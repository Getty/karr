#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run karr_config );
use TestHttpStub qw( http_stub closed_port );
use App::karr::Error ();
use App::karr::Git;
use App::karr::CloneState;

# Ticket k333 (review finding R3): a push failure's text is stored in git
# config and printed on every later command, and it carries URLs -- a token in
# an https URL is a secret. The userinfo is taken out of every URL in the text
# (App::karr::Error::strip_userinfo), and it runs to the LAST "@" before the
# host ends: a password typed with a raw "@" in it went only up to the first
# one, so "https://user:p@ss@host/x" came out as "https://ss@host/x".

my @table = (
    [ 'https://user:p@ss@host/x'                          => 'https://host/x',                    'a raw @ in the password' ],
    [ 'https://user:p@ss@host'                            => 'https://host',                      'no path after the host' ],
    [ "fatal: unable to access 'https://tok\@github.com/x/': boom"
                                                          => "fatal: unable to access 'https://github.com/x/': boom", 'in free text' ],
    [ 'push to https://user:pw@host/a and ssh://user:pw@host/b failed'
                                                          => 'push to https://host/a and ssh://host/b failed', 'every URL in a text' ],
    [ 'ssh://git@host:2222/o/r.git'                       => 'ssh://host:2222/o/r.git',           'ssh:// with a port' ],
    [ 'git@github.com:o/r.git'                            => 'git@github.com:o/r.git',            'scp-style is an address, kept' ],
    [ "failed to push some refs to 'git\@github.com:o/r.git'"
                                                          => "failed to push some refs to 'git\@github.com:o/r.git'", 'scp-style in free text, kept' ],
    [ 'https://host/~user@x/repo'                         => 'https://host/~user@x/repo',         'an @ in the path is not userinfo' ],
    [ 'mail a@b.c about https://h/x'                      => 'mail a@b.c about https://h/x',      'an address in the text is not touched' ],
    [ 'http://cr@t@127.0.0.1:18429/o/r.git/'              => 'http://127.0.0.1:18429/o/r.git/',   'port and trailing slash' ],
    [ 'no url here'                                       => 'no url here',                       'text without a URL' ],
);
for my $t (@table) {
    my ( $in, $out, $label ) = @$t;
    is App::karr::Error::strip_userinfo($in), $out, "strip_userinfo: $label";
    is App::karr::Git::without_userinfo($in), $out, "without_userinfo: $label (same cleanup)";
}
is App::karr::Error::strip_userinfo(undef), undef, 'strip_userinfo: undef stays undef';
is App::karr::Git::without_userinfo(undef), undef, 'without_userinfo: undef stays undef';
is( App::karr::Git->without_userinfo('https://u:p@ss@h/x'), 'https://h/x', 'without_userinfo is callable as a class method' );

# --- the board's own clone state -----------------------------------------
subtest 'CloneState stores a reason stripped, and prints a raw one stripped' => sub {
    my $s = new_scene( seed => 1 );
    my $git = App::karr::Git->new( dir => $s->{clone} );

    # Through CloneState: what lands in git config.
    my $state = App::karr::CloneState->for_git( $git, remote => 'origin' );
    $state->note_push_failure( { class => 'other', remote => 'origin',
        reason => "fatal: unable to access 'https://user:SECRET-TOKEN\@host/x/': boom" } );
    my $c = karr_config($s);
    unlike $c->{'karr.lastpushreason'}, qr/SECRET-TOKEN/, 'karr.lastPushReason stored without the token';
    like $c->{'karr.lastpushreason'}, qr{'https://host/x/'}, 'but with the rest of the URL';

    $state->learn_denied( { class => 'denied', remote => 'origin',
        reason => "denied for 'https://u:SECRET-TOKEN\@h/x'" } );
    $c = karr_config($s);
    unlike $c->{'karr.readonlyreason'}, qr/SECRET-TOKEN/, 'karr.readonlyReason stored without the token';
    unlike join( "\n", values %$c ), qr/SECRET-TOKEN/, 'and no karr.* key holds it';
};

