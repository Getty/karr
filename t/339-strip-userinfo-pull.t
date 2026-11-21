#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run );
use TestHttpStub qw( http_stub closed_port );

# Ticket k342 (follow-up to k333, t/338): a secret in the FETCH URL
# (git remote set-url origin, not --push) must reach no output and no karr.*
# git config through the pull path either -- the native fetch's last_error and
# the git CLI fallback's "git fetch (CLI fallback) failed: ..." both end up in
# "git pull failed: ..." on stderr.
#
# TestDenied runs karr as a subprocess (KARR_TEST_SUBPROC), so the git CLI
# child's stderr is really captured and the CLI-route checks are not vacuous.

# native: the CLI fallback is switched off; cli: the default route.
my %route = (
    native => sub { local $ENV{KARR_NO_CLI_FALLBACK} = 1; $_[0]->() },
    cli    => sub { local $ENV{KARR_NO_CLI_FALLBACK}; delete $ENV{KARR_NO_CLI_FALLBACK}; $_[0]->() },
);

my @commands = (
    [ 'list',        ['list'] ],
    [ 'sync',        ['sync'] ],
    [ 'sync --pull', [ 'sync', '--pull' ] ],
    [ 'create',      [ 'create', 'probe' ] ],
);

sub check {
    my ( $s, $r, $label, $cmd, $route ) = @_;
    my $cfg = `git -C '$s->{clone}' config --local --get-regexp '^karr\\.'`;
    # "karr list" is silent about a failed pull today (exit 0, empty stderr):
    # nothing to assert positively there, only that nothing leaks.
    unless ( $cmd eq 'list' ) {
        like $r->{stderr}, qr/pull failed/i, "$label: the pull failure is reported on stderr";
        # The native (libgit2) error text carries no URL, so the host is named
        # on the CLI route only.
        like $r->{stderr}, qr/127\.0\.0\.1/, "$label: and names the host" if $route eq 'cli';
    }
    unlike $r->{stdout}, qr/SECRET-TOKEN/, "$label: token not on stdout";
    unlike $r->{stderr}, qr/SECRET-TOKEN/, "$label: token not on stderr";
    unlike $r->{stderr}, qr/\@x\@|x\@127/, "$label: no tail of the password on stderr";
    unlike $cfg, qr/SECRET-TOKEN/, "$label: token not in the karr.* git config";
}

my %kinds = (
    'plain userinfo, http 500' => sub { my $p = http_stub( 500, 'boom' ); $p ? "http://user:SECRET-TOKEN\@127.0.0.1:$p/o/r.git" : undef },
    unreachable => sub { my $p = closed_port();            $p ? "http://user:SECRET-TOKEN\@x\@127.0.0.1:$p/o/r.git" : undef },
    'http 500'  => sub { my $p = http_stub( 500, 'boom' ); $p ? "http://user:SECRET-TOKEN\@x\@127.0.0.1:$p/o/r.git" : undef },
);

for my $kind ( sort keys %kinds ) {
    for my $rname ( sort keys %route ) {
        for my $c (@commands) {
            my ( $cmd, $argv ) = @$c;
            subtest "$kind, $rname route, karr $cmd" => sub {
                my $url = $kinds{$kind}->();
                plan skip_all => 'no local port / stand-in' unless $url;
                my $s = new_scene( seed => 1 );
                system( 'git', '-C', $s->{clone}, 'remote', 'set-url', 'origin', $url ) == 0 or die 'set-url';
                my $r;
                $route{$rname}->( sub { $r = run( $s, @$argv ) } );
                diag "exit=$r->{exit} stderr=$r->{stderr}" if $ENV{KARR_T_VERBOSE};
                check( $s, $r, "$kind/$rname/$cmd", $cmd, $rname );
            };
        }
    }
}

done_testing;
