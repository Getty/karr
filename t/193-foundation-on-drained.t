use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path tempdir );
use Time::Piece;
use YAML::XS ();

use App::karr::Foundation;
use App::karr::Encoding qw( json_decode );
use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;

# Ticket #193: when a board drains, run a configured command. karr does not
# know and must not know what that command does -- in the fleet this design
# came from it is a release gate that builds a distribution, installs it and
# tests every dependent against it, none of which belongs in a kanban tool.
#
# So nothing below asserts anything about what the hook *is*. What is pinned
# here is the seam: when it runs, what it is told (where it is, and nothing
# else), what it may not be mistaken for (an agent run), and -- the part that
# needs the most care -- what stops "hook files a ticket, board is worked off,
# hook runs again" from being a loop with no end.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

my @KEEP_TMP;

sub make_git_repo {
  my $dir = tempdir( CLEANUP => 1 );
  system( 'git', '-C', "$dir", 'init', '-q' ) == 0 or die "git init";
  system( 'git', '-C', "$dir", 'config', 'user.email', 'a@b.invalid' ) == 0 or die;
  system( 'git', '-C', "$dir", 'config', 'user.name', 'T' ) == 0 or die;
  return $dir;
}

sub store_of {
  my ( $repo ) = @_;
  return App::karr::BoardStore->new( git => App::karr::Git->new( dir => "$repo" ) );
}

sub seed_board {
  my ( $repo, @titles ) = @_;
  my $store = store_of( $repo );
  for my $title ( @titles ) {
    my $id = $store->allocate_next_id;
    $store->save_task(
      App::karr::Task->new( id => $id, title => $title, status => 'todo' ) );
  }
  return $store;
}

sub write_config {
  my ( %data ) = @_;
  my $dir = tempdir( CLEANUP => 1 );
  push @KEEP_TMP, $dir;
  my $file = $dir->child('config.yml');
  $file->spew_utf8( YAML::XS::Dump( \%data ) );
  return $file;
}

sub state_data {
  my ( $repo ) = @_;
  my $file = path( $repo )->child('.karr.state');
  return $file->exists ? json_decode( $file->slurp_utf8 ) : {};
}

sub log_of {
  my ( $repo ) = @_;
  my $file = path( $repo )->child('.karr.log');
  return $file->exists ? $file->slurp_utf8 : '';
}

# The agent: finishes every actionable card it finds, one per run, and leaves
# an activity-log entry behind so foundation can see it engaged the board.
sub write_fake_agent {
  my ( $dir ) = @_;
  my $lib    = path('lib')->absolute->stringify;
  my $script = path($dir)->child('fake-agent.pl');
  $script->spew_utf8(<<'PERL');
use strict;
use warnings;
require App::karr::Git;
require App::karr::BoardStore;
require App::karr::ActivityLog;
my $repo = $ENV{KARR_REPO} or die "no KARR_REPO\n";
open my $fh, '>>', "$repo/agent-runs.log" or die $!;
print {$fh} "run\n";
close $fh;
my $store = App::karr::BoardStore->new(
  git => App::karr::Git->new( dir => $repo ) );
my ( $t ) = grep {
  $_ && !$_->has_blocked && $_->status ne 'done' && $_->status ne 'archived'
} $store->load_tasks;
exit 0 unless $t;
$t->status('done');
$store->save_task($t);
App::karr::ActivityLog->new( git => $store->git, role => 'agent' )->log_entry(
  agent => 'fake-agent', action => 'move', task_id => $t->id + 0, detail => 'done' );
PERL
  return qq{$^X -I"$lib" "$script"};
}

