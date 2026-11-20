#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
# The runner must spawn bin/karr: the CLI route runs a git child whose stderr
# is the evidence (the denial is classified from it), and the in-process
# runner's captured STDERR has no file descriptor for that child to inherit,
# so there git's message would reach the terminal and karr would see none.
BEGIN { $ENV{KARR_TEST_SUBPROC} = 1 }
use TestKarr qw( run_karr run_karr_stdin );
use File::Temp qw( tempdir );
use Path::Tiny qw( path );

# Ticket k333, part A, end to end: `karr create` and `karr set-refs` against
# a bare origin this user cannot write, through the real bin/karr and the git
# CLI route (the default transport for the board push).
#
# A `git` shim in front of PATH logs every invocation, so "tried once" is a
# count of `git push` runs, not a guess from banners or timing.

SKIP: {
    skip 'running as root: it ignores the read-only mode of the bare repository', 1
        if $> == 0;

    my ($real_git) = grep { -x $_ } map { "$_/git" } split /:/, $ENV{PATH};
    $real_git //= '';
    skip 'no git binary found on PATH', 1 unless length $real_git;

    my $work = tempdir( CLEANUP => 1 );
    my $log  = path("$work/git-calls.log");
    my $bin  = path("$work/bin");
    $bin->mkpath;
    $bin->child('git')->spew("#!/bin/sh\necho \"\$*\" >> '$log'\nexec '$real_git' \"\$@\"\n");
    chmod 0755, $bin->child('git')->stringify;

    system( 'git', 'init', '-q', '--bare', "$work/origin.git" );
    system("git clone -q '$work/origin.git' '$work/a' 2>/dev/null");
    system( 'git', '-C', "$work/a", 'config', 'user.email', 'a@karr.test' );
    system( 'git', '-C', "$work/a", 'config', 'user.name',  'agent-a' );
    is run_karr( "$work/a", 'init' )->{exit}, 0, 'board initialised while origin is writable';

    # Everything below runs with the shim first on PATH and the origin
    # read-only; permissions come back before the tempdir is removed.
    my $restore = sub { system( 'chmod', '-R', 'u+w', "$work/origin.git" ) };
    END { $restore->() if $restore }
    system( 'chmod', '-R', 'a-w', "$work/origin.git" );
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my $pushes_logged = sub {
        return 0 unless $log->exists;
        return scalar grep { /(?:^|\s)push(?:\s|$)/ } $log->lines;
    };

    subtest 'karr create: denied is tried once' => sub {
        $log->remove;
        my $r = run_karr( "$work/a", 'create', 'probe', '--body', 'x' );

        is $r->{exit}, 1, 'exit 1';
        is $pushes_logged->(), 1, 'git push ran exactly once (the old loop ran it three times)';
        like $r->{stderr}, qr/denied/i, 'STDERR says denied';
        like $r->{stderr}, qr/cannot write the remote repository/, 'with the reason';
        like $r->{stderr}, qr/^karr: write access to the remote 'origin' \(\Q$work\E\/origin\.git\) was denied: /m,
            'C1 names the remote and its push URL';
        like $r->{stderr}, qr/Nothing was changed: this command's change was taken back, and this clone is now read-only for the board\./,
            'and says the change was taken back';
        like $r->{stderr}, qr/If this clone is only for reading: karr readonly on\./, 'and the read-only way out';
        unlike $r->{stderr}, qr/Push retry/, 'no retry banner';
        unlike $r->{stderr}, qr/Push failed after 3 attempts/, 'not the exhausted-retries verdict';
        unlike $r->{stderr}, qr/git push failed: git push failed:/, 'no doubled prefix';
        my @shown = $r->{stderr} =~ /(remote unpack failed)/g;
        is scalar @shown, 1, 'the git error appears once';
    };

    subtest 'karr set-refs after the denial: refused (C2) without a push' => sub {
        # Was: set-refs pushed, was denied and said "Failed to push <ref>". The
        # preceding create has put this clone into read-only, so set-refs is
        # now refused before it writes (and before it pushes): the claim that
        # it must not report success stays; the claim that it pushes is gone.
        $log->remove;
        my $r = run_karr_stdin( "$work/a", "hello\n", 'set-refs', 'refs/karr-probe/note' );

        is $r->{exit}, 1, 'exit 1';
        like $r->{stderr}, qr/^karr: this clone is read-only for the board: write access to 'origin' \(\Q$work\E\/origin\.git\) was denied on /m,
            'refused with C2';
        like $r->{stderr}, qr/Nothing was changed\./, 'and says nothing was changed';
        like $r->{stderr}, qr/cannot write the remote repository/, 'with the recorded reason';
        is $pushes_logged->(), 0, 'no push was attempted';
        unlike $r->{stderr}, qr/Stored refs/, 'and it does not claim success';
    };
}

done_testing;
