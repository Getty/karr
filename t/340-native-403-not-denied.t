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
use TestHttpStub qw( http_stub );
use App::karr::Git;
use Git::Native::Error;
use Git::Libgit2 qw( GIT_EAUTH );

# Ticket k345: on the native-only route (KARR_NO_CLI_FALLBACK=1) libgit2 drops
# the HTTP body and reports a 403 only as "unexpected http status code: 403".
# A rate-limit 403 cannot be told from a write denial there, and k333 keeps
# every ambiguous case out of "denied" (which makes the clone read-only): a
# bare native 403, with no auth error beside it, is `other`.
#
# Unchanged and pinned here: a plain CLI 403 text stays denied, and a native
# error that IS an auth error (is_auth / GIT_EAUTH) stays denied.

sub classify { return App::karr::Git::_classify_push_error( $_[0], $_[1] ) }

subtest 'classifier: a bare native 403 is other, an auth error and CLI text stay denied' => sub {
    my $bare = Git::Native::Error->new( code => -1, message => 'unexpected http status code: 403' );
    my ($class) = classify($bare);
    is $class, 'other', 'bare libgit2 "unexpected http status code: 403" is other';

    my $auth = Git::Native::Error->new( code => GIT_EAUTH, message => 'unexpected http status code: 403' );
    ok $auth->is_auth, 'the double is GIT_EAUTH';
    ($class) = classify($auth);
    is $class, 'denied', 'a native 403 that IS an auth error stays denied';

    ($class) = classify('fatal: unable to access \'https://x/y.git/\': The requested URL returned error: 403');
    is $class, 'denied', 'a plain CLI 403 stays denied';

    ($class) = classify("remote: You have exceeded a secondary rate limit.\n"
        . 'fatal: unable to access \'https://x/y.git/\': The requested URL returned error: 403');
    is $class, 'other', 'a CLI 403 with a rate-limit body stays other';
};

for my $body ( 'You have exceeded a secondary rate limit.', 'Forbidden' ) {
    subtest "native-only push answered 403 ($body): not a denial" => sub {
        my $port = http_stub( 403, $body );
        plan skip_all => 'could not start a local HTTP stand-in' unless $port;
        my $s = new_scene( seed => 1 );
        system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', "http://127.0.0.1:$port/o/r.git" );
        local $ENV{KARR_NO_CLI_FALLBACK} = 1;

        my $r = run( $s, 'create', 'probe' );
        diag "exit=$r->{exit} stderr=$r->{stderr}";
        is $r->{exit}, 1, 'exit 1, as any other failed push';
        unlike $r->{stderr}, qr/was denied|read-only for the board|cannot write the board/,
            'not reported as a denial';
        like $r->{stderr}, qr/403/, 'the message tells the user the remote answered 403';

        my $c = karr_config($s);
        ok !exists $c->{'karr.readonly'}, 'git config has no karr.readonly';
        is $c->{'karr.lastpushfailure'}, 'other', 'the last push failure is recorded as other';

        my $ro = run( $s, 'readonly' );
        diag "readonly: $ro->{stdout}$ro->{stderr}";
        like $ro->{stdout}, qr/^Read-only: off\b/m,
            'karr readonly shows the clone is not read-only';

        my $next = run( $s, 'create', 'second' );
        diag "second: exit=$next->{exit} stderr=$next->{stderr}";
        unlike $next->{stderr}, qr/read-only|cannot write the board|was refused/,
            'a following writing command is not refused at the read-only door';
    };
}

done_testing;