# The hook. It records the environment it was handed -- that is the whole
# contract from karr's side -- and, when told to, puts a card back on the
# board, which is the case the ticket says the hook has to tolerate being the
# cause of.
sub write_fake_hook {
  my ( $dir ) = @_;
  my $lib    = path('lib')->absolute->stringify;
  my $script = path($dir)->child('fake-hook.pl');
  $script->spew_utf8(<<'PERL');
use strict;
use warnings;
use Cwd ();
my $repo = $ENV{KARR_REPO} or die "no KARR_REPO\n";
open my $fh, '>>', "$repo/hook-runs.log" or die $!;
printf {$fh} "role=%s task=[%s] prompt=[%s] cwd=%s\n",
  ( $ENV{KARR_ROLE} // '<unset>' ), ( $ENV{KARR_TASK} // '<unset>' ),
  ( $ENV{PROMPT} // '<unset>' ), Cwd::getcwd();
close $fh;

print $ENV{KARR_FAKE_HOOK_OUTPUT} . "\n" if $ENV{KARR_FAKE_HOOK_OUTPUT};

if ( $ENV{KARR_FAKE_HOOK_FILES} ) {
  require App::karr::Git;
  require App::karr::BoardStore;
  require App::karr::Task;
  my $store = App::karr::BoardStore->new(
    git => App::karr::Git->new( dir => $repo ) );
  my $id = $store->allocate_next_id;
  $store->save_task( App::karr::Task->new(
    id => $id, title => "the gate found something", status => 'todo' ) );
}

exit( $ENV{KARR_FAKE_HOOK_EXIT} // 0 );
PERL
  return qq{$^X -I"$lib" "$script"};
}

# Returned as an array so `scalar hook_runs($repo)` is the count and not the
# undef a bare `return ()` yields in scalar context.
sub runs_in {
  my ( $repo, $file ) = @_;
  my $log = path( $repo )->child( $file );
  my @lines = $log->exists ? ( grep { length } split /\n/, $log->slurp_utf8 ) : ();
  return @lines;
}

sub hook_runs  { return runs_in( $_[0], 'hook-runs.log' ) }
sub agent_runs { return runs_in( $_[0], 'agent-runs.log' ) }

# ---------------------------------------------------------------------------
# Where the command comes from
# ---------------------------------------------------------------------------

subtest 'on_drained is a .karr key with a config-wide fallback' => sub {
  my $f = App::karr::Foundation->new( _config_data => {} );
  is $f->_on_drained_command( {} ), undef,
    'no hook configured anywhere is the default -- nothing runs';

  is $f->_on_drained_command( { on_drained => 'gate.sh' } ), 'gate.sh',
    'the .karr key names it';

  my $g = App::karr::Foundation->new(
    _config_data => { on_drained => 'fleet-gate.sh' } );
  is $g->_on_drained_command( {} ), 'fleet-gate.sh',
    'a fleet can configure one for every board it drains';
  is $g->_on_drained_command( { on_drained => 'own.sh' } ), 'own.sh',
    'and the board is the more specific statement, as everywhere else here';
  is $g->_on_drained_command( { on_drained => '' } ), undef,
    'an empty string turns the fleet-wide hook off for one board';
};

# ---------------------------------------------------------------------------
# When it runs
# ---------------------------------------------------------------------------

subtest 'the hook runs when the board has no actionable work left' => sub {
  my $repo  = make_git_repo();
  seed_board( $repo, 'tidy the parser', 'update the docs' );
  my $agent = write_fake_agent( $repo );
  my $hook  = write_fake_hook( $repo );
  path( $repo )->child('.karr')->spew_utf8(
    "command: $agent\nmax_runtime: 60\non_drained: $hook\n" );

  my $f = App::karr::Foundation->new( _config_data => {} );
  $f->_process_repo( path( $repo ) );

  is scalar agent_runs( $repo ), 2,
    'the drain ran until the board stopped offering work';
  is scalar hook_runs( $repo ), 1, 'and then the hook ran, exactly once';
  like log_of( $repo ), qr/ON-DRAINED/, 'the log says the hook ran';
};

subtest 'a board with work left on it has not drained' => sub {
  my $repo  = make_git_repo();
  seed_board( $repo, 'tidy the parser', 'update the docs' );
  my $hook  = write_fake_hook( $repo );
  # An agent that does nothing at all: the board is untouched and still full
  # of actionable cards. An empty *run* is not an empty board.
  path( $repo )->child('.karr')->spew_utf8(
    "command: true\nmax_runtime: 60\non_drained: $hook\n" );

  my $f = App::karr::Foundation->new( _config_data => {}, force => 1 );
  $f->_process_repo( path( $repo ) );

  is scalar hook_runs( $repo ), 0,
    'an idle run over a board that still has cards is not a drained board';
};

subtest 'blocked and finished cards are not work, so the board has drained' => sub {
  my $repo = make_git_repo();
  my $hook = write_fake_hook( $repo );
  my $store = seed_board( $repo, 'cannot be done', 'already done' );
  my $blocked = $store->find_task( 1 );
  $blocked->block( 'waiting for the other repo' );
  $store->save_task( $blocked );
  my $done = $store->find_task( 2 );
  $done->status( 'done' );
  $store->save_task( $done );

  my $f = App::karr::Foundation->new( _config_data => {}, force => 1 );
  $f->_process_repo( path( $repo ) );
  # No agent is configured, so nothing is drained and nothing is hooked.
  is scalar hook_runs( $repo ), 0, 'no agent, no drain, no hook';

  my $agent = write_fake_agent( $repo );
  path( $repo )->child('.karr')->spew_utf8(
    "command: $agent\nmax_runtime: 60\non_drained: $hook\n" );
  $f->_process_repo( path( $repo ) );
  is scalar hook_runs( $repo ), 1,
    'a board whose remainder is blocked or terminal has no actionable work '
    . 'left, which is what draining means';
};

subtest 'a run that broke says nothing about the board being finished' => sub {
  my $repo = make_git_repo();
  my $hook = write_fake_hook( $repo );
  path( $repo )->child('.karr')->spew_utf8(
    "command: exit 3\nmax_runtime: 60\non_drained: $hook\n" );

  my $f = App::karr::Foundation->new( _config_data => {}, force => 1 );
  $f->_process_repo( path( $repo ) );

  ok $f->_cooldown_active( path( $repo ) ), 'the board is in cooldown';
  is scalar hook_runs( $repo ), 0,
    'an agent that could not run leaves an empty-looking board that is not '
    . 'evidence of anything -- the hook is not called on it';
};

# ---------------------------------------------------------------------------
# What the hook is told
# ---------------------------------------------------------------------------

subtest 'the hook is told where it is and nothing else' => sub {
  my $repo  = make_git_repo();
  seed_board( $repo, 'tidy the parser' );
  my $agent = write_fake_agent( $repo );
  my $hook  = write_fake_hook( $repo );
  path( $repo )->child('.karr')->spew_utf8(
    "command: $agent\nmax_runtime: 60\nprompt: DO THE AGENT THING\n"
    . "on_drained: $hook\n" );

  my $f = App::karr::Foundation->new( _config_data => {} );
  $f->_process_repo( path( $repo ) );

  my ( $line ) = hook_runs( $repo );
  ok defined $line, 'the hook ran' or return;
  like $line, qr/\brole=hook\b/,
    'KARR_ROLE says hook, so a karr write of its own is not filed as the '
    . "agent's engagement with a card";
  like $line, qr/\btask=\[\]/, 'no ticket: the hook was given no assignment';
  like $line, qr/\bprompt=\[\]/,
    'and no prompt -- the prompt is the agent instruction, and the hook is '
    . 'not an agent';
  like $line, qr{\bcwd=\Q$repo\E}, 'it runs in the board it drained';
};

# ---------------------------------------------------------------------------
# What the hook is not
# ---------------------------------------------------------------------------

subtest 'a hook that fails is not a failing agent' => sub {
  my $repo   = make_git_repo();
  seed_board( $repo, 'tidy the parser' );
  my $agent  = write_fake_agent( $repo );
  my $hook   = write_fake_hook( $repo );
  my $cfg    = write_config( agents => { fake => { command => $agent } } );
  path( $repo )->child('.karr')->spew_utf8(
    "agent: fake\nmax_runtime: 60\non_drained: $hook\n" );

  local $ENV{KARR_FAKE_HOOK_EXIT}   = 4;
  # The exact text the run classifier backs a board off for. A hook is not
  # classified at all, so it must not matter what it printed.
  local $ENV{KARR_FAKE_HOOK_OUTPUT} = 'API Error: 429 Too Many Requests';

  my $f = App::karr::Foundation->new( config => "$cfg" );
  $f->_process_repo( path( $repo ) );

  is scalar hook_runs( $repo ), 1, 'the hook ran and failed';
  my $state = state_data( $repo );
  ok !$f->_cooldown_active( path( $repo ) ),
    'a failed hook does not park the board';
  ok !exists $state->{last_error}, 'and is not recorded as the run\'s error';
  is $state->{last_exit}, 0, 'last_exit still describes the agent run';
  ok $f->_agents->available( 'fake' ),
    'nor does it mark the agent that drained the board as failing (#188)';
  like log_of( $repo ), qr/ON-DRAINED exit=4/,
    'what it did is written down, and interpreted by nobody';
  is $state->{last_on_drained}{exit}, 4, 'and kept for the operator';
};

# ---------------------------------------------------------------------------
# The loop question
# ---------------------------------------------------------------------------

subtest 'the hook does not run twice on the same board' => sub {
  my $repo = make_git_repo();
  my $hook = write_fake_hook( $repo );
  my $karr = { on_drained => $hook, max_runtime => 60 };

  my $f = App::karr::Foundation->new( _config_data => {} );
  $f->_run_on_drained( path( $repo ), $karr, { outcome => 'progress' } );
  is scalar hook_runs( $repo ), 1, 'the drained board called it';

  $f->_run_on_drained( path( $repo ), $karr, { outcome => 'progress' } );
  $f->_run_on_drained( path( $repo ), $karr, { outcome => 'idle' } );
  is scalar hook_runs( $repo ), 1,
    'a board that has not moved since is the same board, and the hook has '
    . 'already had its say about it -- otherwise a quiet repo would run a '
    . 'release gate on every cron tick, for ever';

  seed_board( $repo, 'something new happened' );
  my $store = store_of( $repo );
  my $t = $store->find_task( 1 );
  $t->status( 'done' );
  $store->save_task( $t );
  $f->_run_on_drained( path( $repo ), $karr, { outcome => 'progress' } );
  is scalar hook_runs( $repo ), 2, 'a board that moved is a new question';

  my $forced = App::karr::Foundation->new( _config_data => {}, force => 1 );
  $forced->_run_on_drained( path( $repo ), $karr, { outcome => 'progress' } );
  is scalar hook_runs( $repo ), 3, '--force asks it again anyway';
};

subtest 'a hook that puts work back on the board is tolerated, and capped' => sub {
  my $repo  = make_git_repo();
  seed_board( $repo, 'tidy the parser' );
  my $agent = write_fake_agent( $repo );
  my $hook  = write_fake_hook( $repo );
  path( $repo )->child('.karr')->spew_utf8(
    "command: $agent\nmax_runtime: 60\non_drained: $hook\n"
    . "on_drained_max_rounds: 2\n" );

  local $ENV{KARR_FAKE_HOOK_FILES} = 1;

  # No --force anywhere: every tick below reaches the drain on its own merits,
  # because the previous tick's hook left an actionable card behind. That is
  # the loop, driven exactly as cron would drive it.
  my $f = App::karr::Foundation->new( _config_data => {} );

  $f->_process_repo( path( $repo ) );
  is scalar hook_runs( $repo ), 1, 'tick 1: board drained, hook ran';
  ok $f->_has_actionable_tasks( path( $repo ) ),
    'and the hook itself is why the board is no longer drained';

  $f->_process_repo( path( $repo ) );
  is scalar hook_runs( $repo ), 2,
    'tick 2: the agent worked the card the hook filed, the board drained '
    . 'again, and the hook is asked again -- that cycle is the point';

  $f->_process_repo( path( $repo ) );
  is scalar hook_runs( $repo ), 2,
    'tick 3: two consecutive hook runs made work and neither settled, so the '
    . 'third is refused rather than filing a ticket every cron tick for ever';
  like log_of( $repo ), qr/ON-DRAINED suppressed/,
    'loudly, in the board log, with the reason';

  my $before = scalar agent_runs( $repo );
  $f->_process_repo( path( $repo ) );
  is scalar hook_runs( $repo ), 2, 'tick 4: still refused';
  is scalar agent_runs( $repo ), $before,
    'and with the hook silent the board is quiet -- nothing left to run';

  my $forced = App::karr::Foundation->new( _config_data => {}, force => 1 );
  $forced->_process_repo( path( $repo ) );
  is scalar hook_runs( $repo ), 3,
    'the operator is the way out of the cap, and --force is how they say so';
};

subtest 'a hook that settles clears the count' => sub {
  my $repo  = make_git_repo();
  seed_board( $repo, 'tidy the parser' );
  my $agent = write_fake_agent( $repo );
  my $hook  = write_fake_hook( $repo );
  path( $repo )->child('.karr')->spew_utf8(
    "command: $agent\nmax_runtime: 60\non_drained: $hook\n"
    . "on_drained_max_rounds: 1\n" );

  my $f = App::karr::Foundation->new( _config_data => {} );
  $f->_process_repo( path( $repo ) );
  is scalar hook_runs( $repo ), 1, 'the hook ran on the drained board';
  is state_data( $repo )->{on_drained_rounds}, 0,
    'it left the board alone, so it starts no chain';

  # Something else moves the board -- a person, another machine, a sync.
  seed_board( $repo, 'a human filed this one' );
  $f->_process_repo( path( $repo ) );
  is scalar hook_runs( $repo ), 2,
    'a cap of 1 does not stop a hook that never made work in the first place';
};

# ---------------------------------------------------------------------------
# The hook goes through the same door as the agent
# ---------------------------------------------------------------------------

subtest 'a hook that hangs is killed with its whole process group' => sub {
  # #148's invariant, reached through the hook: a release gate is far more
  # likely to background a build than an agent is, and a hook that outlives
  # the foundation run that started it would be exactly the orphan the
  # process-group kill exists to prevent.
  # Kept as the Path::Tiny::Temp object it is: wrapping it in path() would drop
  # the guard and delete the directory before the hook ever ran in it.
  my $repo   = tempdir( CLEANUP => 1 );
  my $marker = "45.$$";
  my $cmd    = "sleep $marker & exec sleep $marker";

  my $f = App::karr::Foundation->new( _config_data => {} );
  my $start = time;
  $f->_run_on_drained( $repo,
    { on_drained => $cmd, on_drained_max_runtime => 1 },
    { outcome => 'progress' } );
  my $elapsed = time - $start;

  ok $elapsed < 15, "the hook has its own budget and it was enforced (${elapsed}s)"
    or diag 'the hook waited out the sleep -- it is not going through the '
          . 'runner, or it inherited no timeout';

  my @survivors;
  opendir my $d, '/proc' or die "opendir /proc: $!";
  while ( my $entry = readdir($d) ) {
    next unless $entry =~ /\A[0-9]+\z/;
    next if $entry == $$;
    my $cmdline = eval { path("/proc/$entry/cmdline")->slurp_raw } // next;
    $cmdline =~ s/\0/ /g;
    $cmdline =~ s/\s+\z//;
    push @survivors, $entry if $cmdline eq "sleep $marker";
  }
  closedir $d;
  ok !@survivors, "no orphan sleep $marker left behind"
    or diag "survivors: @survivors";

  like log_of( $repo ), qr/TIMEOUT after/,
    'and the log says the same thing it says for an agent that hung';
};

subtest 'a hook is never started under --dry-run' => sub {
  my $repo = make_git_repo();
  my $hook = write_fake_hook( $repo );

  my $f = App::karr::Foundation->new( _config_data => {}, dry_run => 1 );
  $f->_run_on_drained( path( $repo ),
    { on_drained => $hook }, { outcome => 'progress' } );

  is scalar hook_runs( $repo ), 0, 'nothing ran';
  is_deeply state_data( $repo ), {},
    'and nothing was written down about a run that never happened';
};

subtest 'a hook that explodes does not take the board lock with it' => sub {
  my $repo  = make_git_repo();
  seed_board( $repo, 'tidy the parser' );
  my $agent = write_fake_agent( $repo );
  # A command whose log the runner cannot open is the one failure that throws
  # out of _run_command; a directory where .karr.log has to go does it.
  path( $repo )->child('.karr')->spew_utf8(
    "command: $agent\nmax_runtime: 60\non_drained: true\n" );

  my $f = App::karr::Foundation->new( _config_data => {} );
  # Make _run_on_drained die outright, whatever it is doing internally.
  my $boom = sub { die "gate exploded\n" };
  no warnings 'redefine';
  local *App::karr::Foundation::_on_drained_command = $boom;
  use warnings 'redefine';

  my $warned = '';
  local $SIG{__WARN__} = sub { $warned .= $_[0] };
  ok eval { $f->_process_repo( path( $repo ) ); 1 },
    'the repo pass returns instead of propagating';
  like $warned, qr/on_drained/, 'with a warning naming the hook';
  ok !$f->_lock_held( path( $repo ) ),
    'and the board lock is released -- a leaked lock would park the board '
    . 'until a human removed the file';
};

done_testing;
