use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr run_karr_stdin );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;

# Ticket #236: `karr delete` said nothing about the cards left pointing at the
# id it removed. `karr edit 6 --add-depends-on 2` then `karr delete 2 --yes`
# printed "Deleted task 2" and nothing else, and card 6 was left carrying a
# dependency on an id the board no longer has -- which `karr show 6` then
# renders as "2 (unknown)". The information existed, it simply arrived after
# the only moment it could have stopped anybody.
#
# kanban-md collects board.FindDependents before the delete and prints each hit
# as a "Warning:" on STDERR (cmd/delete.go, internal/board/board.go:53-72). It
# warns and deletes anyway, and karr follows: refusing would make a hard delete
# depend on cards the operator may not care about, and karr already answers the
# whole depends_on family by warning rather than blocking (#123).
#
# It weighs more here than in the reference, because karr's `delete` really
# removes the ref while kanban-md's archives the card -- and karr has `archive`
# as the soft way out, which is exactly where this warning sends a caller.
#
# The channel is the one App::karr::Role::DependencyCheck already argued for:
# the human copy on STDERR so STDOUT stays parseable, --json carrying the same
# sentence in the result object because a JSON consumer never reads STDERR, and
# --quiet silencing the STDERR copy only.

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

# A fresh isolated temp repo per subtest, never the developer's real board.
# Seeded through BoardStore rather than `karr create`, because `parent` has no
# CLI route at all (App::karr::Task) and depends_on only has one on cards that
# already exist.
sub _board {
    my (@specs) = @_;
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or die 'git config';

    my $init = _run_karr( $repo, 'init', '--name', 'Dependent Board' );
    die "karr init failed: $init->{stderr}" if $init->{exit};

    my $git   = App::karr::Git->new( dir => $repo );
    my $store = App::karr::BoardStore->new( git => $git );
    for my $spec (@specs) {
        $store->save_task(
            App::karr::Task->new(
                id     => $spec->{id},
                title  => $spec->{title} // "Task $spec->{id}",
                status => $spec->{status} // 'todo',
                ( $spec->{depends_on} ? ( depends_on => $spec->{depends_on} ) : () ),
                ( defined $spec->{parent} ? ( parent => $spec->{parent} ) : () ),
            )
        );
    }
    $git->write_ref( 'refs/karr/meta/next-id', "50\n" );

    return $repo;
}

sub _task {
    my ( $repo, $id ) = @_;
    return App::karr::Git->new( dir => $repo )->load_task_ref($id);
}

subtest 'deleting a card another card depends on warns and names it' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 6, title => 'K6', depends_on => [2] },
    );

    my $r = _run_karr( $repo, 'delete', '2', '--yes' );
    is( $r->{exit}, 0, 'the delete is not refused -- warn, do not block' )
        or diag $r->{stderr};
    like( $r->{stderr}, qr/task 6 \(K6\) depends on task 2/,
        'the warning names the dependent card by id and title' );
    like( $r->{stderr}, qr/karr archive 2/,
        'and points at the soft way out karr has and kanban-md does not' );
    like( $r->{stdout}, qr/Deleted task 2: K2/, 'STDOUT reports the delete as usual' );
    unlike( $r->{stdout}, qr/Warning/,
        'and carries no warning of its own, so it stays parseable' );
    ok( !_task( $repo, 2 ), 'the card really is gone -- the warning accompanies' );
};

subtest 'the warning comes under --yes, which is how agents delete' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 6, title => 'K6', depends_on => [2] },
    );

    # Same invocation as the subtest above; asserted separately because a
    # warning that only appears on the interactive path warns exactly where
    # nobody is left to read it.
    my $r = _run_karr( $repo, 'delete', '2', '--yes' );
    like( $r->{stderr}, qr/^Warning: /m, 'the unattended path warns too' );
};

subtest 'a card nothing depends on is deleted in silence' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 6, title => 'K6' },
    );

    my $r = _run_karr( $repo, 'delete', '2', '--yes' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/Warning/,
        'nothing points at the card, so there is nothing to say' );
};

subtest 'a card depending on a different id is not a dependent' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 3, title => 'K3' },
        { id => 6, title => 'K6', depends_on => [3] },
    );

    my $r = _run_karr( $repo, 'delete', '2', '--yes' );
    unlike( $r->{stderr}, qr/Warning/, 'ids 3 and 2 are not the same id' );
};

