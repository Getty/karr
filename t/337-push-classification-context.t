#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use Path::Tiny qw( path );
use TestDenied qw( new_scene run karr_config can_deny );
use TestHttpStub qw( http_stub );
use App::karr::Git;

# Ticket k333 (review finding R2): "denied" makes a clone read-only, so it must
# not be said of anything but "this clone has no write access". Three things
# that were taken for it, each pinned here:
#
#   - a rate limit (a 403 or 429 the remote sends because this clone asked too
#     often) is `other`;
#   - a ref the remote refused for a reason of its own -- a hook declining, in
#     whatever words the hook used -- is `rejected`;
#   - "Permission denied" about anything but the remote's files -- this clone's
#     own .git, a hook script, a remote whose path merely contains "hook" -- is
#     not the remote's answer.
#
# _classify_push_error( $text, $ctx ) takes the context
# App::karr::Git::_push_context builds: remote_paths (the remote's repository
# path when it is a local one) and rejected (the refs `git push --porcelain`
# listed as refused, each { ref, reason }). The first half is a table; the
# second half runs real pushes.

sub classify { return App::karr::Git::_classify_push_error( $_[0], $_[1] ) }

my $FILES = "this user cannot write the remote repository's files";
my $RATE  = 'the remote is rate limiting requests';
sub declined { return { rejected => [ { ref => 'refs/karr/x', reason => 'pre-receive hook declined' } ], @_ } }

# [ label, text, ctx, class, reason ]
my @cases = (
    # --- a hook declining: the push reached the remote, its answer is per ref
    [ 'hook words "Permission denied" + declined ref are not a denial',
      "remote: error: Permission denied: hook refuses refs/karr/x",
      declined(), other => 'remote: error: Permission denied: hook refuses refs/karr/x' ],
    [ 'a hook script the remote cannot read (its own Permission denied)',
      "remote: /bin/sh: 0: cannot open /srv/o.git/hooks/pre-receive: Permission denied",
      declined( remote_paths => ['/srv/o.git'] ), other => undef ],

    # --- a path that contains "hook" is not a hook
    [ 'a remote at /srv/webhooks.git whose objects dir is unwritable is still denied',
      "failed to create temporary file '/srv/webhooks.git/objects/pack/pack_git2_x': Permission denied",
      { remote_paths => ['/srv/webhooks.git'] }, denied => $FILES ],

    # --- the lock on a ref of an unwritable remote, per-ref reasons that carry no answer
    [ 'cannot lock ref, "atomic transaction failed"',
      "remote: error: cannot lock ref 'refs/karr/x': Unable to create '/srv/o.git/./refs/karr/x.lock': Permission denied",
      { rejected => [ { ref => 'refs/karr/x', reason => 'atomic transaction failed' } ], remote_paths => ['/srv/o.git'] },
      denied => $FILES ],
    [ 'cannot lock ref, "failed to update ref"',
      "remote: error: cannot lock ref 'refs/karr/x': Unable to create '/srv/o.git/./refs/karr/x.lock': Permission denied",
      { rejected => [ { ref => 'refs/karr/x', reason => 'failed to update ref' } ], remote_paths => ['/srv/o.git'] },
      denied => $FILES ],
    [ 'cannot lock ref, "unpacker error"',
      "remote: error: cannot lock ref 'refs/karr/x': Unable to create '/srv/o.git/./refs/karr/x.lock': Permission denied",
      { rejected => [ { ref => 'refs/karr/x', reason => 'unpacker error' } ], remote_paths => ['/srv/o.git'] },
      denied => $FILES ],

    # --- libgit2 on a local remote: only a line naming the remote's path counts
    [ 'libgit2 temp file, with the remote path: denied',
      "failed to create temporary file '/srv/o.git/objects/pack/pack_git2_x': Permission denied",
      { remote_paths => ['/srv/o.git'] }, denied => $FILES ],
    [ 'libgit2 temp file, without it: other',
      "failed to create temporary file '/srv/o.git/objects/pack/pack_git2_x': Permission denied",
      undef, other => undef ],

    # --- this clone's own .git is not the remote's
    [ 'libgit2: FETCH_HEAD of this clone is locked',
      "failed open - '/home/u/a/.git/FETCH_HEAD' is locked: Permission denied",
      { remote_paths => ['/srv/o.git'] }, other => undef ],
    [ 'git CLI: cannot open .git/FETCH_HEAD',
      "cannot open '.git/FETCH_HEAD': Permission denied",
      { remote_paths => ['/srv/o.git'] }, other => undef ],

    # --- a rate limit
    [ 'CLI 429: Too Many Requests',
      "remote: Too Many Requests\nfatal: unable to access 'https://h/x/': The requested URL returned error: 429",
      undef, other => $RATE ],
    [ 'libgit2 429',
      'unexpected http status code: 429', undef, other => $RATE ],
    [ 'CLI 403 with a secondary rate limit body',
      "remote: You have exceeded a secondary rate limit.\nfatal: unable to access 'https://h/x/': The requested URL returned error: 403",
      undef, other => $RATE ],
    [ 'a plain 403 stays denied (nothing says rate limit)',
      "fatal: unable to access 'https://h/x/': The requested URL returned error: 403",
      undef, denied => undef ],
);

