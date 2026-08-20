use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use Path::Tiny qw( path tempdir );

use App::karr::Foundation;
use App::karr::Foundation::Executor;
use App::karr::Foundation::ChainStore;
use App::karr::Foundation::Questions;
use App::karr::Git;

# Ticket #200, the last executable seam of the fleet-execution epic (#194): the
# question mailbox has existed since #191 and nothing in the runner read a word
# of it. A `kind: question` step could be planned and depended on, and no tick
# ever waited on one -- it was recognised, left pending and re-planned, for ever.
#
# What is pinned here, and why each is a decision rather than an accident:
#
#   1. The step RESOLVES a question, it does not ask one. The planner asks with
#      `karr-foundation ask --step ID` before the step can become ready. A
#      self-asking step would have to carry the question text, options, policy,
#      default and deadline in the chain -- the mailbox's schema written out a
#      second time.
#   2. Which means a ready question step nothing in the mailbox names is a
#      PLANNING ERROR and must be visible as one: stale, with the reason, like
#      a ticket step whose card is not on the board. The one outcome that is
#      forbidden is waiting quietly for a question that is never coming.
#   3. `open` waits: pending, unclaimed, dependents wait with it -- and the tick
#      does not hang on it. Every other branch of the chain runs in the same
#      tick.
#   4. `answered` is done, and the answer is in the run log. It is not copied
#      into a field on the step: the step schema is the planner's vocabulary.
#   5. `overdue` does what the ASKER wrote down. block keeps waiting (that is
#      what block means), use_default takes the default resolve() hands over,
#      and escalate_to_ai can only be RECORDED here -- the coordination agent
#      that policy names is the judgement layer, and it is called once at the
#      end of a tick (#210), never from inside the resolution of one question.
#      Resolving the question on that agent's behalf would mean inventing it.
#   6. `question_state` is a fact like the board facts, measured by the
#      executor, absent when it cannot be measured -- and measured only for the
#      kind that can have a question, so no other step pays a mailbox read.
#   7. A step waits for EVERY question naming it. Letting the first answer
#      release a step somebody asked a second question about would drop an
#      unanswered question on the floor.
#
# Everything runs in throwaway repositories; no agent is ever started, and the
# only command any step runs is an echo into a file.

my @KEEP;    # tempdirs vanish with their object

sub make_repo {
  my $dir = tempdir( CLEANUP => 1 );
  push @KEEP, $dir;
  system( 'git', '-C', "$dir", 'init', '-q' ) == 0 or die 'git init';
  system( 'git', '-C', "$dir", 'config', 'user.email', 'fleet@example.com' ) == 0 or die;
  system( 'git', '-C', "$dir", 'config', 'user.name', 'Fleet' ) == 0 or die;
  return $dir;
}

sub chain_store {
  my ( $hub ) = @_;
  return App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => "$hub" ) );
}

sub mailbox {
  my ( $hub ) = @_;
  return App::karr::Foundation::Questions->new(
    git => App::karr::Git->new( dir => "$hub" ) );
}

# STDOUT through a real file rather than an in-memory scalar: a shell step
# forks and dups the child's stdout onto a pipe, and a scalar filehandle has no
# descriptor to dup onto. The encoding layer is the one F<karr-foundation>
# installs itself, so the em dashes this prints are written as UTF-8 rather
# than warned about.
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

sub entries_for {
  my ( $hub, $event, $step ) = @_;
  return grep {
    $_->{event} eq $event
      && ( !defined $step || ( defined $_->{step} && $_->{step} eq "$step" ) )
  } log_of($hub);
}

# A deadline that has already passed. `ask` refuses a policy without one and
# would refuse a wait of zero seconds, so this is how a test reaches `overdue`
# without sleeping through a real deadline.
my $PAST = '2020-01-01T00:00:00Z';

# ---------------------------------------------------------------------------
# open: wait, and hold nothing else up
# ---------------------------------------------------------------------------

