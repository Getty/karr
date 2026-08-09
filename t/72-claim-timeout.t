use strict;
use warnings;
use Test::More;
use Time::Piece;

use App::karr::Task;

# Ticket #63: App::karr::Role::ClaimTimeout had no direct coverage at all.
# Mutating `return $1 * 60` to `$1 * 3600` (minutes parsed as hours) and
# replacing the whole of _claim_expired with `return 0` (no claim ever expires,
# so `karr pick` can never take over a stale claim) both left the suite green --
# the role is only exercised indirectly by pick/handoff, and only through claims
# that were fresh either way.

{
  package TimeoutConsumer;
  use Moo;
  with 'App::karr::Role::ClaimTimeout';
}

my $c = TimeoutConsumer->new;

subtest '_parse_timeout' => sub {
  is( $c->_parse_timeout('1h'),  3600,  '1h' );
  is( $c->_parse_timeout('2h'),  7200,  '2h' );
  is( $c->_parse_timeout('24h'), 86400, '24h' );

  # The mutation that survived: minutes are minutes, not hours.
  is( $c->_parse_timeout('1m'),  60,    '1m is 60 seconds, not 3600' );
  is( $c->_parse_timeout('30m'), 1800,  '30m' );
  is( $c->_parse_timeout('90m'), 5400,  '90m' );

  # Anything unparseable falls back to one hour rather than to zero, which
  # would make every claim instantly stealable.
  is( $c->_parse_timeout(undef), 3600, 'undef falls back to 1h' );
  is( $c->_parse_timeout(''),    3600, 'empty string falls back to 1h' );
  is( $c->_parse_timeout('0'),   3600, 'a bare 0 falls back to 1h' );
  is( $c->_parse_timeout('7d'),  3600, 'an unsupported unit falls back to 1h' );
  is( $c->_parse_timeout('1 h'), 3600, 'a malformed value falls back to 1h' );
  is( $c->_parse_timeout('h'),   3600, 'a unit with no number falls back to 1h' );
};

sub _task_claimed_secs_ago {
  my ($secs) = @_;
  my $ts = defined $secs ? gmtime( time - $secs )->datetime . 'Z' : undef;
  return App::karr::Task->new(
    id    => 1,
    title => 'Claimed card',
    ( defined $ts ? ( claimed_by => 'agent-fox', claimed_at => $ts ) : () ),
  );
}

subtest '_claim_expired' => sub {
  # Both sides of the decision, so `return 0` and `return 1` are each fatal.
  ok( !$c->_claim_expired( _task_claimed_secs_ago(60), 3600 ),
    'a claim one minute old is still live under a 1h timeout' );
  ok( $c->_claim_expired( _task_claimed_secs_ago(7200), 3600 ),
    'a claim two hours old has expired under a 1h timeout' );

  # And that the timeout argument is actually consulted.
  ok( $c->_claim_expired( _task_claimed_secs_ago(120), 60 ),
    'the same claim expires under a 1m timeout' );
  ok( !$c->_claim_expired( _task_claimed_secs_ago(120), 86400 ),
    'and does not under a 24h timeout' );

  # An unclaimed task is not "expired": pick treats has_claimed_at as the
  # question and would otherwise double-count it.
  ok( !$c->_claim_expired( _task_claimed_secs_ago(undef), 0 ),
    'a task that was never claimed is not expired' );

  # A stamp karr did not write must not silently read as expired either.
  my $bad = App::karr::Task->new(
    id => 2, title => 'Bad stamp',
    claimed_by => 'agent-fox', claimed_at => 'not-a-timestamp',
  );
  ok( !$c->_claim_expired( $bad, 0 ), 'an unparseable claimed_at is not treated as expired' );
};

done_testing;
