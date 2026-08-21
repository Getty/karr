use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path getcwd );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;

# Ticket #241: `karr delete` printed its confirmation with printf and no
# trailing newline, then blocked on <STDIN> without flushing. The question was
# therefore still sitting in karr's own buffer while the command was already
# waiting for the answer to it.
#
# What this test pins is exactly that: the question has reached the other end
# of the pipe *before* karr blocks on stdin. Everything a human notices --
# hanging cursor, typing blind, the answer echoing above the question -- is a
# consequence of that one property, and it is the only part of the story that
# can be observed without a terminal.
#
# Why not the pseudo-terminal the ticket was found on:
#
#   * Nothing in this suite allocates one today, IO::Pty is not a dependency,
#     and script(1) takes its arguments differently on util-linux and on BSD.
#     A test that hangs or fails on somebody else's machine would be worse than
#     no test.
#
#   * The pty transcript in the ticket does not actually prove the bug. There
#     the answer was piped in before karr had started, so the tty line
#     discipline echoed it at once; with the answer typed a second later, even
#     the unfixed karr printed the question first. PerlIO flushes line-buffered
#     handles when a read is attempted on a tty (PerlIOBuf_fill calls
#     PerlIOBase_flush_linebuf), so on a terminal something else was already
#     doing the flush by accident.
#
# That courtesy flush is what makes the pipe below the honest reproduction
# rather than a weaker stand-in: it only happens when stdin is a terminal. Feed
# the answers from anywhere else -- a pipe, a file, a harness -- and nothing
# pushes the question out, so it appears only when the next newline or the
# process exit forces it, which is after karr has acted on the answer. The
# explicit flush also stops the interactive case from depending on a PerlIO
# implementation detail that nothing promises.
#
# This test fails without the flush: the select() below then times out, because
# stdout on a pipe is block buffered and not one byte arrives until karr exits.

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

# How long to wait for the question. Only a run without the flush pays it --
# with the flush the prompt arrives as soon as karr gets there.
my $DEADLINE = 20;

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
    my $rc = system( $^X, "-I$ROOT/lib", $BIN, 'init', '--name', 'Prompt Board' );
    chdir $old or die "chdir $old: $!";
    die 'karr init failed' if $rc;

    my $git = App::karr::Git->new( dir => $repo );
    App::karr::BoardStore->new( git => $git )
        ->save_task( App::karr::Task->new( id => 1, title => 'Doomed', status => 'todo' ) );

    return $repo;
}

subtest 'the question arrives before karr waits for the answer' => sub {
    my $repo = _board();

    my $old = getcwd();
    chdir $repo or die "chdir $repo: $!";
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err,
        $^X, "-I$ROOT/lib", $BIN, 'delete', '1' );
    chdir $old or die "chdir $old: $!";

    # Deliberately nothing written to $in yet, and $in stays open: karr is left
    # blocking on a read that will not complete, which is the moment the
    # operator is looking at a cursor.
    my $prompt   = '';
    my $deadline = time + $DEADLINE;
    while ( time < $deadline ) {
        my $rin = '';
        vec( $rin, fileno($out), 1 ) = 1;
        my $ready = select( my $rout = $rin, undef, undef, 1 );
        next unless defined $ready && $ready > 0;
        my $chunk = '';
        my $read  = sysread( $out, $chunk, 4096 );
        last unless $read;    # child died or closed stdout
        $prompt .= $chunk;
        last if $prompt =~ /\[y\/N\]/;
    }

    like( $prompt, qr/Delete task 1: Doomed\? \[y\/N\] /,
        'the whole question is out on the wire while karr is still waiting' );

    # Answer it, so the child always finishes and this file never hangs -- also
    # without the flush, where the loop above ran out of time.
    print {$in} "n\n";
    close $in;

    my $rest = '';
    my $chunk;
    $rest .= $chunk while sysread( $out, $chunk, 4096 );
    my $stderr = do { local $/; <$err> };
    waitpid( $pid, 0 );
    my $exit = $? >> 8;

    is( $exit, 0, 'answering no is an answer, not a failure' )
        or diag $stderr;
    like( $prompt . $rest, qr/Skipped task 1: Doomed/,
        'and the exchange still reads as one conversation from end to end' );
};

done_testing;
