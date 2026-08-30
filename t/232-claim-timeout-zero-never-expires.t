# t/232-claim-timeout-zero-never-expires.t
#
# Ticket #232. `claim_timeout: 0s` is documented as "claims never expire" --
# in App::karr::Role::ClaimTimeout/claim_timeout_secs, in the comment over
# _parse_timeout, and by the implementation it is parity with (kanban-md's
# internal/board/filter.go, whose IsUnclaimed asks `timeout > 0 && ClaimedAt !=
# nil` and falls through to "still claimed" on a zero timeout).
#
# It did the exact opposite. _parse_timeout handed the zero through verbatim,
# which is right, and _claim_expired then asked `(now - claimed_at) > 0` -- true
# of every claim more than a second old. So the one setting a board uses to say
# "claims are binding here" was the setting that made every card free for the
# taking, seconds after it was claimed, with nothing said anywhere:
#
#     karr config set claim_timeout 0s
#     karr move 1 in-progress --claim agent-a
#     karr pick --claim agent-b
#     -> Picked task 1: A (claimed by agent-b)
#
# Four things are pinned here, and the last three matter as much as the first:
#
#   * zero means never: pick, edit and move all leave a claimed card alone, and
#     expired_claim_report has nothing to report because nothing expired;
#   * a real timeout still expires, and taking the claim over is still
#     announced (#177) -- the fix must not be "no claim ever expires again";
#   * a negative or unparseable claim_timeout still falls back to one hour
#     rather than reaching the new guard and reading as "never";
#   * the same zero on the lock side -- App::karr::Lock/expired, reached from
#     `lock_timeout: 0s` -- answers the same way. Those are two separate
#     guards that have to agree, and drifting apart is what produced this
#     ticket: the lock side read its zero correctly for as long as the claim
#     side read it backwards, because they only look alike. Both answers are
#     asserted in this one file so losing either of them goes red here.
#
# Never the developer's own board: every repository below is a tempdir.
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use MockStore;
use File::Temp qw( tempdir );
use Time::Piece;

use App::karr::Config;
use App::karr::Git;
use App::karr::Lock;
use App::karr::Task;

my $HOLDER   = 'agent-holder';
my $TAKEOVER = 'agent-takeover';

{
  package ZeroTimeoutConsumer;
  use Moo;
  # The three names the role requires. store is the real question here: unlike
  # t/72's stub, check_claim below has to read a board's claim_timeout back out
  # of it, so this one is a MockStore carrying the value under test.
  has store => ( is => 'ro' );
  sub json  { 0 }
  sub quiet { 0 }
  with 'App::karr::Role::ClaimTimeout';
}

sub _consumer_for {
  my ($timeout) = @_;
  my $ec = App::karr::Config->default_config;
  $ec->{claim_timeout} = $timeout;
  return ZeroTimeoutConsumer->new( store => MockStore->new( ec => $ec ) );
}

sub _claimed_secs_ago {
  my ($secs) = @_;
  return App::karr::Task->new(
    id         => 1,
    title      => 'Held card',
    status     => 'in-progress',
    claimed_by => $HOLDER,
    claimed_at => gmtime( time - $secs )->datetime . 'Z',
  );
}

subtest 'the comparison itself: zero is not a very short window' => sub {
  my $c   = _consumer_for('1h');
  my $old = _claimed_secs_ago(7200);

  # The counter-probe first, so "nothing ever expires" cannot pass this file:
  # a two-hour-old claim under the default one-hour window is expired, and
  # every assertion below is the same task judged against a different number.
  ok( $c->_claim_expired( $old, 3600 ),
    'a two-hour-old claim has expired under a 1h timeout' );

  ok( !$c->_claim_expired( $old, 0 ),
    'the same claim has NOT expired under a timeout of 0 -- zero disables expiry' );
  ok( !$c->_claim_expired( _claimed_secs_ago(86400 * 30), 0 ),
    'and neither has one a month old: zero is never, not sooner' );

  # Answered like zero rather than like a duration, exactly as
  # App::karr::Lock/expired answers a negative ttl. No board can produce this
  # (see the _parse_timeout subtest), but "not a positive window" is the whole
  # question the guard asks.
  ok( !$c->_claim_expired( $old, -1 ),
    'a negative timeout disables expiry too' );

  ok( !$c->_claim_expired( _claimed_secs_ago(60), 3600 ),
    'a fresh claim under a real window is still live' );
};

