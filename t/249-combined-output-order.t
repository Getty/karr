use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path getcwd );
use POSIX ();

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;

# Ticket #249: karr's warnings arrived after the results they were about.
#
#   karr delete 1 --yes 2>&1
#   -> Deleted task 1: Doomed
#      Warning: task 2 (Dependent) depends on task 1, which is being deleted
#
# The warning is printed before the delete and before the outcome line, so the
# order above is not the code's -- it is the buffering. App::karr::Encoding puts
# an :encoding(UTF-8) layer on STDERR, and that layer takes away the unbuffered
# default a bare STDERR has, so both handles ended up flushing at exit, STDOUT
# first. Everything karr wrote to STDERR therefore landed under everything it
# wrote to STDOUT, whatever order the code used.
#
# Why both streams go into ONE pipe here: with two pipes each stream is ordered
# within itself and the defect is invisible, so a test that read them separately
# could not fail. The bug is a property of the merged stream and of nothing
# else -- which is also why it never showed on a terminal (STDOUT is line
# buffered there and STDERR unbuffered, so the order came out right by itself)
# and only ever hit `2>&1`, a pipeline, or an agent harness reading combined
# output.
#
# Two subtests, and the second is not padding. The fix is autoflush on both
# handles in App::karr::Encoding::enable_std_utf8; autoflushing only STDERR --
# the obvious reading of "STDERR lost its unbuffered default" -- passes the
# first subtest and fails the second, because it does not restore the order, it
# reverses it: `karr move` prints its outcome first and warns afterwards, and
# with only STDERR flushed eagerly that warning overtakes the outcome it
# follows.

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

# A fresh isolated temp repo, never the developer's real board.
sub _board {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or die 'git config';

    my $old = getcwd();
    chdir $repo or die "chdir $repo: $!";
    my $rc = system( $^X, "-I$ROOT/lib", $BIN, 'init', '--name', 'Order Board' );
    chdir $old or die "chdir $old: $!";
    die 'karr init failed' if $rc;

    my $store = App::karr::BoardStore->new( git => App::karr::Git->new( dir => $repo ) );
    $store->save_task(
        App::karr::Task->new( id => 1, title => 'Doomed', status => 'backlog' ) );
    $store->save_task(
        App::karr::Task->new( id => 2, title => 'Dependent', status => 'backlog',
            depends_on => [1] ) );

    return $repo;
}

# Run karr with stdout and stderr on the same pipe -- the fork/dup shape a shell
# builds for `2>&1 |`, without a shell to quote for. Returns the merged output.
sub _combined {
    my ( $repo, @args ) = @_;

    pipe( my $reader, my $writer ) or die "pipe: $!";

    my $pid = fork;
    die "fork: $!" unless defined $pid;
    unless ($pid) {
        # child
        close $reader;
        chdir $repo or POSIX::_exit(127);
        open( STDOUT, '>&', $writer )   or POSIX::_exit(127);
        open( STDERR, '>&', \*STDOUT )  or POSIX::_exit(127);
        { no warnings 'exec'; exec( $^X, "-I$ROOT/lib", $BIN, @args ); }
        # _exit, not exit: an exec that failed must not run this file's END
        # blocks a second time and print a second test plan.
        POSIX::_exit(127);
    }

    close $writer;
    my $out = do { local $/; <$reader> };
    close $reader;
    waitpid( $pid, 0 );

    return defined $out ? $out : '';
}

# Both lines are there and $first stands above $second in the merged stream.
sub _reads_in_order {
    my ( $out, $first, $second, $name ) = @_;

    my $at_first  = $out =~ /$first/  ? $-[0] : -1;
    my $at_second = $out =~ /$second/ ? $-[0] : -1;

    cmp_ok( $at_first,  '>=', 0, "$name: the first line is in the output" )
        or diag "combined output was:\n$out";
    cmp_ok( $at_second, '>=', 0, "$name: the second line is in the output" )
        or diag "combined output was:\n$out";
    return if $at_first < 0 || $at_second < 0;

    cmp_ok( $at_first, '<', $at_second, $name )
        or diag "combined output was:\n$out";
    return;
}

subtest 'the warning stands above the deletion it warns about' => sub {
    my $repo = _board();
    my $out  = _combined( $repo, 'delete', '1', '--yes' );

    _reads_in_order(
        $out,
        qr/Warning: task 2 \(Dependent\) depends on task 1, which is being deleted/,
        qr/Deleted task 1: Doomed/,
        'the dependency warning arrives before the outcome it should have preceded',
    );
};

subtest 'and a command that warns afterwards still reads that way' => sub {
    my $repo = _board();
    my $out  = _combined( $repo, 'move', '2', 'in-progress', '--claim', 'order-test' );

    # The mirror image of the subtest above, and the reason the fix flushes both
    # handles: here the outcome is printed first and the warning follows it.
    _reads_in_order(
        $out,
        qr/Moved task 2: backlog -> in-progress/,
        qr/Warning: task 2 depends on task 1, which is still backlog/,
        'the outcome still arrives before the warning that follows it in the code',
    );
};

done_testing;