subtest 'values written raw into git config (before this cleanup) print stripped' => sub {
    my $s = new_scene( seed => 1 );
    my $cfg = sub { system( 'git', '-C', $s->{clone}, 'config', @_ ) };

    # A reason on the lasting warning: an unpublished card plus a failed push.
    is run( $s, 'create', 'older', '--local-only' )->{exit}, 0, 'an unpublished card (precondition)';
    $cfg->( 'karr.lastPushFailure', 'other' );
    $cfg->( 'karr.lastPushReason',  "fatal: unable to access 'https://SECRET-TOKEN\@github.com/x/': boom" );
    $cfg->( 'karr.lastPushAt',      '2026-01-01T00:00:00Z' );
    my $r = run( $s, 'list' );
    is $r->{exit}, 0, 'list works';
    like $r->{stderr}, qr/Last push: failed: fatal: unable to access 'https:\/\/github\.com\/x\/': boom/,
        'the warning line carries the reason, without the userinfo';
    unlike $r->{stderr} . $r->{stdout}, qr/SECRET-TOKEN/, 'the token is nowhere';

    # The refusal of a write in a clone read-only after a denial.
    $cfg->( '--unset', $_ ) for qw( karr.lastPushFailure karr.lastPushReason karr.lastPushAt );
    $cfg->( 'karr.readonly',        'denied' );
    $cfg->( 'karr.readonlyPushUrl', $s->{origin} );
    $cfg->( 'karr.readonlyReason',  "denied for 'https://u:SECRET-TOKEN\@h/x'" );
    $cfg->( 'karr.readonlySince',   '2026-01-01T00:00:00Z' );
    $r = run( $s, 'create', 'refused' );
    is $r->{exit}, 1, 'a write is refused';
    like $r->{stderr}, qr/was denied on 2026-01-01T00:00:00Z \(denied for 'https:\/\/h\/x'\)/, 'the refusal states the reason without the userinfo';
    unlike $r->{stderr}, qr/SECRET-TOKEN/, 'the token is nowhere';
};

subtest 'push_url of a remote whose password holds a raw @ is clean' => sub {
    my $s = new_scene( seed => 1 );
    system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', 'http://tok:se@cr@t@127.0.0.1:18429/o/r.git' );
    my $git = App::karr::Git->new( dir => $s->{clone} );
    is $git->push_url, 'http://127.0.0.1:18429/o/r.git', 'no userinfo at all, not "cr@t@..."';
};

# --- end to end: a secret in the remote URL never surfaces ----------------
sub secret_free {
    my ( $s, $r, $label ) = @_;
    my $cfg = `git -C '$s->{clone}' config --local --get-regexp '^karr\\.'`;
    unlike $r->{stdout}, qr/SECRET-TOKEN/, "$label: not on stdout";
    unlike $r->{stderr}, qr/SECRET-TOKEN/, "$label: not on stderr";
    unlike $cfg, qr/SECRET-TOKEN/, "$label: not in the karr.* git config";
    my $l = run( $s, 'list' );
    unlike $l->{stdout} . $l->{stderr}, qr/SECRET-TOKEN/, "$label: not in what a following karr list prints";
}

subtest 'unreachable remote with a secret in the URL' => sub {
    my $port = closed_port();
    plan skip_all => 'no free local port' unless $port;
    my $s = new_scene( seed => 1 );
    system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', "http://user:SECRET-TOKEN\@127.0.0.1:$port/x.git" );
    my $r = run( $s, 'create', 'probe' );
    is $r->{exit}, 1, 'the create fails (exit 1)';
    secret_free( $s, $r, 'unreachable' );
};

subtest 'remote answering 500 with the secret in the URL (class other)' => sub {
    my $port = http_stub( 500, 'boom' );
    plan skip_all => 'could not start a local HTTP stand-in' unless $port;
    my $s = new_scene( seed => 1 );
    system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', "http://SECRET-TOKEN\@127.0.0.1:$port/o/r.git" );
    my $r = run( $s, 'create', 'probe' );
    is $r->{exit}, 1, 'the create fails (exit 1)';
    secret_free( $s, $r, 'other' );
};

subtest 'password with a raw @ against the stand-in' => sub {
    my $port = http_stub( 500, 'boom' );
    plan skip_all => 'could not start a local HTTP stand-in' unless $port;
    my $s = new_scene( seed => 1 );
    system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', "http://user:SECRET-TOKEN\@x\@127.0.0.1:$port/o/r.git" );
    my $r = run( $s, 'create', 'probe' );
    is $r->{exit}, 1, 'the create fails (exit 1)';
    secret_free( $s, $r, 'raw @' );
    unlike $r->{stderr}, qr/\@x\@|x\@127/, 'and no tail of the password either';
};

done_testing;
