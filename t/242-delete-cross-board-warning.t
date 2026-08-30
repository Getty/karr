use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr run_karr_stdin );
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use JSON::MaybeXS qw( decode_json );

use App::karr::Git;

# Ticket #242: the cross-board half of #236. `karr delete` learned to name the
# cards on *this* board that were left pointing at the id it removes; a card on
# another board waiting through a `needs:` link got nothing, and found out the
# way #236's dependents used to:
#
#     boardA$ karr delete 1 --yes        -> Deleted task 1: Fix the API
#     boardB$ karr needs
#     -> needs boardA#1 -- task 1 does not exist on board boardA
#
# It is worse than the local case. App::karr::CrossBoard/link_state calls that
# state `missing`, and `karr needs --resolve` refuses on purpose to settle a
# link whose card cannot be read -- so a card blocked on that link stays
# blocked, with nothing over there able to lift it.
#
# The far board is still not opened, and this test does not ask it to be: the
# escalation protocol writes its far end onto the card being deleted itself
# (`escalated-from:<board>#<id>`, `karr create --escalated-from`), so the far
# card can be *named* from this board's own tag without a path this command
# does not have. Resolving it stays `karr needs`' job.
#
# `needs:` on the card being deleted is reported too, in different words: no
# link breaks over there -- it goes with the card -- what ends is anything on
# this board waiting for the far card at all.
#
# Channel is #236's: STDERR for the human copy, --quiet silences it, --json
# carries the same sentences in the result object. The key is its own,
# `cross_board_warnings`, because a consumer that can act on a dangling
# dependency on this board cannot act on a card in another repository.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. This file's own
# convention -- a leading SCALAR ref in @argv standing for the answer typed at
# `karr delete`'s confirmation prompt -- still works, now routed through
# run_karr_stdin. KARR_TEST_SUBPROC=1 restores the old open3 path.
sub _run_karr {
    my ( $cwd, @argv ) = @_;
    my $stdin_text = ref $argv[0] eq 'SCALAR' ? ${ shift @argv } : undef;
    return defined $stdin_text
        ? run_karr_stdin( $cwd, $stdin_text, @argv )
        : run_karr( $cwd, @argv );
}

# A board of a given *name*, because a cross-board reference is a board name
# and that name is the repository's directory basename
# (App::karr::CrossBoard). Always under a fresh temp parent, never the
# developer's own board.
sub _board {
    my ( $name ) = @_;
    my $dir = path( tempdir( CLEANUP => 1 ) )->child($name);
    $dir->mkpath;
    system( 'git', 'init', '-q', "$dir" ) == 0 or die 'git init';
    system( 'git', '-C', "$dir", 'config', 'user.email', 'test@example.com' ) == 0
        or die 'git config';
    system( 'git', '-C', "$dir", 'config', 'user.name', 'Test User' ) == 0
        or die 'git config';
    my $init = _run_karr( "$dir", 'init', '--name', $name );
    die "karr init failed: $init->{stderr}" if $init->{exit};
    return "$dir";
}

sub _create {
    my ( $repo, @argv ) = @_;
    my $r = _run_karr( $repo, 'create', @argv );
    die "karr create failed: $r->{stderr}" if $r->{exit};
    return $r;
}

sub _task {
    my ( $repo, $id ) = @_;
    return App::karr::Git->new( dir => $repo )->load_task_ref($id);
}

