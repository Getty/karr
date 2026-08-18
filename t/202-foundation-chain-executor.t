use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use Path::Tiny qw( path tempdir );
use POSIX ();
use Time::Piece;

use App::karr::Foundation;
use App::karr::Foundation::Executor;
use App::karr::Foundation::ChainStore;
use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;

# Ticket #202, the piece the fleet-execution epic (#194) never had: the chain
# and the run log were storage (#189), the modes were execution (#185/#186),
# and nothing joined them -- no code path chose a ready step, checked its
# precheck, ran it, wrote its state back or marked it stale.
#
# What is pinned here, and why each is a decision rather than an accident:
#
#   1. The executor is a LAYER ABOVE the repo modes, not a fourth mode beside
#      drain/single/ticket. A kind: ticket step goes into the existing ticket
#      mode in the target repo -- so the card is the one the CHAIN named, one
#      agent run happens whatever the board's own `mode:` says, and the lock,
#      the claim and the ownership guard are inherited rather than copied.
#   2. A step whose precheck no longer holds is NOT EXECUTED. That is the whole
#      point of the mechanism, so the test proves the command never ran, not
#      merely that the step ended up marked stale.
#   3. Two ticks never run one step twice. The push of the CLAIM before the work
#      starts is the first line of defence and the CAS is the second, so both
#      are measured: two ticks on one hub, and two clones of one remote where
#      the second tick must see the claim rather than the lock.
#   4. Who measures the facts: the executor, because measuring a fact means
#      reading a board and reading a board is execution. An unmeasurable fact is
#      absent, and absent makes a precheck not hold.
#   5. A failed step stops ITS OWN BRANCH by construction -- ready_steps
#      releases a step only when everything it needs is done -- and nothing
#      else. The planner is recorded as wanted; no planner runs from here.
#   6. Not every non-run is a failure: a broken agent command, a locked or
#      disabled board and a repository this machine does not have are all
#      requeues, because none of them says anything about the plan.
#   7. kind: plan is left pending on purpose -- the coordination agent it wants
#      does not exist -- and the tick says so. kind: question is no longer one
#      of those: it resolves against the mailbox, which is #200 and lives in
#      t/200-foundation-question-steps.t.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

my $LIB = path('lib')->absolute->stringify;
my @KEEP;    # tempdirs vanish with their object

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

sub board_store {
  my ( $repo ) = @_;
  return App::karr::BoardStore->new( git => App::karr::Git->new( dir => "$repo" ) );
}

sub chain_store {
  my ( $hub ) = @_;
  return App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => "$hub" ) );
}

# One line per invocation holding the id the run was given, and the card moved
# to done -- enough to prove which card the chain named and how many agent runs
# a step produced.
sub write_agent {
  my ( $repo ) = @_;
  my $script = path($repo)->child('fake-agent.pl');
  $script->spew_utf8(<<'PERL');
use strict;
use warnings;
my $repo = $ENV{KARR_REPO} or die "no KARR_REPO\n";
my $id   = $ENV{KARR_TASK} // '';
open my $fh, '>>', "$repo/runs.log" or die $!;
print {$fh} "$id\n";
close $fh;
exit 0 unless length $id;
require App::karr::Git;
require App::karr::BoardStore;
my $store = App::karr::BoardStore->new( git => App::karr::Git->new( dir => $repo ) );
my $task  = $store->find_task($id) or die "no task $id\n";
$task->status('done');
$store->save_task($task);
PERL
  return qq{$^X -I"$LIB" "$script"};
}

sub write_karr {
  my ( $repo, %opt ) = @_;
  my $body = '';
  $body .= "$_: $opt{$_}\n" for sort keys %opt;
  path($repo)->child('.karr')->spew_utf8($body);
  return;
}

sub runs_of {
  my ( $repo ) = @_;
  my $log = path($repo)->child('runs.log');
  return () unless $log->exists;
  return grep { defined } split /\n/, $log->slurp_utf8;
}

sub lines_of {
  my ( $file ) = @_;
  return () unless $file->exists;
  return grep { length } split /\n/, $file->slurp_utf8;
}

