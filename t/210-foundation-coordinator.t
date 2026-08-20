use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use Path::Tiny qw( path tempdir );
use YAML::XS ();
use App::karr::Encoding qw( json_encode json_decode );

use App::karr::Foundation;
use App::karr::Foundation::Coordinator;
use App::karr::Foundation::ChainStore;
use App::karr::Foundation::Questions;
use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;

# Ticket #210, the judgement layer: the coordination agent karr-foundation
# calls when a written plan is missing or has broken -- and never otherwise.
#
# What is pinned here, and why each is a decision rather than an accident:
#
#   1. WHICH agent it is, is a marker on an agent definition (role:
#      coordinator) and not a second config key naming an agent that is
#      already named. Two markers are refused rather than guessed between.
#   2. NO AI IN THE HOT PATH. Routing is a lookup in the assignment: repo path
#      to an ordered agent list, first entry that currently works, explicit
#      WAIT for "rather wait than take the next one". A board the assignment
#      routes never calls the coordination agent.
#   3. ONE CALL PER TICK. Five deviations in one tick are one call carrying
#      five reasons, not five runs -- and the call happens at the END of the
#      tick, after the boards and the chain have done what they could.
#   4. IT IS AN AGENT LIKE ANY OTHER: invoked through its definition's command
#      under the kind: claude-code contract (#188), classified from its result
#      JSON (#187), and marked failing by the same availability record --
#      while it is failing the place that wanted it simply waits, which is the
#      behaviour karr-foundation had before it existed.
#   5. A FLEET THAT MARKS NO COORDINATOR IS UNCHANGED. Nothing is recorded,
#      nothing is called, and the chain tick says what it always said.
#
# Everything runs in throwaway repositories with a fake agent that records its
# arguments; HOME is redirected so the developer's own fleet config, agent
# availability and assignment can never be read or written by this file.

my $HOME = tempdir( CLEANUP => 1 );
$ENV{HOME} = "$HOME";

my $LIB = path('lib')->absolute->stringify;
my @KEEP;    # tempdirs vanish with their object

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub make_repo {
  my $dir = tempdir( CLEANUP => 1 );
  push @KEEP, $dir;
  system( 'git', '-C', "$dir", 'init', '-q' ) == 0 or die 'git init';
  system( 'git', '-C', "$dir", 'config', 'user.email', 'fleet@example.com' ) == 0 or die;
  system( 'git', '-C', "$dir", 'config', 'user.name', 'Fleet' ) == 0 or die;
  return $dir;
}

sub seed_board {
  my ( $repo, @specs ) = @_;
  my $store = App::karr::BoardStore->new( git => App::karr::Git->new( dir => "$repo" ) );
  for my $spec ( @specs ) {
    my $id = $store->allocate_next_id;
    $store->save_task( App::karr::Task->new( id => $id, title => "task $id", %$spec ) );
  }
  return $store;
}

sub chain_store {
  return App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => "$_[0]" ) );
}

# A config directory of this test's own, so agents.state and assignment.yml
# are this file's and nobody else's.
sub write_config {
  my ( %data ) = @_;
  my $dir = tempdir( CLEANUP => 1 );
  push @KEEP, $dir;
  my $file = $dir->child('config.yml');
  $file->spew_utf8( YAML::XS::Dump( \%data ) );
  return $file;
}

sub write_assignment {
  my ( $cfg, $data ) = @_;
  path($cfg)->sibling('assignment.yml')->spew_utf8( YAML::XS::Dump($data) );
  return;
}

sub set_agents_state {
  my ( $cfg, $data ) = @_;
  path($cfg)->sibling('agents.state')->spew_utf8( json_encode($data) );
  return;
}

# Never undef and never a nested deref on a missing key: a mutation that
# stops recording availability must FAIL a test, not die before it runs one.
sub agents_state {
  my ( $cfg ) = @_;
  my $file = path($cfg)->sibling('agents.state');
  return {} unless $file->exists;
  my $data = json_decode( $file->slurp_utf8 );
  return ref $data eq 'HASH' ? $data : {};
}

sub agent_record {
  my ( $cfg, $name ) = @_;
  return agents_state($cfg)->{$name} // {};
}

