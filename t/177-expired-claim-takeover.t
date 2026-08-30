use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );

# Ticket #177, the behavioural half of #176. An expired claim no longer blocks
# anybody -- that is what claim_timeout is *for*, and this test does not try to
# take it back. What it pins is that stepping over one is no longer silent.
#
# Before this change the two halves of the same mismatch answered completely
# differently:
#
#   live claim, other name      refused, exit 1, "Task 1 is claimed by <A>"
#   expired claim, other name   "Handed off task 1 -> review", exit 0, card
#                               re-stamped to <B>, nothing said anywhere
#
# So the one signal that names the previous holder disappeared exactly when it
# was most useful: an agent that lost its own claim name (#176, `karr agentname`
# mints a fresh one per call) got a success instead of the hint, and
# karr-foundation -- which attributes stalls per claim name -- had its
# attribution moved to a name nobody held, with no record that the card had ever
# belonged to someone else.
#
# App::karr::Role::ClaimTimeout::check_claim now records the override and the
# commands emit it after the write lands, the way
# App::karr::Role::DependencyCheck already reports unsatisfied dependencies:
# STDERR for humans, the `expired_claim` pair under --json, silenced by --quiet.
# Return value and exit code are deliberately unchanged.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

# Always a throwaway repo; never the developer's real board.
sub _setup_repo {
    my (%opt) = @_;
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init failed';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
      or die 'git config failed';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
      or die 'git config failed';

    my $init = _run_karr( $repo, 'init', '--name', 'Ticket177 Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    if ( $opt{claim_timeout} ) {
        my $cfg = _run_karr( $repo, 'config', 'set', 'claim_timeout',
            $opt{claim_timeout} );
        is( $cfg->{exit}, 0, "claim_timeout set to $opt{claim_timeout}" )
          or diag $cfg->{stderr};
    }

    for my $n ( 1 .. ( $opt{tasks} || 1 ) ) {
        my $rv = _run_karr( $repo, 'create', "Task $n" );
        is( $rv->{exit}, 0, "task $n created" ) or diag $rv->{stderr};
    }

    return $repo;
}

my $HOLDER  = 'agent-holder';
my $TAKEOVER = 'agent-takeover';

# The one sentence every command has to produce, whoever is stepping over the
# claim -- including the two that pass no claimant at all.
sub _trace_re {
    my ( $id, $holder ) = @_;
    return qr/task \Q$id\E: overriding the expired claim held by \Q$holder\E/;
}