# STDOUT through a real file, not an in-memory scalar: the runner forks and dups
# the child's stdout onto a pipe, and a scalar filehandle has no descriptor to
# dup onto. The encoding layer is the one F<karr-foundation> installs itself,
# so the em dashes this prints are written as UTF-8 rather than warned about.
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

sub foundation_for {
  my ( $hub, %opt ) = @_;
  return App::karr::Foundation->new( _config_data => { hub => "$hub" }, %opt );
}

sub tick {
  my ( $hub, %opt ) = @_;
  return capture( sub { foundation_for( $hub, %opt )->run('chain') } );
}

sub step_of {
  my ( $hub, $id ) = @_;
  return chain_store($hub)->step($id);
}

sub log_of {
  my ( $hub ) = @_;
  my $store = chain_store($hub);
  return map { $store->run_entries($_) } $store->run_ids;
}

# ---------------------------------------------------------------------------
# Who measures the facts
# ---------------------------------------------------------------------------

subtest 'the executor measures the facts, off one board read' => sub {
  my $repo = make_repo();
  seed_board( $repo,
    { status => 'todo', priority => 'low' },
    { status => 'in-progress', claimed_by => 'someone-else',
      claimed_at => gmtime->datetime . 'Z' },
    { status => 'todo', blocked => 'waiting on a thing' },
  );
  my $hub  = make_repo();
  # The executor holds its foundation weakly, as every other collaborator here
  # does -- the foundation owns them -- so the test has to hold the other end.
  my $f    = foundation_for($hub);
  my $exec = App::karr::Foundation::Executor->new( foundation => $f );

  is_deeply $exec->facts_for(
    { kind => 'ticket', repo => "$repo", ticket => 1 } ),
    { board_actionable => 'yes', ticket_status => 'todo',
      ticket_blocked => 'no', ticket_claimed => '', ticket_links => 'settled' },
    'the vocabulary a precheck may use, for a plain open card';

  is_deeply $exec->facts_for(
    { kind => 'ticket', repo => "$repo", ticket => 2 } ),
    { board_actionable => 'yes', ticket_status => 'in-progress',
      ticket_blocked => 'no', ticket_claimed => 'someone-else',
      ticket_links => 'settled' },
    'the claim name is reported as the card carries it';

  is $exec->facts_for( { kind => 'ticket', repo => "$repo", ticket => 3 } )
    ->{ticket_blocked}, 'yes', 'and a blocked card says so';

  is_deeply $exec->facts_for( { kind => 'ticket', repo => "$repo", ticket => 99 } ),
    { board_actionable => 'yes' },
    'a ticket that is not on the board leaves its facts ABSENT rather than '
    . 'defaulting them -- absent is what makes a precheck not hold';

  is_deeply $exec->facts_for( { kind => 'shell', repo => tempdir( CLEANUP => 1 ) } ),
    {},
    'and a directory that is not a board measures nothing at all';

  my $done = make_repo();
  seed_board( $done, { status => 'done' }, { status => 'todo', blocked => 'why' } );
  is $exec->facts_for( { kind => 'shell', repo => "$done" } )->{board_actionable},
    'no', 'board_actionable uses the foundation\'s own definition of actionable';
};

# ---------------------------------------------------------------------------
# A shell step
# ---------------------------------------------------------------------------

subtest 'a shell step runs, is written back done, and is in the run log' => sub {
  my $repo   = make_repo();
  my $hub    = make_repo();
  my $marker = path($repo)->child('marker');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'shell', repo => "$repo", command => "echo one >> '$marker'" },
  ] );

  my ( $out, $exit ) = tick($hub);
  is $exit, 0, 'the tick finished';
  is_deeply [ lines_of($marker) ], ['one'], 'the command ran, exactly once';

  my $step = step_of( $hub, 1 );
  is $step->{state}, 'done', 'the step is written back as done';
  is $step->{attempts}, 1, 'with the attempt the claim counted';
  ok defined $step->{started} && defined $step->{finished},
    'and both timestamps';
  is $step->{result}{detail}, 'exit=0', 'the result says how it ended';

  my @entries = log_of($hub);
  is_deeply [ map { $_->{event} } @entries ], [qw( start step step end )],
    'the run log opens, records the step twice (running, then its outcome) '
    . 'and closes';
  is $entries[1]{state}, 'running', 'the first step entry is the claim';
  is $entries[2]{state}, 'done',    'the second is the outcome';
  like $out, qr/step 1 \(shell\)/, 'and the tick said what it did';
};