subtest 'the far card that raised this one is named before it goes' => sub {
    my $far  = _board('boardB');
    my $here = _board('boardA');

    _create( $far,  'Real waiter', '--needs', 'boardA#1' );
    _create( $here, 'Fix the API', '--escalated-from', 'boardB#1' );

    my $before = _run_karr( $far, 'needs', '--board', "boardA=$here" );
    like( $before->{stdout}, qr/needs boardA#1 -- backlog \(open\)/,
        'the link resolves while the card is there' ) or diag $before->{stderr};

    my $r = _run_karr( $here, 'delete', '1', '--yes' );
    is( $r->{exit}, 0, 'the delete is not refused -- warn, do not block' )
        or diag $r->{stderr};
    like( $r->{stderr}, qr/task 1 \(Fix the API\) was escalated from boardB#1/,
        'the warning names the far card out of the tag on the card being deleted' );
    like( $r->{stderr}, qr/karr archive 1/,
        'and offers the door that keeps the far link resolvable' );
    # The door is offered with its side effect, not as a clean way out (#250):
    # a settled link says the far card is closed, never that it succeeded.
    like( $r->{stderr}, qr/reads as settled over there, finished or not/,
        'and says what archiving reports over there, finished or given up' );
    like( $r->{stdout}, qr/Deleted task 1: Fix the API/,
        'STDOUT reports the delete as usual' );
    unlike( $r->{stdout}, qr/Warning/, 'and stays parseable' );
    ok( !_task( $here, 1 ), 'the card really is gone -- the warning accompanies' );

    my $after = _run_karr( $far, 'needs', '--board', "boardA=$here" );
    like( $after->{stdout}, qr/task 1 does not exist on board boardA/,
        'this is the damage the warning was about, and it was named first' );
};

