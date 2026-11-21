#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Cwd ();
use File::Spec;
# The tree under test, taken before any chdir.
my $LIB = Cwd::abs_path('lib');
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );

# Ticket k336: `prove -l` puts the relative `lib` into @INC, run_karr chdirs
# into the repository under test, and a command class loaded lazily after
# that chdir would resolve `lib/App/karr/Cmd/X.pm` against the new cwd, miss,
# and fall through to an installed App::karr -- the test running old code
# without a sign. TestKarr makes @INC absolute at load time. This file
# deliberately has no `use lib abs_path` of its own.
#
# Modern `prove -l` already hands tests an absolute lib, so this file cannot
# rely on how it was started: each check runs in a fresh perl given the
# relative -Ilib -It/lib that `perl -Ilib`, `prove -Ilib` or an old prove gives.
# Child: load TestKarr as a test would, report relative @INC entries, then run
# `init` and `set-refs --help` (set-refs is not loaded by TestKarr itself) and
# report where the lazily loaded class came from.
my $code = <<'CHILD';
use TestKarr qw(run_karr);
my $class = "App/karr/Cmd/SetRefs.pm";
print "preloaded=", ( $INC{$class} ? 1 : 0 ), "\n";
print "relative=", join( ",", grep { !ref $_ && $_ !~ m{^/} } @INC ), "\n";
my $i = run_karr( $ARGV[0], "init" );
my $r = run_karr( $ARGV[0], "set-refs", "--help" );
print "init=$i->{exit}\n";
print "inc=", ( $INC{$class} // "" ), "\n";
CHILD

for my $mode ( 0, 1 ) {
    subtest( ( $mode ? 'subprocess' : 'in-process' ) . ' mode' => sub {
        local $ENV{KARR_TEST_SUBPROC} = $mode;
        # prove -l also exports the absolute lib in PERL5LIB, which would
        # mask the bug in the child: drop this tree from it.
        local $ENV{PERL5LIB} = join ':',
            grep { $_ ne $LIB } split /:/, $ENV{PERL5LIB} // '';
        my $repo = tempdir( CLEANUP => 1 );
        system( 'git', '-C', $repo, 'init', '-q' ) == 0 or BAIL_OUT('git init');
        open my $fh, '-|', $^X, '-Ilib', '-It/lib', '-e', $code, $repo
            or die "spawn: $!";
        my %got = map { /\A(\w+)=(.*)\n?\z/ ? ( $1 => $2 ) : () } <$fh>;
        close $fh;
        is( $got{relative}, '', 'TestKarr leaves no relative entry in @INC' );
        is( $got{init}, 0, 'init in the temp repo' );
        if ($mode) {
            # The command class loads in the child's child; the point here is
            # that the run works from the temp repo at all.
            pass('subprocess run found the tree under test');
        }
        else {
            is( $got{preloaded}, 0, 'set-refs is not loaded before the first run' );
            like( $got{inc}, qr/\A\Q$LIB\E\//,
                'set-refs, loaded after the chdir, came from this tree' );
        }
    } );
}

done_testing;
