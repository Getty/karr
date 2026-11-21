#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run karr_config closed_port_url );
use TestHttpStub qw( http_stub );

# Ticket k334 (follow-up of k333): on the native route a failed push or pull is
# reported by its MESSAGE only. The Git::Native::Error libgit2 throws is a
# Throwable with a stack trace in its stringification; _push_refspecs and
# _fetch_refspecs used to store that string, so ~30 lines of "Trace begun at
# .../Git/Native/Error.pm" landed in the "git push failed: ..." line on STDERR.
# The classification of the failure (k333) must survive the cleanup.

$ENV{KARR_NO_CLI_FALLBACK} = 1;

# Whatever shape a trace has, it names the Throwable's own file and the call
# chain; the message never does.
sub no_trace {
    my ( $err, $label ) = @_;
    unlike $err, qr/Trace begun/,                 "$label: no 'Trace begun'";
    unlike $err, qr{Git/Native/Error\.pm},        "$label: no Git/Native/Error.pm frame";
    unlike $err, qr/^\S+::\w+\(.*\) called at /m, "$label: no 'called at' call-chain line";
}

my @targets = (
    [ unreachable => sub { closed_port_url() }, qr/(?:connect|refused)/i, 'unreachable' ],
    [ http500     => sub { 'http://127.0.0.1:' . http_stub( 500, 'boom' ) . '/o/r.git' },
                    qr/unexpected http status code: 500/, 'other' ],
);

for my $t (@targets) {
    my ( $name, $url_for, $message, $class ) = @$t;

    subtest "push failure, $name: message only" => sub {
        my $s   = new_scene( seed => 1 );
        my $url = $url_for->();
        system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', $url );

        my $r = run( $s, 'create', 'probe' );
        isnt $r->{exit}, 0, 'the push failure is a failure';
        like $r->{stderr}, qr/git push failed: /, 'stderr carries the push failure';
        like $r->{stderr}, $message,              'with the transport message';
        no_trace( $r->{stderr}, 'create' );

        is karr_config($s)->{'karr.lastpushfailure'}, $class, "classified as $class (k333 still holds)";

        my $l = run( $s, 'list', '--compact' );
        my ($last) = $l->{stderr} =~ /(Last push: [^\n]*)/;
        ok defined $last, 'a following list names the last push';
        no_trace( $l->{stderr}, 'list' );
        unlike $last // '', qr/\bcalled at\b|Trace/, 'the Last push reason is a short phrase';
    };

    subtest "pull failure, $name: message only" => sub {
        my $s   = new_scene( seed => 1 );
        my $url = $url_for->();
        system( 'git', '-C', $s->{clone}, 'remote', 'set-url', 'origin', $url );

        my $r = run( $s, 'sync', '--pull' );
        isnt $r->{exit}, 0, 'the pull failure is a failure';
        like $r->{stderr}, qr/git pull failed: /, 'stderr carries the pull failure';
        like $r->{stderr}, $message,              'with the transport message';
        no_trace( $r->{stderr}, 'sync --pull' );
    };
}

done_testing;