subtest 'the far board is never opened to say it' => sub {
    # The tag alone carries the reference, so a board name this machine cannot
    # place anywhere is still named -- no fleet config, no directory, nothing
    # remote. That is the honest reach: name the far card, do not resolve it.
    my $here = _board('boardA');
    _create( $here, 'Fix the API', '--escalated-from', 'nowhere-at-all#42' );

    my $r = _run_karr( $here, 'delete', '1', '--yes' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    like( $r->{stderr}, qr/was escalated from nowhere-at-all#42/,
        'the reference is named without being resolved' );
    unlike( $r->{stderr}, qr/unknown board/,
        'and nothing tried to place it on this machine' );
};

subtest 'a card waiting on another board says something else' => sub {
    my $here = _board('boardA');
    _create( $here, 'Waiting card', '--needs', 'other-repo#7' );

    my $r = _run_karr( $here, 'delete', '1', '--yes' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    like( $r->{stderr},
        qr/task 1 \(Waiting card\) waits on other-repo#7 on another board/,
        'the outgoing link is reported in its own words' );
    unlike( $r->{stderr}, qr/was escalated from/,
        'and not in the words of the incoming one' );
    unlike( $r->{stderr}, qr/karr archive/,
        'no archive door: nothing over there breaks, so keeping the card fixes nothing' );
};

subtest 'both directions on one card are two sentences' => sub {
    my $here = _board('boardA');
    _create( $here, 'Middle', '--escalated-from', 'boardB#5', '--needs', 'boardC#9' );

    my $r = _run_karr( $here, 'delete', '1', '--yes' );
    like( $r->{stderr}, qr/was escalated from boardB#5/, 'the incoming link is named' );
    like( $r->{stderr}, qr/waits on boardC#9/,           'and so is the outgoing one' );
};

subtest 'a card with no cross-board tag is deleted in silence' => sub {
    my $here = _board('boardA');
    _create( $here, 'Plain card' );

    my $r = _run_karr( $here, 'delete', '1', '--yes' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/Warning/, 'nothing to say about any other board' );
};

subtest 'a tag carrying the prefix but no reference is not a link' => sub {
    # tags is free text and karr owns the typed doors -- App::karr::CrossBoard
    # skips a malformed one rather than reporting a third state, and a delete
    # must not invent one either.
    my $here = _board('boardA');
    _create( $here, 'Hand typed', '--tags', 'needs:whatever' );

    my $r = _run_karr( $here, 'delete', '1', '--yes' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/Warning/, 'no reference, no warning' );
};

subtest '--json carries them in their own key, and not on STDERR' => sub {
    my $here = _board('boardA');
    _create( $here, 'Fix the API', '--escalated-from', 'boardB#5' );
    _create( $here, 'Local dependent', '--depends-on', '1' );

    my $r = _run_karr( $here, 'delete', '1', '--yes', '--json' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/Warning/,
        'nothing on STDERR: a JSON consumer would never see it there' );

    my $data = eval { decode_json( $r->{stdout} ) };
    ok( $data, 'STDOUT is still one decodable JSON object' )
        or diag "stdout was: $r->{stdout}";
    is( ref $data->{cross_board_warnings}, 'ARRAY',
        'the cross-board warning rides in the result object' );
    is( scalar @{ $data->{cross_board_warnings} }, 1, 'one far card' );
    like( $data->{cross_board_warnings}[0], qr/was escalated from boardB#5/,
        'and it is the sentence STDERR would have carried' );

    is( scalar @{ $data->{dependent_warnings} }, 1,
        'the board-local warning keeps its own key' );
    like( $data->{dependent_warnings}[0], qr/task 2 \(Local dependent\) depends on task 1/,
        'and its own sentence: this board is not the other board' );
};

subtest '--json omits the key entirely when there is nothing to say' => sub {
    my $here = _board('boardA');
    _create( $here, 'Plain card' );

    my $r = _run_karr( $here, 'delete', '1', '--yes', '--json' );
    my $data = eval { decode_json( $r->{stdout} ) };
    ok( $data, 'STDOUT decodes' ) or diag "stdout was: $r->{stdout}";
    ok( !exists $data->{cross_board_warnings},
        'no empty array to make a consumer test for length' );
};

subtest '--quiet silences it' => sub {
    my $here = _board('boardA');
    _create( $here, 'Fix the API', '--escalated-from', 'boardB#5' );

    my $r = _run_karr( $here, 'delete', '1', '--yes', '--quiet' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/Warning/, 'STDERR says nothing under --quiet' );
    unlike( $r->{stdout}, qr/Warning/, 'and it did not move to STDOUT either' );
    ok( !_task( $here, 1 ), 'the delete still happened' );
};

subtest 'it reaches the operator while the answer is still open' => sub {
    my $here = _board('boardA');
    _create( $here, 'Fix the API', '--escalated-from', 'boardB#5' );

    my $r = _run_karr( $here, \"n\n", 'delete', '1' );
    is( $r->{exit}, 0, 'answering no is an answer, not a failure' )
        or diag $r->{stderr};
    like( $r->{stderr}, qr/was escalated from boardB#5/,
        'the warning was given before the confirmation was answered' );
    like( $r->{stdout}, qr/Skipped task 1/, 'and the operator could act on it' );
    ok( _task( $here, 1 ), 'so the card is still there' );
};

subtest 'the kept card carries them under --json too' => sub {
    my $here = _board('boardA');
    _create( $here, 'Fix the API', '--escalated-from', 'boardB#5' );

    my $r = _run_karr( $here, \"n\n", 'delete', '1', '--json' );
    # The confirmation prompt is printed to STDOUT whatever --json says, so the
    # object is decoded from where it starts. That is a separate defect of the
    # prompt (the neighbour of #241, which fixed its flushing and not its
    # channel), not of the warning under test, and this test declines to pin it
    # either way.
    my ($json) = $r->{stdout} =~ /(\{.*\})/s;
    my $data = eval { decode_json( $json // '' ) };
    ok( $data, 'STDOUT carries the result object' )
        or diag "stdout was: $r->{stdout}";
    ok( !$data->{deleted},
        'deleted:false says the delete the warning named did not happen' );
    like( $data->{cross_board_warnings}[0], qr/was escalated from boardB#5/,
        'and the warning is beside it, which under --json is its only channel' );
};

subtest 'a batch warns per deleted id' => sub {
    my $here = _board('boardA');
    _create( $here, 'First',  '--escalated-from', 'boardB#5' );
    _create( $here, 'Second', '--escalated-from', 'boardB#6' );

    my $r = _run_karr( $here, 'delete', '1,2', '--yes' );
    is( $r->{exit}, 0, 'both ids are deleted' ) or diag $r->{stderr};
    like( $r->{stderr}, qr/task 1 \(First\) was escalated from boardB#5/,
        'the first id warns' );
    like( $r->{stderr}, qr/task 2 \(Second\) was escalated from boardB#6/,
        'and so does the second' );
};

done_testing;