subtest 'every dependent is named, not just the first' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 5, title => 'Five',  depends_on => [ 1, 2 ] },
        { id => 6, title => 'Six',   depends_on => [2] },
        { id => 7, title => 'Seven', depends_on => [3] },
    );

    my $r = _run_karr( $repo, 'delete', '2', '--yes' );
    like( $r->{stderr}, qr/task 5 \(Five\) depends on task 2/, 'the first is named' );
    like( $r->{stderr}, qr/task 6 \(Six\) depends on task 2/,  'and so is the second' );
    unlike( $r->{stderr}, qr/task 7/, 'the one pointing elsewhere is not' );
};

subtest 'the warning reaches the operator before the confirmation is answered' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 6, title => 'K6', depends_on => [2] },
    );

    # Answering "n" is the whole point of warning at all: the card survives, so
    # a warning printed after the delete would never have been printed here.
    my $r = _run_karr( $repo, \"n\n", 'delete', '2' );
    is( $r->{exit}, 0, 'answering no is an answer, not a failure' )
        or diag $r->{stderr};
    like( $r->{stderr}, qr/task 6 \(K6\) depends on task 2/,
        'the warning was given while the answer was still open' );
    like( $r->{stdout}, qr/Skipped task 2/, 'and the operator could act on it' );
    ok( _task( $repo, 2 ), 'so the card is still there' );
};

subtest 'a card carrying the deleted id as parent is reported too' => sub {
    # kanban-md's FindDependents reports both. karr has no --parent option, but
    # `karr import` brings the field in from a kanban-md board and Task keeps
    # it, so the value can be real -- and unlike depends_on, nothing in karr
    # renders it afterwards, so this warning is the only place an orphaned
    # child is ever mentioned.
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 6, title => 'Child', parent => 2 },
    );

    my $r = _run_karr( $repo, 'delete', '2', '--yes' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    like( $r->{stderr}, qr/task 6 \(Child\) has task 2 as its parent/,
        'a child is a dependent in its own words' );
    unlike( $r->{stderr}, qr/depends on/,
        'and not in the words used for a depends_on entry' );
};

subtest '--json carries the warning in the object and not on STDERR' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 6, title => 'K6', depends_on => [2] },
    );

    my $r = _run_karr( $repo, 'delete', '2', '--yes', '--json' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/Warning/,
        'nothing on STDERR: a JSON consumer would never see it there' );

    my $data = eval { decode_json( $r->{stdout} ) };
    ok( $data, 'STDOUT is still one decodable JSON object' )
        or diag "stdout was: $r->{stdout}";
    is( ref $data->{dependent_warnings}, 'ARRAY',
        'the warning rides in the result object' );
    is( scalar @{ $data->{dependent_warnings} }, 1, 'one dependent card' );
    like( $data->{dependent_warnings}[0], qr/task 6 \(K6\) depends on task 2/,
        'and it is the same sentence STDERR would have carried' );
};

subtest '--json omits the key entirely when there is nothing to say' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 6, title => 'K6' },
    );

    my $r = _run_karr( $repo, 'delete', '2', '--yes', '--json' );
    my $data = eval { decode_json( $r->{stdout} ) };
    ok( $data, 'STDOUT decodes' ) or diag "stdout was: $r->{stdout}";
    ok( !exists $data->{dependent_warnings},
        'no empty array to make a consumer test for length' );
};

subtest '--quiet silences it' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 6, title => 'K6', depends_on => [2] },
    );

    my $r = _run_karr( $repo, 'delete', '2', '--yes', '--quiet' );
    is( $r->{exit}, 0, 'delete succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/Warning/, 'STDERR says nothing under --quiet' );
    unlike( $r->{stdout}, qr/Warning/, 'and it did not move to STDOUT either' );
    ok( !_task( $repo, 2 ), 'the delete still happened' );
};

subtest 'a batch warns per deleted id' => sub {
    my $repo = _board(
        { id => 2, title => 'K2' },
        { id => 3, title => 'K3' },
        { id => 6, title => 'K6', depends_on => [ 2, 3 ] },
    );

    my $r = _run_karr( $repo, 'delete', '2,3', '--yes' );
    is( $r->{exit}, 0, 'both ids are deleted' ) or diag $r->{stderr};
    like( $r->{stderr}, qr/task 6 \(K6\) depends on task 2/, 'the first id warns' );
    like( $r->{stderr}, qr/task 6 \(K6\) depends on task 3/, 'and so does the second' );
};

done_testing;