subtest 'an expired claim taken over by another name is reported' => sub {
    my $repo = _setup_repo( claim_timeout => '1s', tasks => 6 );

    my $claim = _run_karr( $repo, 'move', '1,2,3,4,5,6', 'in-progress',
        '--claim', $HOLDER );
    is( $claim->{exit}, 0, 'all six tasks claimed by the holder' )
      or diag $claim->{stderr};

    # One sleep for the whole subtest: every claim above was stamped before it,
    # so every card below is expired by the same wait.
    sleep 2;

    subtest 'handoff under a different name' => sub {
        my $r = _run_karr( $repo, 'handoff', '1', '--claim', $TAKEOVER,
            '--note', 'x' );

        # Unchanged, and deliberately so: an expired claim must not start
        # blocking anybody just because it is now audible.
        is( $r->{exit}, 0, 'the handoff still succeeds' ) or diag $r->{stderr};
        like( $r->{stdout}, qr/Handed off task 1/, '...and still says so' );

        like( $r->{stderr}, _trace_re( 1, $HOLDER ),
            'STDERR names the holder the takeover stepped over' );

        my $show = _run_karr( $repo, 'show', '1' );
        like( $show->{stdout}, qr/^Claimed:\s+\Q$TAKEOVER\E$/m,
            'the card really did change hands' );
    };

    subtest 'archive, which passes no claimant at all' => sub {
        my $r = _run_karr( $repo, 'archive', '2' );
        is( $r->{exit}, 0, 'the archive still succeeds' ) or diag $r->{stderr};
        like( $r->{stderr}, _trace_re( 2, $HOLDER ),
            'a card archived out from under an expired claim says whose it was' );
    };

    subtest 'delete, which checks the claim twice' => sub {
        my $r = _run_karr( $repo, 'delete', '3', '--yes' );
        is( $r->{exit}, 0, 'the delete still succeeds' ) or diag $r->{stderr};

        # Delete applies the rule once outside the guard (to decide whether to
        # prompt) and again inside delete_task_guarded, against the revision it
        # removes. Two checks, one card, one line: the record is keyed by task
        # id and replaced, not appended to.
        my @lines = ( $r->{stderr} =~ /(overriding the expired claim)/g );
        is( scalar @lines, 1,
            'the two check_claim calls on the delete path report once, not twice' )
          or diag $r->{stderr};
        like( $r->{stderr}, _trace_re( 3, $HOLDER ), '...and it names the holder' );
    };

    subtest 'the holder continuing under its own name is not reported' => sub {
        # check_claim answers "the current claimant may always proceed" before
        # it ever asks about expiry, so a long-running agent that outlives its
        # own claim_timeout gets no warning about itself.
        my $r = _run_karr( $repo, 'move', '4', 'review', '--claim', $HOLDER );
        is( $r->{exit}, 0, 'the holder still moves its own card' )
          or diag $r->{stderr};
        unlike( $r->{stderr}, qr/expired claim/,
            'no trace: nothing changed hands' );
    };

    subtest '--quiet silences the human copy' => sub {
        my $r = _run_karr( $repo, 'move', '5', 'review', '--claim', $TAKEOVER,
            '--quiet' );
        is( $r->{exit}, 0, 'the move still succeeds under --quiet' )
          or diag $r->{stderr};
        unlike( $r->{stderr}, qr/expired claim/,
            '--quiet silences the takeover line like every other warning' );
    };

    subtest '--json carries the pair instead of the line' => sub {
        my $r = _run_karr( $repo, 'handoff', '6', '--claim', $TAKEOVER,
            '--note', 'x', '--json' );
        is( $r->{exit}, 0, 'the handoff still succeeds under --json' )
          or diag $r->{stderr};

        unlike( $r->{stderr}, qr/expired claim/,
            'nothing on STDERR: a JSON consumer would never read it there' );

        my $data = eval { decode_json( $r->{stdout} ) };
        ok( $data, 'STDOUT is one decodable JSON object' )
          or diag "stdout: $r->{stdout}";
        is( ref $data->{expired_claim}, 'HASH',
            'the payload carries an expired_claim object' )
          or return;

        # Structured, not a sentence: karr-foundation attributes stalls per
        # claim name, so the name it needs must not have to be parsed out of
        # English.
        is( $data->{expired_claim}{held_by}, $HOLDER,
            'expired_claim.held_by is the previous holder' );
        like( $data->{expired_claim}{claimed_at},
            qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/,
            'expired_claim.claimed_at is when that claim was stamped' );
    };
};

subtest 'a live claim is still refused, loudly and for every command' => sub {
    my $repo = _setup_repo( tasks => 4 );   # default claim_timeout: 1h

    my $claim = _run_karr( $repo, 'move', '1,2,3', 'in-progress',
        '--claim', $HOLDER );
    is( $claim->{exit}, 0, 'three tasks claimed by the holder' )
      or diag $claim->{stderr};

    my $handoff = _run_karr( $repo, 'handoff', '1', '--claim', $TAKEOVER,
        '--note', 'x' );
    isnt( $handoff->{exit}, 0, 'handoff under another name is refused' );
    like( $handoff->{stderr}, qr/\QTask 1 is claimed by $HOLDER\E/,
        '...with the wording that has always named the holder' );
    unlike( $handoff->{stderr}, qr/expired claim/,
        '...and nothing about expiry, because nothing expired' );

    # delete and archive pass undef as the claimant on purpose: they refuse
    # *any* live claim rather than comparing names, since neither has a --claim
    # option to satisfy one with. Adding the takeover trace must not turn either
    # of them into a command that walks through a live claim.
    my $delete = _run_karr( $repo, 'delete', '2', '--yes' );
    isnt( $delete->{exit}, 0, 'delete still refuses a live claim' );
    like( $delete->{stderr}, qr/\QTask 2 is claimed by $HOLDER\E/,
        '...naming the holder' );

    my $archive = _run_karr( $repo, 'archive', '3' );
    isnt( $archive->{exit}, 0, 'archive still refuses a live claim' );
    like( $archive->{stderr}, qr/\QTask 3 is claimed by $HOLDER\E/,
        '...naming the holder' );

    my $show = _run_karr( $repo, 'show', '2' );
    like( $show->{stdout}, qr/^Claimed:\s+\Q$HOLDER\E$/m,
        'the refused card is still there and still the holder\'s' );

    my $free = _run_karr( $repo, 'move', '4', 'in-progress', '--claim', $TAKEOVER );
    is( $free->{exit}, 0, 'an unclaimed card moves as before' )
      or diag $free->{stderr};
    unlike( $free->{stderr}, qr/expired claim/,
        'and says nothing: there was no claim to step over' );
};

done_testing;