subtest 'the parse: which values ever reach that comparison' => sub {
  my $c = _consumer_for('1h');

  is( $c->_parse_timeout('0s'), 0,
    '0s is honoured verbatim -- it must reach the comparison as a zero' );
  is( $c->claim_timeout_secs, 3600, 'a board saying 1h reads back as 3600' );
  is( _consumer_for('0s')->claim_timeout_secs, 0,
    'a board saying 0s reads back as 0, not as the fallback' );

  # The fallback still catches everything that is not a duration, so the new
  # guard is never reached by an accident. A negative one especially: it parses
  # and would otherwise be read as "claims never expire" on a board that meant
  # nothing of the sort.
  is( $c->_parse_timeout('-5m'), 3600, 'a negative duration falls back to 1h' );
  is( _consumer_for('-5m')->claim_timeout_secs, 3600,
    '...on the board level too, so it never lands on the zero guard' );
  is( $c->_parse_timeout('7d'),    3600, 'an unsupported unit falls back to 1h' );
  is( $c->_parse_timeout('later'), 3600, 'a non-duration falls back to 1h' );
  is( $c->_parse_timeout('0'),     3600,
    'a bare 0 with no unit keeps its historical fallback, unchanged by this fix' );
  is( $c->_parse_timeout(undef),   3600, 'an absent value falls back to 1h' );
};

# The consumers above neither --json nor --quiet, so expired_claim_report
# writes its human copy to STDERR. Captured rather than let through, both to
# keep the run's output clean and because "reports nothing" is half of what
# this ticket is about: the return value and the line have to agree.
sub _report_from {
  my ( $consumer, $id ) = @_;
  my $captured = '';
  my @pairs;
  {
    open my $fh, '>', \$captured or die "in-memory STDERR: $!";
    local *STDERR = $fh;
    @pairs = $consumer->expired_claim_report($id);
  }
  return ( \@pairs, $captured );
}

subtest 'check_claim and expired_claim_report under 0s' => sub {
  my $old = _claimed_secs_ago(7200);

  my $zero = _consumer_for('0s');
  my $ok   = eval { $zero->check_claim( $old, $TAKEOVER ); 1 };
  ok( !$ok, 'a foreign name is refused however old the claim is' );
  like( $@, qr/\QTask 1 is claimed by $HOLDER\E/,
    '...with the wording that names the holder' );

  my ( $pairs, $said ) = _report_from( $zero, 1 );
  is_deeply( $pairs, [],
    'nothing is reported as overridden, because nothing was' );
  is( $said, '', '...and nothing is said on STDERR either' );

  ok( $zero->check_claim( $old, $HOLDER ),
    'the holder itself still proceeds under 0s' );

  # The same call on a board with a real window: still a takeover, still
  # recorded (#177). The two consumers differ in exactly one config value.
  my $hour = _consumer_for('1h');
  ok( $hour->check_claim( $old, $TAKEOVER ),
    'the same two-hour-old claim is stepped over on a 1h board' );
  ( $pairs, $said ) = _report_from( $hour, 1 );
  is( $pairs->[0], 'expired_claim', 'the override is reported as a pair' );
  is( $pairs->[1]{held_by}, $HOLDER, '...naming the previous holder' );
  like( $said, qr/\Qoverriding the expired claim held by $HOLDER\E/,
    '...and said out loud as well' );
};

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

sub _setup_board {
  my (%opt) = @_;
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
    or BAIL_OUT('git config failed');
  system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
    or BAIL_OUT('git config failed');

  my $init = _run_karr( $repo, 'init', '--name', 'Ticket232 Board' );
  is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

  my $cfg = _run_karr( $repo, 'config', 'set', 'claim_timeout', $opt{claim_timeout} );
  is( $cfg->{exit}, 0, "claim_timeout set to $opt{claim_timeout}" )
    or diag $cfg->{stderr};

  for my $n ( 1 .. $opt{tasks} ) {
    my $rv = _run_karr( $repo, 'create', "Task $n" );
    is( $rv->{exit}, 0, "task $n created" ) or diag $rv->{stderr};
  }
  return $repo;
}