subtest 'an open question leaves its step pending and stops nothing else' => sub {
  my $repo = make_repo();
  my $hub  = make_repo();
  my $held = path($repo)->child('held');
  my $free = path($repo)->child('free');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'question' },
    { id => 2, kind => 'shell', repo => "$repo", needs => [1],
      command => "echo x >> '$held'" },
    { id => 3, kind => 'shell', repo => "$repo",
      command => "echo x >> '$free'" },
  ] );
  my $qid = mailbox($hub)->ask( question => 'Which registry?', step => 1 );

  my ( $out, $exit ) = tick($hub);
  is $exit, 0, 'the tick finished -- waiting on an answer is not a failure';

  my $step = step_of( $hub, 1 );
  is $step->{state}, 'pending', 'the question step waits for its answer';
  ok !defined $step->{attempts},
    'and is left UNCLAIMED: nothing ran, so there is no attempt to count and '
    . 'the next tick finds the step as the planner left it';
  ok !defined $step->{started}, 'and carries no started stamp';

  is step_of( $hub, 2 )->{state}, 'pending', 'its dependent waits with it';
  ok !$held->exists, 'and did not run';
  is step_of( $hub, 3 )->{state}, 'done',
    'while the branch that does not go through the question runs in the same '
    . 'tick -- a question holds up its own dependents, not the chain';
  ok $free->exists, 'and really ran';

  my ( $entry ) = entries_for( $hub, 'step', 1 );
  is $entry->{state}, 'pending', 'the run log records the wait';
  like $entry->{detail}, qr/question #\Q$qid\E is unanswered/,
    'naming the question that is holding the step up';
  is scalar( entries_for( $hub, 'planner' ) ), 0,
    'and does NOT call for the planner: an unanswered question is somebody '
    . 'being asked, not a plan that has broken';
  like $out, qr/left pending/, 'the tick says so out loud';
};

# ---------------------------------------------------------------------------
# answered
# ---------------------------------------------------------------------------

subtest 'an answered question finishes the step, with the answer in the log' => sub {
  my $repo = make_repo();
  my $hub  = make_repo();
  my $next = path($repo)->child('next');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'question' },
    { id => 2, kind => 'shell', repo => "$repo", needs => [1],
      command => "echo x >> '$next'" },
  ] );
  my $mb  = mailbox($hub);
  my $qid = $mb->ask( question => 'Which registry?',
    options => [ 'cpan', 'darkpan' ], step => 1 );

  tick($hub);
  is step_of( $hub, 1 )->{state}, 'pending', 'unanswered, the step waits';

  $mb->settle( $qid, 'darkpan' );
  my ( $out ) = tick($hub);

  my $step = step_of( $hub, 1 );
  is $step->{state}, 'done', 'answered, the step is done';
  is $step->{attempts}, 1, 'claimed exactly once, like any other step';
  like $step->{result}{detail}, qr/answered 'darkpan'/,
    'and its result records what the answer was';
  ok !exists $step->{answer},
    'the answer is NOT copied into a field of its own on the step: the step '
    . 'schema is the planner\'s vocabulary, and an answer in it would be the '
    . 'mailbox\'s schema kept in a second place';

  my ( $done ) = grep { $_->{state} eq 'done' } entries_for( $hub, 'step', 1 );
  like $done->{detail}, qr/question #\Q$qid\E answered 'darkpan'/,
    'the run log carries the answer, which is where anybody reading back what '
    . 'the fleet decided will look for it';
  like $done->{detail}, qr/by /, 'and who gave it';

  is step_of( $hub, 2 )->{state}, 'done',
    'the dependent is released, in the same tick: the round after the one '
    . 'that resolved the question sees it ready';
  ok $next->exists, 'and really ran';
  like $out, qr/step 1 \(question\): done/, 'the tick says what it did';
};

subtest 'an answer that arrives before the step does' => sub {
  my $repo = make_repo();
  my $hub  = make_repo();
  my $first = path($repo)->child('first');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'shell', repo => "$repo", command => "echo x >> '$first'" },
    { id => 2, kind => 'question', needs => [1] },
  ] );
  my $mb  = mailbox($hub);
  my $qid = $mb->ask( question => 'Ship it?', step => 2 );
  $mb->settle( $qid, 'yes' );

  tick($hub);
  is step_of( $hub, 2 )->{state}, 'done',
    'a question answered long before its step became ready is simply there '
    . 'when the step arrives, and the step never waits at all';
};

# ---------------------------------------------------------------------------
# overdue: what the asker wrote down
# ---------------------------------------------------------------------------

subtest 'overdue + block keeps waiting, because that is what block means' => sub {
  my $hub = make_repo();
  chain_store($hub)->write_chain( [ { id => 1, kind => 'question' } ] );
  mailbox($hub)->ask( question => 'Which registry?', step => 1,
    deadline => $PAST );

  my ( $out ) = tick($hub);
  my $step = step_of( $hub, 1 );
  is $step->{state}, 'pending', 'a passed deadline under block changes nothing';
  ok !defined $step->{attempts}, 'the step is not even claimed';
  is scalar( entries_for( $hub, 'planner' ) ), 0,
    'and nobody is called: block is the only policy that never invents an '
    . 'answer, and waiting for a person IS the plan';
  like $out, qr/block policy keeps waiting/, 'the tick says which policy it is';
};

