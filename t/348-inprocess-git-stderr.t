#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir tempfile );
use Path::Tiny qw( path );

# k335: the in-process runner captures STDERR, but a git child spawned by karr
# (the CLI transport route) inherits file descriptor 2, not the Perl handle.
# With STDERR reopened onto an in-memory scalar that descriptor was still the
# terminal, so git's own message never reached run_karr's `stderr` and anything
# classifying it saw nothing. This runs WITHOUT KARR_TEST_SUBPROC on purpose.

plan skip_all => 'KARR_TEST_SUBPROC is set: this test is about the in-process runner'
    if $ENV{KARR_TEST_SUBPROC};

my $work = tempdir( CLEANUP => 1 );
system( 'git', 'init', '-q', '--bare', "$work/origin.git" );
system("git clone -q '$work/origin.git' '$work/a' 2>/dev/null");
system( 'git', '-C', "$work/a", 'config', 'user.email', 'a@karr.test' );
system( 'git', '-C', "$work/a", 'config', 'user.name',  'agent-a' );
is run_karr( "$work/a", 'init' )->{exit}, 0, 'board initialised';

# Point origin at a path that is not a repository: only git itself words the
# refusal ("does not appear to be a git repository").
my $gone = "$work/does-not-exist.git";
system( 'git', '-C', "$work/a", 'remote', 'set-url', 'origin', $gone );

# Watch the real descriptor 2 for the duration: nothing may leak onto it.
open my $saved, '>&', \*STDERR or die "dup STDERR: $!";
my ( $leak_fh, $leak_name ) = tempfile( DIR => $work );
open STDERR, '>&', $leak_fh or die "redirect STDERR: $!";

my $r = run_karr( "$work/a", 'create', 'probe', '--body', 'x' );

open STDERR, '>&', $saved or die "restore STDERR: $!";
my $leaked = path($leak_name)->slurp_raw;

isnt $r->{exit}, 0, 'the push to the missing remote fails';
like $r->{stderr}, qr/does not appear to be a git repository/,
    q{git's own message reaches the captured stderr};
is $leaked, '', 'nothing leaked onto the real stderr'
    or diag $leaked;

done_testing;