# ---------------------------------------------------------------------------
# A ticket step: the layer above the modes
# ---------------------------------------------------------------------------

subtest 'a ticket step runs the card the CHAIN named, through ticket mode' => sub {
  my $repo = make_repo();
  seed_board( $repo,
    { status => 'todo', priority => 'low' },      # 1: the chain names this one
    { status => 'todo', priority => 'critical' }, # 2: the picker would take this
  );
  # The board says drain. The chain says one card. The chain is the more
  # specific statement, and a board configured to drain must not turn one
  # planned step into a whole drain.
  write_karr( $repo, command => write_agent($repo), mode => 'drain',
    max_runtime => 60 );

  my $hub = make_repo();
  chain_store($hub)->write_chain( [
    { id => 1, kind => 'ticket', repo => "$repo", ticket => 1 },
  ] );

  my ( $out, $exit ) = tick($hub);
  is $exit, 0, 'the tick finished';

  is_deeply [ runs_of($repo) ], ['1'],
    'exactly one agent run, and it was handed the card the chain named -- not '
    . 'the one the picker ranks first, and not a drain';
  is board_store($repo)->find_task(1)->status, 'done', 'that card moved';
  is board_store($repo)->find_task(2)->status, 'todo',
    'and the rest of the board is untouched';

  is step_of( $hub, 1 )->{state}, 'done', 'the step is done';
  like path($repo)->child('.karr.log')->slurp_utf8, qr/TICKET task#1/,
    'the board log shows the run went through ticket mode';
};

# ---------------------------------------------------------------------------
# The precheck: the step is NOT EXECUTED
# ---------------------------------------------------------------------------

subtest 'a step whose precheck no longer holds is not executed at all' => sub {
  my $repo = make_repo();
  seed_board( $repo, { status => 'in-progress' } );
  write_karr( $repo, command => write_agent($repo), max_runtime => 60 );

  my $hub = make_repo();
  chain_store($hub)->write_chain( [
    { id => 1, kind => 'ticket', repo => "$repo", ticket => 1,
      precheck => 'ticket_status == todo' },
  ] );

  my ( $out ) = tick($hub);

  ok !path($repo)->child('runs.log')->exists,
    'THE COMMAND NEVER RAN -- which is the whole mechanism; a step that ends '
    . 'up marked stale after doing its work would be worthless';
  my $step = step_of( $hub, 1 );
  is $step->{state}, 'stale', 'the step is stale';
  like $step->{stale_reason}, qr/ticket_status == todo/,
    'the reason quotes the precheck';
  like $step->{stale_reason}, qr/ticket_status is 'in-progress'/,
    'and names the fact that was measured instead';
  ok !defined $step->{started}, 'it was never even claimed as running';

  my @planner = grep { $_->{event} eq 'planner' } log_of($hub);
  is scalar @planner, 1, 'the run log records that the planner is wanted';
  like $out, qr/the planner is wanted/,
    'and the tick says so out loud, because no planner runs from here yet';

  # The control: the same chain against a board where the precheck holds.
  my $ok_repo = make_repo();
  seed_board( $ok_repo, { status => 'todo' } );
  write_karr( $ok_repo, command => write_agent($ok_repo), max_runtime => 60 );
  my $ok_hub = make_repo();
  chain_store($ok_hub)->write_chain( [
    { id => 1, kind => 'ticket', repo => "$ok_repo", ticket => 1,
      precheck => 'ticket_status == todo' },
  ] );
  tick($ok_hub);
  is_deeply [ runs_of($ok_repo) ], ['1'],
    'and with the same precheck holding, the very same step does run';
};