my @ALIVE;    # collaborators hold their foundation weakly
sub foundation {
  my ( $cfg, %args ) = @_;
  my $f = App::karr::Foundation->new( config => "$cfg", %args );
  push @ALIVE, $f;
  return $f;
}

sub coordinator { return foundation(@_)->_coordinator }

# STDOUT through a real file, not an in-memory scalar: the runner forks and
# dups the child's stdout onto a pipe, and a scalar filehandle has no
# descriptor to dup onto.
sub capture {
  my ( $code ) = @_;
  my $file = Path::Tiny->tempfile;
  open my $save, '>&', \*STDOUT or die "dup stdout: $!";
  open STDOUT, '>', "$file"     or die "redirect stdout: $!";
  binmode STDOUT, ':encoding(UTF-8)';
  my ( $ret, $err );
  eval { $ret = $code->(); 1 } or $err = $@;
  open STDOUT, '>&', $save or die "restore stdout: $!";
  close $save;
  die $err if defined $err;
  return ( $file->slurp_utf8, $ret );
}

# The fake coordination agent. It records what it was given -- its argv (so
# the kind: claude-code contract is visible), the prompt the shell expanded
# for it, its role and its working directory -- and can be told to fail or to
# leave a result object behind.
my $OUT;    # where the fake records, set per subtest
sub write_coordinator {
  my ( $dir ) = @_;
  my $script = path($dir)->child('fake-coordinator.pl');
  $script->spew_utf8(<<'PERL');
use strict;
use warnings;
use Path::Tiny qw( path );
my $out = path( $ENV{FAKE_OUT} or die "no FAKE_OUT\n" );
$out->mkpath unless $out->is_dir;
$out->child('runs')->append_utf8("run\n");
my ( $p ) = grep { $ARGV[$_] eq '-p' } 0 .. $#ARGV;
$out->child('prompt')->spew_utf8( defined $p ? ( $ARGV[ $p + 1 ] // '' ) : '' );
$out->child('argv')->spew_utf8( join "\n", @ARGV );
$out->child('env')->spew_utf8( join "\n",
  'role=' . ( $ENV{KARR_ROLE} // '' ),
  'task=' . ( $ENV{KARR_TASK} // '' ),
  'cwd='  . path('.')->realpath );
print "$ENV{FAKE_RESULT}\n" if defined $ENV{FAKE_RESULT} && length $ENV{FAKE_RESULT};
exit( $ENV{FAKE_EXIT} // 0 );
PERL
  return qq{$^X -I"$LIB" "$script"};
}

sub fake_out {
  my $dir = tempdir( CLEANUP => 1 );
  push @KEEP, $dir;
  $OUT = $dir;
  $ENV{FAKE_OUT} = "$dir";
  return $dir;
}

sub coordinator_runs {
  my $f = $OUT->child('runs');
  return $f->exists ? ( grep { length } split /\n/, $f->slurp_utf8 ) : ();
}

sub coordinator_prompt {
  my $f = $OUT->child('prompt');
  return $f->exists ? $f->slurp_utf8 : '';
}

sub log_of {
  my $f = path( $_[0] )->child('.karr.log');
  return $f->exists ? $f->slurp_utf8 : '';
}

sub coordinator_env {
  my $f = $OUT->child('env');
  return '' unless $f->exists;
  return $f->slurp_utf8;
}

# ---------------------------------------------------------------------------
# 1. Which agent is the coordinator
# ---------------------------------------------------------------------------

subtest 'the coordinator is a marked agent definition, not a second config key'
=> sub {
  my $cfg = write_config(
    agents => {
      worker  => { command => 'true' },
      planner => { command => 'true', kind => 'claude-code',
                   role => 'coordinator' },
    },
  );
  my $c = coordinator($cfg);
  is $c->name, 'planner', 'the definition marked role: coordinator is the one';
  ok $c->configured, 'and the fleet has a judgement layer';

  my $none = coordinator( write_config( agents => { w => { command => 'true' } } ) );
  is $none->name, undef, 'a fleet that marks none has none';
  ok !$none->configured, 'and says so';

  my $two = coordinator( write_config( agents => {
    a => { command => 'true', role => 'coordinator' },
    b => { command => 'true', role => 'coordinator' },
  } ) );
  my $err = do { local $@; eval { $two->name }; $@ };
  like $err, qr/both marked/,
    'two marked definitions are refused rather than guessed between: "which '
    . 'of these is the judgement layer" has no safe default';

  my $typo = coordinator( write_config( agents => {
    a => { command => 'true', role => 'coordinater' },
  } ) );
  my $terr = do { local $@; eval { $typo->name }; $@ };
  like $terr, qr/unknown role 'coordinater'/,
    'and a typo in the marker is a hard error, not a fleet that quietly has '
    . 'no judgement layer at all';
};

# ---------------------------------------------------------------------------
# 2. The hot path: a lookup, and no AI in it
# ---------------------------------------------------------------------------

subtest 'the assignment routes a board, and the first working agent wins' => sub {
  fake_out();
  my $repo = make_repo();
  my $cfg  = write_config( agents => {
    fast    => { command => 'fast-cmd' },
    slow    => { command => 'slow-cmd' },
    planner => { command => write_coordinator($repo), kind => 'claude-code',
                 role => 'coordinator' },
  } );
  write_assignment( $cfg, { repos => { "$repo" => [ 'fast', 'slow' ] } } );

  my $f = foundation($cfg);
  my ( $cmd, $inv, $wait ) = $f->_resolve_agent( $repo, {} );
  is $cmd, 'fast-cmd', 'the first agent in the chain is taken';
  is $inv->{name}, 'fast', 'and it comes back as a named agent';
  is $wait, undef, 'nothing waits';
  is_deeply [ @{ $f->_coordinator->wanted } ], [],
    'and the coordination agent is NOT wanted: a board the assignment routes '
    . 'needs no judgement, which is the whole point of writing one down';

  # The same board once `fast` has stopped working: the fallback chain is what
  # the operator's estimate being wrong costs -- one step down the list.
  set_agents_state( $cfg,
    { fast => { state => 'failing', failing_since => time,
                next_attempt => time + 3600, last_error => 'rate limited' } } );
  my $f2 = foundation($cfg);
  my ( $cmd2, $inv2 ) = $f2->_resolve_agent( $repo, {} );
  is $cmd2, 'slow-cmd', 'a failing first choice falls through to the next';
  is $inv2->{name}, 'slow', 'under its own name, so its own availability is '
    . 'what gets written afterwards';

  ok !coordinator_runs(), 'and no coordination agent ran at any point: '
    . 'routing is a lookup, and no AI is in the hot path';
};

subtest 'WAIT is an answer, and an exhausted chain is the same answer' => sub {
  my $repo = make_repo();
  seed_board( $repo, { status => 'todo' } );
  # A .karr file so _process_repo below recognises a board at all -- the wait
  # is checked where the agent is resolved, which is after that.
  path($repo)->child('.karr')->spew_utf8("max_runtime: 60\n");
  my $cfg = write_config( agents => {
    fast => { command => 'fast-cmd' },
    slow => { command => 'slow-cmd' },
  } );
  write_assignment( $cfg, { repos => { "$repo" => [ 'fast', 'WAIT', 'slow' ] } } );
  set_agents_state( $cfg,
    { fast => { state => 'failing', failing_since => time,
                next_attempt => time + 3600 } } );

  my $f = foundation($cfg);
  my ( $cmd, $inv, $wait ) = $f->_resolve_agent( $repo, {} );
  is $cmd, undef, 'nothing runs on this board right now';
  like $wait, qr/WAIT/,
    'because the chain says WAIT before it reaches the next agent -- "rather '
    . 'wait than use something unsuitable here" is the one thing an ordered '
    . 'list cannot say by itself';
  unlike $wait, qr/slow/, 'and the agent below the WAIT is never considered';

  my $result = $f->_process_repo( $repo );
  is $result->{outcome}, 'skipped', 'the board is skipped for this tick';
  like $result->{reason}, qr/WAIT/,
    'with the routing reason, not "no agent configured" -- a board waiting '
    . 'for an agent to come back and a board nobody configured are fixed by '
    . 'different things';
  ok !path($repo)->child('.karr.log')->exists, 'and nothing was started';

  # No WAIT written, every agent failing: the same answer. Going past the end
  # of a chain the coordination agent wrote would be karr routing on its own.
  my $cfg2 = write_config( agents => { fast => { command => 'fast-cmd' } } );
  write_assignment( $cfg2, { repos => { "$repo" => ['fast'] } } );
  set_agents_state( $cfg2,
    { fast => { state => 'failing', failing_since => time,
                next_attempt => time + 3600 } } );
  my ( undef, undef, $wait2 ) = foundation($cfg2)->_resolve_agent( $repo, {} );
  like $wait2, qr/every agent .* is failing/,
    'an exhausted chain waits too, and says which agents it tried';
};

subtest 'the assignment sits below the board\'s own agent and above the default'
=> sub {
  my $repo = make_repo();
  my $cfg  = write_config(
    agents => {
      routed  => { command => 'routed-cmd' },
      own     => { command => 'own-cmd' },
      default => { command => 'default-cmd' },
    },
    default_agent => 'default',
  );
  write_assignment( $cfg, { repos => { "$repo" => ['routed'] } } );
  my $f = foundation($cfg);

  is( ( $f->_resolve_agent( $repo, { agent => 'own' } ) )[0], 'own-cmd',
    'a board that names its own agent is not routed: it has said the most '
    . 'specific thing there is to say about itself' );
  is( ( $f->_resolve_agent( $repo, { command => 'literal' } ) )[0], 'literal',
    'and a literal command still wins over everything' );
  is( ( $f->_resolve_agent( $repo, {} ) )[0], 'routed-cmd',
    'a board that names none is routed by the assignment, which is per '
    . 'repository and therefore beats default_agent, which is per fleet' );

  my $other = make_repo();
  is( ( $f->_resolve_agent( $other, {} ) )[0], 'default-cmd',
    'and a repository the assignment does not name falls through to the '
    . 'fleet default exactly as it did before there was an assignment' );
};

subtest 'an assignment naming an agent this machine has not is not fatal' => sub {
  my $repo = make_repo();
  my $cfg  = write_config( agents => {
    here    => { command => 'here-cmd' },
    planner => { command => 'true', role => 'coordinator' },
  } );
  write_assignment( $cfg,
    { repos => { "$repo" => [ 'elsewhere', 'here' ] } } );

  my $f = foundation($cfg);
  is( ( $f->_resolve_agent( $repo, {} ) )[0], 'here-cmd',
    'an agent this machine does not define is skipped, not refused: agent '
    . 'definitions are local and only local, so a table written where more of '
    . 'them exist is a normal thing to meet' );
  is_deeply [ @{ $f->_coordinator->wanted } ], [],
    'and that is not a deviation either';

  write_assignment( $cfg, { repos => { "$repo" => ['elsewhere'] } } );
  my $f2 = foundation($cfg);
  is( ( $f2->_resolve_agent( $repo, {} ) )[0], undef, 'a chain of nothing but '
    . 'unknown names routes nothing' );
  is scalar @{ $f2->_coordinator->wanted }, 1,
    'and that IS a deviation the coordination agent hears about';
};

# ---------------------------------------------------------------------------
# 3. One call per tick, at the end of it
# ---------------------------------------------------------------------------

subtest 'a tick with no assignment calls the coordination agent once' => sub {
  my $out  = fake_out();
  my $hub  = make_repo();
  my @repo = ( make_repo(), make_repo(), make_repo() );
  seed_board( $_, { status => 'todo' } ) for @repo;

  my $cfg = write_config(
    hub     => "$hub",
    dirs    => [ map { "$_" } @repo ],
    routing => "minimax is cheap and does the routine work.\n"
             . "Never hand it a release.",
    agents  => {
      minimax => { command => 'minimax-cmd', description => 'cheap and fast' },
      planner => { command => write_coordinator($hub), kind => 'claude-code',
                   role => 'coordinator',
                   description => 'the one that thinks' },
    },
  );

  my ( $printed ) = capture( sub { foundation($cfg)->run } );

  is scalar( coordinator_runs() ), 1,
    'THREE boards nobody has routed are ONE call: a tick that met five '
    . 'deviations has learned one thing, and five calls would pay five times '
    . 'to hear it';

  my $prompt = coordinator_prompt();
  like $prompt, qr/\Q$_\E: no assignment names this repository/, "prompt names $_"
    for @repo;
  like $prompt, qr/Never hand it a release/,
    'the operator\'s own prose reaches it -- that prose IS the routing '
    . 'criterion, and karr never parses it';
  like $prompt, qr/cheap and fast/, 'so does each agent\'s description';
  like $prompt, qr/\Qminimax\E\s+kind: shell\s+ok/, 'with what is known about it now';
  like $prompt, qr/assignment\s+\Q@{[ path($cfg)->sibling('assignment.yml') ]}\E/,
    'and the path it is supposed to write';
  like $prompt, qr/never names an agent|Name an agent in a chain step/i,
    'the boundary that keeps routing out of the shared chain is stated';

  my $env = coordinator_env();
  like $env, qr/role=coordinator/,
    'it runs under its own role, so its karr writes are not an agent\'s '
    . 'engagement with a card';
  like $env, qr/task=$/m, 'and it is given no ticket: it is not working a card';
  like $env, qr{cwd=\Q@{[ path($hub)->realpath ]}\E},
    'in the hub, where the chain and the questions it may write live';

  like $printed, qr/calling the coordination agent 'planner' for 3 deviation/,
    'and the tick says it out loud';

  my $log = log_of($hub);
  like $log, qr/START role=coordinator agent=planner/,
    'the run is in the hub\'s log like every other run karr starts';
  like $log, qr/COORDINATION wanted:/, 'together with what it was called for';
};

subtest 'the chain\'s three deviations are one call, after the tick' => sub {
  my $out    = fake_out();
  my $hub    = make_repo();
  my $repo   = make_repo();
  my $marker = path($repo)->child('marker');
  seed_board( $repo, { status => 'done' } );     # nothing actionable left

  my $cfg = write_config(
    hub    => "$hub",
    agents => { planner => { command => write_coordinator($hub),
                             kind => 'claude-code', role => 'coordinator' } },
  );

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'plan', note => 'what next?' },
    { id => 2, kind => 'shell', repo => "$repo", command => "echo x >> '$marker'",
      precheck => 'board_actionable == yes' },
    { id => 3, kind => 'plan', note => 'and then?' },
  ] );

  my ( $printed, $exit ) = capture( sub { foundation($cfg)->run('chain') } );
  is $exit, 0, 'the tick finished';
  ok !$marker->exists, 'the stale step did not run';

  is scalar( coordinator_runs() ), 1,
    'two plan steps and one stale step are ONE call at the end of the tick';
  my $prompt = coordinator_prompt();
  like $prompt, qr/step 1: kind: plan is not executed here/, 'the plan step is named';
  like $prompt, qr/step 3: kind: plan is not executed here/, 'both of them';
  like $prompt, qr/step 2: .*precheck/,
    'and the stale step, with the precheck that stopped holding';
  like $printed, qr/the coordination agent is called at the end of this tick/,
    'the tick says a planner is wanted AND that one exists to be called';
};

subtest 'an overdue escalate_to_ai question is one of the deviations' => sub {
  my $out = fake_out();
  my $hub = make_repo();
  my $cfg = write_config(
    hub    => "$hub",
    agents => { planner => { command => write_coordinator($hub),
                             kind => 'claude-code', role => 'coordinator' } },
  );

  chain_store($hub)->write_chain( [ { id => 1, kind => 'question' } ] );
  my $qid = App::karr::Foundation::Questions->new(
    git => App::karr::Git->new( dir => "$hub" ) )->ask(
      question => 'which registry?', policy => 'escalate_to_ai',
      deadline => '2000-01-01T00:00:00Z', step => 1 );

  my ( $printed ) = capture( sub { foundation($cfg)->run('chain') } );

  is scalar( coordinator_runs() ), 1, 'the policy that names the agent calls it';
  like coordinator_prompt(), qr/step 1: escalate_to_ai on question #\Q$qid\E/,
    'naming the question, not merely the step';
  is chain_store($hub)->step(1)->{state}, 'pending',
    'and the step is left exactly as the planner left it: the question is '
    . 'still open, and nothing here answered it on the agent\'s behalf';
};

# ---------------------------------------------------------------------------
# 4. An agent like any other
# ---------------------------------------------------------------------------

subtest 'a coordination agent that fails is marked failing and then waited for'
=> sub {
  my $out  = fake_out();
  my $hub  = make_repo();
  my $repo = make_repo();
  seed_board( $repo, { status => 'todo' } );
  my $cfg = write_config(
    hub    => "$hub",
    dirs   => [ "$repo" ],
    agents => { planner => { command => write_coordinator($hub),
                             kind => 'claude-code', role => 'coordinator',
                             probe_every => '30m' } },
  );

  {
    local $ENV{FAKE_EXIT} = 3;
    my ( $printed ) = capture( sub { foundation($cfg)->run } );
    like $printed, qr/coordination agent 'planner' failed: exit=3/,
      'a bad exit is a failure like any other agent\'s';
  }
  my $state = agent_record( $cfg, 'planner' );
  is $state->{state}, 'failing',
    'and it goes into the same availability record every board agent uses';
  is $state->{last_error}, 'exit=3', 'with what was seen';
  cmp_ok $state->{next_attempt} // 0, '>', time + 1500,
    'and its own probe_every decides when it is tried again';

  # The second tick: the same deviation, an agent that is failing. The place
  # that wanted it waits -- which is what karr-foundation did before there was
  # a coordination agent at all.
  my ( $again ) = capture( sub { foundation($cfg)->run } );
  is scalar( coordinator_runs() ), 1, 'it is not called again while it fails';
  like $again, qr/the coordination agent 'planner' is failing/,
    'and the tick says why nothing was planned';
  like $again, qr/the plan waits/, 'the deviation simply keeps waiting';
};

subtest 'the run is classified from its result JSON, never from its transcript'
=> sub {
  my $out  = fake_out();
  my $hub  = make_repo();
  my $repo = make_repo();
  seed_board( $repo, { status => 'todo' } );
  my $cfg = write_config(
    hub    => "$hub",
    dirs   => [ "$repo" ],
    agents => { planner => { command => write_coordinator($hub),
                             kind => 'claude-code', role => 'coordinator' } },
  );

  {
    # Exit 0, and a report that says the provider refused. Without the report
    # this run would count as a success.
    local $ENV{FAKE_RESULT} = '{"type":"result","is_error":true,'
      . '"subtype":"error_api","api_error_status":429,"num_turns":2}';
    capture( sub { foundation($cfg)->run } );
  }
  is agent_record( $cfg, 'planner' )->{last_error}, 'api 429',
    'the agent\'s own result object is what says how the run ended';
  like log_of($hub), qr/RESULT api 429/,
    'and the log carries the same reading';

  # Now the recovery: the probe IS the run, and the moment it worked again is
  # recorded for whoever wants to read a rhythm out of it later.
  set_agents_state( $cfg, { planner => { state => 'failing',
    failing_since => time - 600, next_attempt => time - 1,
    last_error => 'api 429' } } );
  {
    local $ENV{FAKE_RESULT} = '{"type":"result","is_error":false,"num_turns":4}';
    my ( $printed ) = capture( sub { foundation($cfg)->run } );
    like $printed, qr/coordination agent 'planner' finished/, 'it ran again';
  }
  my $state = agent_record( $cfg, 'planner' );
  is $state->{state}, 'ok', 'and is back';
  is scalar @{ $state->{recovered} // [] }, 1,
    'with the outage recorded, which is the trail karr leaves instead of '
    . 'learning a rhythm itself';

  # A transcript full of the words the board-run scan looks for, and a report
  # that says the run was fine: the report wins, because this run moved no
  # board and a planner that printed a backlog would trip the scan on it.
  set_agents_state( $cfg, {} );
  {
    local $ENV{FAKE_RESULT} = '{"type":"result","is_error":false}';
    capture( sub { foundation($cfg)->run } );
  }
  is agent_record( $cfg, 'planner' )->{state} // 'ok', 'ok',
    'a clean report leaves it available';
};

# ---------------------------------------------------------------------------
# 5. A fleet without a coordinator is the fleet karr-foundation always had
# ---------------------------------------------------------------------------

subtest 'no marked agent: nothing recorded, nothing called, nothing changed'
=> sub {
  my $out    = fake_out();
  my $hub    = make_repo();
  my $repo   = make_repo();
  my $marker = path($repo)->child('marker');
  seed_board( $repo, { status => 'done' } );

  my $cfg = write_config( hub => "$hub",
    agents => { worker => { command => write_coordinator($hub) } } );
  chain_store($hub)->write_chain( [
    { id => 1, kind => 'plan' },
    { id => 2, kind => 'shell', repo => "$repo", command => "echo x >> '$marker'",
      precheck => 'board_actionable == yes' },
  ] );

  my ( $printed ) = capture( sub { foundation($cfg)->run('chain') } );
  ok !coordinator_runs(), 'nothing is called';
  like $printed, qr/no planner runs from here yet; re-plan the chain/,
    'and the tick says exactly what it said before this existed: the operator '
    . 'is the planner until a fleet marks one';
  my $c = foundation($cfg)->_coordinator;
  is $c->want( reason => 'anything at all' ), 0,
    'a deviation is not even recorded -- the executor has already said it out '
    . 'loud and written it into the run log, and a second record nobody can '
    . 'act on is not a record';
  is_deeply [ @{ $c->wanted } ], [], 'so nothing is carried';

  # And the other half of the same contract, where there IS one: recorded
  # once, however often the tick meets it. _plan_repos and _process_repo both
  # resolve every board, so one board says the same thing twice per tick.
  my $marked = foundation( write_config( hub => "$hub",
    agents => { p => { command => 'true', role => 'coordinator' } } ) )
    ->_coordinator;
  is $marked->want( step => 4, reason => 'same' ), 1, 'the first is recorded';
  is $marked->want( step => 4, reason => 'same' ), 0, 'the second collapses';
  is scalar @{ $marked->wanted }, 1, 'one call carries it once';
};

# ---------------------------------------------------------------------------
# 6. The two ways not to call it
# ---------------------------------------------------------------------------

subtest 'a dry run, a hubless fleet and a busy hub all call nothing' => sub {
  my $out  = fake_out();
  my $hub  = make_repo();
  my $repo = make_repo();
  seed_board( $repo, { status => 'todo' } );
  my $cfg = write_config( hub => "$hub", dirs => [ "$repo" ],
    agents => { planner => { command => write_coordinator($hub),
                             kind => 'claude-code', role => 'coordinator' } } );

  my ( $dry ) = capture( sub { foundation( $cfg, dry_run => 1 )->run } );
  like $dry, qr/would call the coordination agent 'planner'/,
    '--dry-run says what it would have called and why';
  ok !coordinator_runs(), 'and calls nothing';

  my $nohub = write_config( dirs => [ "$repo" ],
    agents => { planner => { command => write_coordinator($hub),
                             kind => 'claude-code', role => 'coordinator' } } );
  my @warnings;
  {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    capture( sub { foundation($nohub)->run } );
  }
  ok !coordinator_runs(),
    'a fleet with no hub cannot call it: a chain and a question live in '
    . 'refs/karr-foundation/*, so there would be nowhere to put the answer';
  like join( '', @warnings ), qr/no hub/, 'and it says so once';

  # One agent per repository is the fleet's one hard rule, and the hub is a
  # repository like any other: a tick whose hub is already held waits instead
  # of putting a second agent into that working tree.
  my $holder = foundation($cfg);
  ok $holder->_acquire_lock( path($hub) ), 'the hub is locked by somebody else';
  my ( $busy ) = capture( sub { foundation($cfg)->run } );
  ok !coordinator_runs(), 'so the coordination agent does not run in it';
  like $busy, qr/is busy/, 'and the tick says the plan waits for the next one';
  $holder->_release_lock( path($hub) );
};

done_testing;