subtest 'overdue + use_default takes the default as the answer' => sub {
  my $repo = make_repo();
  my $hub  = make_repo();
  my $next = path($repo)->child('next');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'question' },
    { id => 2, kind => 'shell', repo => "$repo", needs => [1],
      command => "echo x >> '$next'" },
  ] );
  my $qid = mailbox($hub)->ask( question => 'Which registry?',
    options => [ 'cpan', 'darkpan' ], default => 'cpan',
    policy => 'use_default', deadline => $PAST, step => 1 );

  tick($hub);
  is step_of( $hub, 1 )->{state}, 'done',
    'the deadline passed and the policy says what to do, so the step is done';
  like step_of( $hub, 1 )->{result}{detail}, qr/default 'cpan'/,
    'with the default as the answer';

  my ( $done ) = grep { $_->{state} eq 'done' } entries_for( $hub, 'step', 1 );
  like $done->{detail}, qr/question #\Q$qid\E went unanswered past its deadline/,
    'and the run log says the answer came from the deadline rather than from '
    . 'a person -- the two are not the same decision';
  is step_of( $hub, 2 )->{state}, 'done', 'the dependent is released';
  ok $next->exists, 'and ran';
};

subtest 'overdue + escalate_to_ai can only be recorded' => sub {
  my $repo = make_repo();
  my $hub  = make_repo();
  my $next = path($repo)->child('next');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'question' },
    { id => 2, kind => 'shell', repo => "$repo", needs => [1],
      command => "echo x >> '$next'" },
  ] );
  my $qid = mailbox($hub)->ask( question => 'Which registry?',
    policy => 'escalate_to_ai', deadline => $PAST, step => 1 );

  my ( $out ) = tick($hub);
  my $step = step_of( $hub, 1 );
  is $step->{state}, 'pending',
    'the coordination agent this policy names is not callable from inside the '
    . 'resolution of one question (#210 calls it once per tick), so the step '
    . 'waits';
  ok !defined $step->{attempts}, 'unclaimed, with nothing written to undo';
  ok !$next->exists, 'and nothing downstream was released on an invented answer';

  my ( $planner ) = entries_for( $hub, 'planner', 1 );
  ok $planner, 'the planner IS recorded as wanted -- a chain that cannot '
    . 'proceed must not do it quietly';
  is $planner->{policy}, 'escalate_to_ai',
    'under the policy that asked for it, not under a generic one';
  like $planner->{reason}, qr/question #\Q$qid\E/, 'naming the question';
  like $out, qr/policy wants the coordination agent/,
    'and the tick says out loud which policy left the step where it is';
};

# ---------------------------------------------------------------------------
# The planning error
# ---------------------------------------------------------------------------

subtest 'a ready question step nothing in the mailbox names is a planning error' => sub {
  my $repo = make_repo();
  my $hub  = make_repo();
  my $next = path($repo)->child('next');

  chain_store($hub)->write_chain( [
    { id => 1, kind => 'question', note => 'which registry?' },
    { id => 2, kind => 'shell', repo => "$repo", needs => [1],
      command => "echo x >> '$next'" },
  ] );
  # A question that names a different step is not this step's question, so the
  # walk has to be a match and not merely "the mailbox is not empty".
  mailbox($hub)->ask( question => 'Something else entirely?', step => 2 );

  my ( $out, $exit ) = tick($hub);
  is $exit, 0, 'the tick itself is fine';

  my $step = step_of( $hub, 1 );
  isnt $step->{state}, 'pending',
    'the step must NOT sit and wait: the question is written before the step '
    . 'can become ready, so an empty mailbox here means it never was';
  is $step->{state}, 'stale',
    'it is stale, the same answer a ticket step gets when its card is not on '
    . 'the board -- the plan is about something that is not there';
  like $step->{stale_reason}, qr/no question in the mailbox names step 1/,
    'with the reason on the step';

  my ( $entry ) = entries_for( $hub, 'step', 1 );
  is $entry->{state}, 'stale', 'the run log records the state';
  like $entry->{detail}, qr/it does not ask itself/,
    'and the reason, in the language the executor uses everywhere else';
  my ( $planner ) = entries_for( $hub, 'planner', 1 );
  ok $planner, 'the planner is recorded as wanted';
  like $out, qr/no question was ever asked about it/,
    'and the tick names the mistake in its closing report';
  ok !$next->exists, 'nothing downstream ran';
};

# ---------------------------------------------------------------------------
# More than one question on one step
# ---------------------------------------------------------------------------