subtest 'a ticket step whose card is not on the board is stale, not run' => sub {
  my $repo = make_repo();
  seed_board( $repo, { status => 'todo' } );
  write_karr( $repo, command => write_agent($repo), max_runtime => 60 );

  my $hub = make_repo();
  chain_store($hub)->write_chain( [
    { id => 1, kind => 'ticket', repo => "$repo", ticket => 99 },
  ] );

  tick($hub);
  ok !path($repo)->child('runs.log')->exists, 'no agent was started';
  my $step = step_of( $hub, 1 );
  is $step->{state}, 'stale', 'a plan about a card that is gone is out of date';
  like $step->{stale_reason}, qr/ticket 99 is not on the board/,
    'and says which card it could not find';
};

# ---------------------------------------------------------------------------
# What a failure does to the DAG
# ---------------------------------------------------------------------------

subtest 'a failed step stops its own branch and nothing else' => sub {
  my $repo  = make_repo();
  my $hub   = make_repo();
  my $after = path($repo)->child('after');
  my $other = path($repo)->child('other');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'shell', repo => "$repo", command => 'exit 3' },
    { id => 2, kind => 'shell', repo => "$repo", needs => [1],
      command => "echo after >> '$after'" },
    { id => 3, kind => 'shell', repo => "$repo", command => "echo other >> '$other'" },
  ] );

  my ( $out ) = tick($hub);

  is step_of( $hub, 1 )->{state}, 'failed', 'the step that exited non-zero failed';
  is step_of( $hub, 1 )->{result}{exit}, 3, 'with the exit code recorded';

  is step_of( $hub, 2 )->{state}, 'pending',
    'its dependent never became ready -- ready_steps releases a step only when '
    . 'everything it needs is DONE, so the branch prunes itself and nobody has '
    . 'to compute a cascade';
  ok !$after->exists, 'and it certainly did not run';

  is step_of( $hub, 3 )->{state}, 'done',
    'a step on another branch is unaffected: that is what the missing edge means';
  is_deeply [ lines_of($other) ], ['other'], 'and it ran';

  my ( $planner ) = grep { $_->{event} eq 'planner' } log_of($hub);
  is $planner->{step}, '1', 'the planner is wanted for the step that failed';
  is $planner->{policy}, 'plan', 'under the on_stall policy the spec writes';
  like $out, qr/the planner is wanted for step\(s\) 1/,
    'and the operator is told, since the operator is the planner until there '
    . 'is one';
};

# ---------------------------------------------------------------------------
# Not every non-run is a failure
# ---------------------------------------------------------------------------

subtest 'a broken agent command requeues its step instead of failing it' => sub {
  my $repo = make_repo();
  seed_board( $repo, { status => 'todo' } );
  write_karr( $repo, command => 'exit 7', max_runtime => 60 );

  my $hub = make_repo();
  chain_store($hub)->write_chain( [
    { id => 1, kind => 'ticket', repo => "$repo", ticket => 1 },
  ] );

  my ( $out ) = tick($hub);
  my $step = step_of( $hub, 1 );
  is $step->{state}, 'pending',
    'a rate-limited or broken agent command says nothing about the plan, so '
    . 'the step goes back rather than down';
  is $step->{attempts}, 1, 'the attempt is still counted';
  ok !defined $step->{started}, 'and the claim is cleared';
  like $out, qr/requeued/, 'the tick says it requeued it';
};

subtest 'a disabled board requeues a shell step, it does not fail it' => sub {
  my $repo   = make_repo();
  my $hub    = make_repo();
  my $marker = path($repo)->child('marker');
  seed_board( $repo, { status => 'todo' } );
  board_store($repo)->set_foundation_enabled( 0, 'parked on purpose' );

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'shell', repo => "$repo", command => "echo x >> '$marker'" },
  ] );

  tick($hub);
  ok !$marker->exists,
    'the board-level disable wins over a planned step: it is synchronised '
    . 'board state, and "no automated runs here" does not get smaller because '
    . 'the run was planned in the hub';
  is step_of( $hub, 1 )->{state}, 'pending',
    'pending, not failed -- whoever disabled the board is who can enable it';
};