subtest 'end to end: 0s keeps a claimed card off every other agent' => sub {
  my $repo = _setup_board( claim_timeout => '0s', tasks => 3 );

  my $claim = _run_karr( $repo, 'move', '1,2,3', 'in-progress', '--claim', $HOLDER );
  is( $claim->{exit}, 0, 'the holder claims all three cards' )
    or diag $claim->{stderr};

  # Old enough that the broken comparison called every one of them expired,
  # and no board age at all under a timeout that means "never".
  sleep 2;

  my $pick = _run_karr( $repo, 'pick', '--claim', $TAKEOVER );
  like( $pick->{stdout}, qr/No available tasks to pick/,
    'pick finds nothing: a live claim under 0s is not pickable' )
    or diag $pick->{stdout};
  unlike( $pick->{stdout}, qr/Picked task/, '...and hands out no card at all' );

  my $edit = _run_karr( $repo, 'edit', '1', '-a', 'stolen note',
    '--claim', $TAKEOVER );
  isnt( $edit->{exit}, 0, 'edit under another name is refused' );
  like( $edit->{stderr}, qr/\QTask 1 is claimed by $HOLDER\E/,
    '...naming the holder' );

  my $move = _run_karr( $repo, 'move', '2', 'review', '--claim', $TAKEOVER );
  isnt( $move->{exit}, 0, 'move under another name is refused' );
  like( $move->{stderr}, qr/\QTask 2 is claimed by $HOLDER\E/,
    '...naming the holder' );

  unlike( "$pick->{stderr}$edit->{stderr}$move->{stderr}", qr/expired claim/,
    'nothing anywhere reports an expired claim: under 0s none can expire' );

  my $show = _run_karr( $repo, 'show', '1' );
  like( $show->{stdout}, qr/^Claimed:\s+\Q$HOLDER\E$/m,
    'the card still belongs to the agent that claimed it' );

  my $own = _run_karr( $repo, 'move', '1', 'review', '--claim', $HOLDER );
  is( $own->{exit}, 0, 'the holder still works its own card' )
    or diag $own->{stderr};

  # 0s must not wedge the board: releasing is still the way out, and the card
  # is pickable the moment it is unclaimed.
  my $release = _run_karr( $repo, 'edit', '3', '--release' );
  is( $release->{exit}, 0, 'the claim can still be released' )
    or diag $release->{stderr};
  my $after = _run_karr( $repo, 'pick', '--claim', $TAKEOVER );
  like( $after->{stdout}, qr/Picked task 3/,
    'and the released card is picked by the next agent' )
    or diag $after->{stdout};
};

subtest 'end to end: a real timeout still expires and still says so' => sub {
  my $repo = _setup_board( claim_timeout => '1s', tasks => 1 );

  my $claim = _run_karr( $repo, 'move', '1', 'in-progress', '--claim', $HOLDER );
  is( $claim->{exit}, 0, 'the holder claims the card' ) or diag $claim->{stderr};

  sleep 2;

  my $handoff = _run_karr( $repo, 'handoff', '1', '--claim', $TAKEOVER,
    '--note', 'taking over' );
  is( $handoff->{exit}, 0, 'the takeover of an expired claim still succeeds' )
    or diag $handoff->{stderr};
  like( $handoff->{stderr},
    qr/task 1: overriding the expired claim held by \Q$HOLDER\E/,
    '...and is still announced (#177)' );

  my $show = _run_karr( $repo, 'show', '1' );
  like( $show->{stdout}, qr/^Claimed:\s+\Q$TAKEOVER\E$/m,
    'the card really did change hands' );
};

subtest 'the lock side answers its own zero the same way' => sub {
  # Not App::karr::Lock's own test -- that is t/83 -- but the pin that keeps
  # the two guards from drifting again. `lock_timeout: 0s` and
  # `claim_timeout: 0s` are the same sentence about two different refs, and
  # they are enforced by two separate lines of code.
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
    or BAIL_OUT('git config failed');
  system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
    or BAIL_OUT('git config failed');

  my $git = App::karr::Git->new( dir => $repo );
  my ($ok) = App::karr::Lock->new( git => $git, ttl => 300 )
    ->acquire( 1, 'ghost@example.com' );
  ok( $ok, 'a lock is taken' );

  # A lock's age is the committer time of its commit, so the only honest way
  # to put it behind a one-second ttl is to wait past it.
  sleep 2;
  my ($oid) = $git->read_ref_with_oid( App::karr::Lock->LOCK_ROOT . '1/lock' );

  ok( App::karr::Lock->new( git => $git, ttl => 1 )->expired($oid),
    'the lock is past a 1s ttl' );
  ok( !App::karr::Lock->new( git => $git, ttl => 0 )->expired($oid),
    'a ttl of 0 disables lock expiry, the same answer the claim side now gives' );
  ok( !App::karr::Lock->new( git => $git, ttl => -1 )->expired($oid),
    'and so does a negative ttl' );
};

done_testing;