for my $case (@cases) {
    my ( $label, $text, $ctx, $class, $reason ) = @$case;
    my ( $got, $why ) = classify( $text, $ctx );
    is $got, $class, "$label: class";
    if ( defined $reason ) { is $why, $reason, "$label: reason" }
    else { ok defined $why && length $why, "$label: has a reason" }
}

subtest 'other keeps the first line of the text as its reason' => sub {
    my ( $c, $why ) = classify( "remote: error: Permission denied: hook refuses refs/karr/x\nsecond line",
        declined() );
    is $c, 'other', 'other';
    is $why, 'remote: error: Permission denied: hook refuses refs/karr/x', 'the first line only';
};

# ---------------------------------------------------------------------
# Real pushes.
# ---------------------------------------------------------------------

# --- a hook that says "Permission denied" while declining ----------------
subtest 'a pre-receive hook refusing in words that say "Permission denied": rejected, no read-only state' => sub {
    my $s = new_scene( seed => 1 );
    my $hook = path("$s->{origin}/hooks/pre-receive");
    $hook->spew("#!/bin/sh\necho 'error: Permission denied: hook refuses refs/karr/x' >&2\nexit 1\n");
    chmod 0755, "$hook";

    # Through the Git object, the verdict it hands back.
    my $git = App::karr::Git->new( dir => $s->{clone} );
    $git->write_ref( 'refs/karr/x', "hi\n" );
    ok !$git->push, 'the push fails';
    my $failure = $git->push_failure;
    ok $failure, 'and says why';
    is $failure->{class}, 'rejected', 'the verdict is rejected, not denied';

    # Through the command.
    my $r = run( $s, 'create', 'probe' );
    is $r->{exit}, 1, 'karr create ends with exit 1';
    unlike $r->{stderr}, qr/was denied|read-only for the board/, 'without a denial message';
    my $c = karr_config($s);
    ok !exists $c->{'karr.readonly'}, 'git config has no karr.readonly';
    my $l = run( $s, 'list' );
    unlike $l->{stderr}, qr/cannot write the board|read-only/, 'and a later karr list gives no denied warning';
};

# --- a remote that rate limits --------------------------------------------
for my $stub ( [ 429, 'Too Many Requests' ], [ 403, 'You have exceeded a secondary rate limit.' ] ) {
    my ( $status, $body ) = @$stub;
    subtest "a remote answering $status ($body): other, the clone stays writable" => sub {
        my $port = http_stub( $status, $body );
        plan skip_all => 'could not start a local HTTP stand-in' unless $port;
        my $s = new_scene( seed => 1 );
        system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', "http://127.0.0.1:$port/o/r.git" );

        my $r = run( $s, 'create', 'probe' );
        is $r->{exit}, 1, 'exit 1';
        unlike $r->{stderr}, qr/was denied|read-only for the board/, 'not reported as a denial';
        my $c = karr_config($s);
        ok !exists $c->{'karr.readonly'}, 'git config has no karr.readonly';
        is $c->{'karr.lastpushreason'}, 'the remote is rate limiting requests', 'karr.lastPushReason says rate limit';
        is $c->{'karr.lastpushfailure'}, 'other', 'class other';
    };
}

done_testing;