subtest 'a repository this machine does not have is left alone entirely' => sub {
  my $hub = make_repo();
  chain_store($hub)->write_chain( [
    { id => 1, kind => 'shell', repo => '/nonexistent/repo/for/this/test',
      command => 'true' },
  ] );

  my ( $out, $exit ) = tick($hub);
  is $exit, 0, 'not an error';
  my $step = step_of( $hub, 1 );
  is $step->{state}, 'pending', 'the step is untouched';
  ok !defined $step->{attempts},
    'and unclaimed: the chain is shared state and the working copies are not, '
    . 'so this is another machine\'s step, not a broken plan';
  is scalar( grep { $_->{event} eq 'step' } log_of($hub) ), 0,
    'nothing about it in the run log either';
};

# ---------------------------------------------------------------------------
# The seams left open on purpose
# ---------------------------------------------------------------------------

subtest 'a plan step is left pending, and the tick says so' => sub {
  my $repo = make_repo();
  my $hub  = make_repo();
  my $done = path($repo)->child('done');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'plan', note => 'what next?' },
    { id => 2, kind => 'shell', repo => "$repo", needs => [1],
      command => "echo x >> '$done'" },
  ] );

  my ( $out ) = tick($hub);
  is step_of( $hub, 1 )->{state}, 'pending',
    'a plan step waits for the coordination agent, which is not built, not '
    . 'callable from here and not a ticket yet (#194)';
  is step_of( $hub, 2 )->{state}, 'pending', 'and its dependent waits with it';
  ok !$done->exists, 'nothing downstream ran';
  like $out, qr/left pending/, 'the tick says a kind it does not run was reached';
  is scalar( grep { $_->{event} eq 'planner' } log_of($hub) ), 1,
    'and records that this needs somebody it does not have';
};

# ---------------------------------------------------------------------------
# Two ticks, one step
# ---------------------------------------------------------------------------

subtest 'two ticks on one hub run a step exactly once' => sub {
  my $repo   = make_repo();
  my $hub    = make_repo();
  my $marker = path($repo)->child('marker');
  my $go     = path($repo)->child('go');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'shell', repo => "$repo",
      command => "echo run >> '$marker'; sleep 1" },
  ] );

  my @kids;
  for my $i ( 1 .. 2 ) {
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ( $pid ) { push @kids, $pid; next }
    select undef, undef, undef, 0.02 until $go->exists;
    my $out = eval { ( capture( sub { foundation_for($hub)->run('chain') } ) )[0] };
    path($repo)->child("out.$i")->spew_utf8( $out // "died: $@" );
    POSIX::_exit(0);
  }
  $go->spew_utf8('go');
  waitpid $_, 0 for @kids;

  is_deeply [ lines_of($marker) ], ['run'],
    'the command ran once across two simultaneous ticks (with .karr.lock '
    . 'underneath as the second guard, as it is for every other run here)';
  is step_of( $hub, 1 )->{attempts}, 1,
    'and exactly ONE tick ever claimed the step: the compare-and-swap is the '
    . 'exclusion, and it is the board\'s own machinery rather than a second '
    . 'one. Without it the loser claims the step too, is turned away by the '
    . 'board lock, and writes its own verdict over the winner\'s';
  is step_of( $hub, 1 )->{state}, 'done',
    'so the step is done, and stays done';
};