subtest 'a step waits for every question naming it' => sub {
  my $hub = make_repo();
  chain_store($hub)->write_chain( [ { id => 1, kind => 'question' } ] );
  my $mb = mailbox($hub);
  my $a  = $mb->ask( question => 'Which registry?', step => 1 );
  my $b  = $mb->ask( question => 'Which branch?',   step => 1 );

  $mb->settle( $a, 'darkpan' );
  tick($hub);
  is step_of( $hub, 1 )->{state}, 'pending',
    'one answer does not release a step somebody asked a second question '
    . 'about: the unanswered one is work nobody has done yet';

  $mb->settle( $b, 'main' );
  tick($hub);
  is step_of( $hub, 1 )->{state}, 'done', 'both answered, the step is done';
  my $detail = step_of( $hub, 1 )->{result}{detail};
  like $detail, qr/question #\Q$a\E answered 'darkpan'/, 'the first answer is recorded';
  like $detail, qr/question #\Q$b\E answered 'main'/,    'and the second';
};

# ---------------------------------------------------------------------------
# The fact
# ---------------------------------------------------------------------------

subtest 'question_state is a fact, and only for the kind that has a question' => sub {
  my $hub = make_repo();
  # The executor holds its foundation weakly -- the foundation owns it -- so
  # the test has to hold the other end.
  my $f    = foundation_for($hub);
  my $exec = App::karr::Foundation::Executor->new( foundation => $f );
  my $mb   = mailbox($hub);

  my $open = $mb->ask( question => 'Which registry?', step => 1 );
  is_deeply $exec->facts_for( { id => 1, kind => 'question' } ),
    { question_state => 'open' },
    'the fact is the state resolve() gives, and a question step measures '
    . 'nothing else';

  my $late = $mb->ask( question => 'Which branch?', step => 2,
    default => 'main', policy => 'use_default', deadline => $PAST );
  is $exec->facts_for( { id => 2, kind => 'question' } )->{question_state},
    'overdue',
    'an overdue question reports overdue even where its policy will settle '
    . 'the step: the fact is about the question, the policy is a separate '
    . 'thing the plan can read';

  $mb->settle( $open, 'darkpan' );
  is $exec->facts_for( { id => 1, kind => 'question' } )->{question_state},
    'answered', 'and an answered one says so';

  is_deeply $exec->facts_for( { id => 9, kind => 'question' } ), {},
    'a question step nothing names measures NOTHING rather than defaulting to '
    . 'a state -- absent is what makes a precheck about it fail safe';

  my $repo = make_repo();
  $mb->ask( question => 'About a shell step?', step => 3 );
  ok !exists $exec->facts_for(
    { id => 3, kind => 'shell', repo => "$repo", command => 'true' } )
    ->{question_state},
    'and a step of another kind measures no question at all, even where one '
    . 'names it: gating a step is what the DAG edges are for, and every step '
    . 'would otherwise pay a mailbox read for a fact it cannot use';
};

subtest 'a precheck about the question is decided before the answer is' => sub {
  my $hub = make_repo();
  chain_store($hub)->write_chain( [
    { id => 1, kind => 'question', precheck => 'question_state == open' },
  ] );
  my $mb  = mailbox($hub);
  my $qid = $mb->ask( question => 'Which registry?', step => 1 );
  $mb->settle( $qid, 'darkpan' );

  tick($hub);
  is step_of( $hub, 1 )->{state}, 'stale',
    'the precheck is measured with the new fact and settles the step first: '
    . 'a plan that assumed nobody had answered yet is out of date, and karr '
    . 'does not get to be cleverer than the plan it was given';
};

# ---------------------------------------------------------------------------
# The dry run
# ---------------------------------------------------------------------------

subtest 'a dry run says what a question step would do, and writes nothing' => sub {
  my $hub = make_repo();
  chain_store($hub)->write_chain( [ { id => 1, kind => 'question' } ] );

  my ( $none ) = tick( $hub, dry_run => 1 );
  like $none, qr/no question in the mailbox names it/,
    'a dry run does not say "would run" about a step that is going to go '
    . 'stale -- that would be the one line of this command nobody could trust';

  mailbox($hub)->ask( question => 'Which registry?', step => 1 );
  my ( $out ) = tick( $hub, dry_run => 1 );
  like $out, qr/would wait/, 'nor about one that is going to wait';

  is step_of( $hub, 1 )->{state}, 'pending', 'and it writes nothing back';
  is scalar( chain_store($hub)->run_ids ), 0, 'not even a run log';
};

done_testing;
