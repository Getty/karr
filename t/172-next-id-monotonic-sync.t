use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );
use App::karr::Git;

# Ticket #172: eight parallel `karr create` in ONE clone handed out the same
# task id twice, and the second card overwrote the first.
#
# The compare-and-swap in allocate_next_id_ref was not the defect -- it is
# provably exclusive on its own (t/75) -- but it is only the sole authority for
# handing out an id while nothing else moves the ref it counts on. The pull did
# exactly that: reconciliation is last-writer-wins per ref, so a remote counter
# behind the local one was force-written over it, and the next create was
# handed an id that already had a card on it. A run of the reproducer walked
# the counter from 7 back to 4 and then created 4 and 5 a second time.
#
# The remote does get behind, without anything being wrong with it: every push
# force-writes the whole namespace, so a push that started earlier can land
# after one that started later, and a clone that has not synced for a while
# holds an older counter it will publish the moment it does.
#
# So this pins the invariant the allocator needs, in both directions:
#
#   * a pull never walks the id counter backwards, and the create after such a
#     pull does not reuse a live id
#   * a counter the remote really has moved ahead is still adopted -- the fix
#     is "merge forward", not "never take the remote's value"

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

sub _run {
    my ( $dir, @argv ) = @_;
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err,
        $^X, "-I$ROOT/lib", $BIN, '--dir', $dir, @argv );
    close $in;
    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    waitpid $pid, 0;
    return {
        exit   => $? >> 8,
        stdout => defined $stdout ? $stdout : '',
        stderr => defined $stderr ? $stderr : '',
    };
}

sub _karr_ok {
    my ( $dir, $what, @argv ) = @_;
    my $r = _run( $dir, @argv );
    is( $r->{exit}, 0, $what ) or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";
    return $r;
}

# A bare origin and two clones of it, each with a git identity of its own.
sub _clones {
    my $work = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', '--bare', "$work/origin.git" ) == 0
        or die "cannot create origin";
    for my $name (qw( a b )) {
        system("git clone -q '$work/origin.git' '$work/$name' 2>/dev/null") == 0
            or die "cannot clone $name";
        system( 'git', '-C', "$work/$name", 'config', 'user.email',
            "$name\@karr.test" ) == 0 or die;
        system( 'git', '-C', "$work/$name", 'config', 'user.name',
            "agent-$name" ) == 0 or die;
    }
    return ( "$work/a", "$work/b" );
}

sub _counter {
    my ($dir) = @_;
    return App::karr::Git->new( dir => $dir )->read_next_id_ref;
}

sub _title_of {
    my ( $dir, $id ) = @_;
    my $r = _run( $dir, 'show', $id );
    my ($title) = $r->{stdout} =~ /^Task \#\d+: (.*)$/m;
    return $title;
}

subtest 'a pull never walks the id counter backwards' => sub {
    my ( $a, $b ) = _clones();

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Monotonic' );
    _karr_ok( $a, "create task $_", 'create', "A$_" ) for 1 .. 3;
    is( _counter($a), 4, 'clone a has handed out 1..3 and stands at 4' );

    # Clone b syncs here and then goes quiet: from now on it holds a counter
    # that is real, was correct when it was read, and is behind.
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--pull', '--quiet' );
    is( _counter($b), 4, 'clone b is at 4 too' );

    _karr_ok( $a, "create task $_", 'create', "A$_" ) for 4 .. 6;
    is( _counter($a), 7, 'clone a has moved on to 7' );

    # What a stale push landing late looks like on the wire, with nothing else
    # in the way: only the counter ref goes, so the remote's cards stay as
    # clone a published them and the counter alone is behind.
    is( system( 'git', '-C', $b, 'push', '-q', 'origin',
            '+refs/karr/meta/next-id:refs/karr/meta/next-id' ),
        0, "clone b's older counter reaches the remote" );

    _karr_ok( $a, 'clone a pulls', 'sync', '--pull', '--quiet' );
    is( _counter($a), 7,
        'the pull kept the counter clone a had reached, not the older remote one' );

    # The consequence the ticket is actually about: with the counter walked
    # back to 4, this create was handed 4 -- an id task "A4" is sitting on --
    # and overwrote it.
    my $created = _karr_ok( $a, 'create after the pull', 'create', 'After' );
    like( $created->{stdout}, qr/^Created task 7: After$/m,
        'the create after the pull got a fresh id, not a live one' );
    is( _title_of( $a, 4 ), 'A4', 'and the card that id used to belong to is untouched' );
};

subtest 'a counter the remote moved ahead is still adopted' => sub {
    my ( $a, $b ) = _clones();

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Monotonic' );
    _karr_ok( $a, 'create task 1', 'create', 'A1' );
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--pull', '--quiet' );
    is( _counter($b), 2, 'both clones stand at 2' );

    _karr_ok( $b, "create task $_", 'create', "B$_" ) for 2 .. 4;
    is( _counter($b), 5, 'clone b has moved the counter to 5' );

    _karr_ok( $a, 'clone a pulls', 'sync', '--pull', '--quiet' );
    is( _counter($a), 5,
        'the remote counter is adopted when it really is the further one' );

    my $created = _karr_ok( $a, 'create after the pull', 'create', 'After' );
    like( $created->{stdout}, qr/^Created task 5: After$/m,
        'so the next create continues past the other clone, not over it' );
};

done_testing;