subtest 'the claim is published before the work starts, not after' => sub {
  # Two clones of one remote -- the case a compare-and-swap inside one clone
  # cannot answer: both machines read `pending` out of their own refs and both
  # win their own local CAS. What keeps one step to one machine is the ORDER:
  # pull, claim, PUSH THE CLAIM, then work.
  #
  # The interleaving is made deterministic by the step itself: its command runs
  # the other machine's tick, from inside the window the claim has to cover. If
  # the claim were pushed after the work, the second machine would see `pending`
  # and take the step -- so this asserts what the second machine SAW, which is
  # what separates "it saw the claim" from "it was stopped by the board lock".
  my $remote = tempdir( CLEANUP => 1 );
  push @KEEP, $remote;
  system( 'git', 'init', '-q', '--bare', "$remote" ) == 0 or die 'git init --bare';

  my @hub;
  for my $i ( 0, 1 ) {
    my $dir = tempdir( CLEANUP => 1 );
    push @KEEP, $dir;
    system( "git clone -q '$remote' '$dir' 2>/dev/null" ) == 0 or die 'git clone';
    system( 'git', '-C', "$dir", 'config', 'user.email', 'fleet@example.com' ) == 0 or die;
    system( 'git', '-C', "$dir", 'config', 'user.name', 'Fleet' ) == 0 or die;
    push @hub, $dir;
  }
  my $repo   = make_repo();
  my $marker = path($repo)->child('marker');
  my $seen   = path($repo)->child('seen');

  # The command of the step IS the other machine's tick.
  my $inner = path($repo)->child('inner.pl');
  $inner->spew_utf8(<<"PERL");
use strict;
use warnings;
use App::karr::Foundation;
open my \$m, '>>', "$marker" or die \$!;
print {\$m} "run\\n";
close \$m;
open my \$save, '>&', \\*STDOUT or die \$!;
open STDOUT, '>', "$seen" or die \$!;
App::karr::Foundation->new( _config_data => { hub => "$hub[1]" } )->run('chain');
open STDOUT, '>&', \$save or die \$!;
PERL

  chain_store( $hub[0] )->write_chain( [
    { id => 1, kind => 'shell', repo => "$repo", command => qq{$^X -I"$LIB" "$inner"} },
  ] );
  my $publish = App::karr::Git->new( dir => "$hub[0]" )->push_foundation;
  ok $publish, 'the chain is published so the second machine can see it';

  tick( $hub[0] );

  is_deeply [ lines_of($marker) ], ['run'],
    'the step ran exactly once across two machines';
  my $what_b_saw = $seen->exists ? $seen->slurp_utf8 : '';
  like $what_b_saw, qr/nothing ready/,
    'the second machine found NOTHING READY: the claim reached the remote '
    . 'before the work started, so the step was never readable as pending';
  unlike $what_b_saw, qr/step 1/,
    'it did not get as far as taking the step and being turned away by the '
    . 'board lock -- that would be the same outcome for the wrong reason';
};

# ---------------------------------------------------------------------------
# The command surface
# ---------------------------------------------------------------------------

subtest 'what the command does without a hub, without a chain, and dry' => sub {
  my $err = do {
    local $@;
    eval { App::karr::Foundation->new( _config_data => {} )->run('chain') };
    $@;
  };
  like $err, qr/No usable hub repository/,
    'no hub is an error, exactly as it is for the mailbox: executing a plan '
    . 'nobody else can see is not a smaller version of executing the fleet\'s';

  my $hub = make_repo();
  my ( $out, $exit ) = tick($hub);
  is $exit, 0, 'a hub with no chain written is not a failure';
  like $out, qr/No chain in/, 'it says so';

  my $bad = do {
    local $@;
    eval { foundation_for($hub)->run( 'chain', 'extra' ) };
    $@;
  };
  like $bad, qr/\AUsage:/,
    'and a surplus argument is a usage error (exit 2), not a silent tick';

  my $repo   = make_repo();
  my $marker = path($repo)->child('marker');
  chain_store($hub)->write_chain( [
    { id => 1, kind => 'shell', repo => "$repo", command => "echo x >> '$marker'" },
  ] );

  my ( $dry ) = capture(
    sub { foundation_for( $hub, dry_run => 1 )->run('chain') } );
  like $dry, qr/would run/, '--dry-run says what is ready';
  ok !$marker->exists, 'and runs nothing';
  is step_of( $hub, 1 )->{state}, 'pending', 'and writes nothing back';
  is scalar( chain_store($hub)->run_ids ), 0, 'not even a run log';
};

done_testing;
