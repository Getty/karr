# ABSTRACT: Sync karr board with remote

package App::karr::Cmd::Sync;
our $VERSION = '0.501';
use Moo;
use MooX::Cmd;
use feature 'say';
use MooX::Options (
    usage_string => 'USAGE: karr sync [--push] [--pull] [--prune] [--accept-foreign-board]',
);
use App::karr::Role::BoardAccess;

with 'App::karr::Role::BoardAccess';

=head1 SYNOPSIS

    karr sync
    karr sync --pull
    karr sync --push

=head1 DESCRIPTION

Synchronises the C<refs/karr/*> namespace with the configured remote. Without
flags it fetches the remote ref state and then pushes the local ref state back,
pruning deleted refs so destructive restore operations can be mirrored
correctly.

Both halves run through L<App::karr::Role::SyncLifecycle>, so this command
retries exactly as every writing command does: up to three attempts each, the
first silent and the retries announced from the second, errors always on
STDERR, and C<--quiet> silencing the progress lines and the retry
announcements but never an error. A push the remote refused ref by ref is
I<not> retried -- the far side gave its answer -- unless the refusal was only
contention, two pushes racing for the same ref, which the next attempt wins
(L<App::karr::Git/push_contention>). This is the command karr points every
failed sync at, and until #183 it was the only one that pushed once and gave
up.

=head1 OPTIONS

=over 4

=item * C<--pull>

Only fetches remote C<refs/karr/*>.

=item * C<--push>

Only pushes local C<refs/karr/*> state to the configured remote.

=item * C<--prune>

Accepts a reconciliation that would delete every remaining board ref. Any
other command refuses that and stops, because "the remote deliberately
dropped the board" and "the remote is empty for the wrong reason" -- a
re-created origin, an edited remote URL, a rolled-back hosting-side restore --
look exactly alike from here. Use it to let a C<karr destroy> performed on
another clone take effect on this one; check C<git remote -v> first.

=item * C<--accept-foreign-board>

Accepts a pull whose remote presents a different board identity than the one
this clone has been syncing with. Any other pull refuses that before
reconciling anything, because a swapped remote -- a re-initialised origin, an
edited remote URL, a stale clone pointed at the wrong repository -- would
otherwise replace this board with a stranger's, silently and totally. Use it
when the remote's board really is the one you want from now on; check
C<git remote -v> first.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Board>,
L<App::karr::Cmd::Backup>, L<App::karr::Cmd::Restore>

=cut

option push => ( is => 'ro', default => 0, doc => 'Push refs to remote' );
option pull => ( is => 'ro', default => 0, doc => 'Pull refs from remote' );
option prune => (
    is      => 'ro',
    default => 0,
    doc     => 'Accept a pull that deletes every remaining board ref',
);
option accept_foreign_board => (
    is      => 'ro',
    default => 0,
    doc     => 'Accept a pull whose remote presents a different board identity',
);

sub execute {
    my ( $self, $args, $data ) = @_;

    my $git = $self->git;

    unless ( $git->is_repo ) {
        say "Not a git repository. Skipping sync.";
        return;
    }

    my $email = $git->git_user_email;
    my $name = $git->git_user_name;
    unless ($email) {
        say q(No git user.email configured. Run: git config --global user.email 'you@example.com');
        return;
    }

    say "User: $name <$email>";

    my $push_only = $self->push && !$self->pull;
    my $pull_only = $self->pull && !$self->push;

    # Both halves go through App::karr::Role::SyncLifecycle, which this command
    # has composed all along (via App::karr::Role::BoardAccess) without using.
    # It called $git->pull and $git->push exactly once each and died on a false
    # return -- so the command every failed sync is pointed at ("Run 'karr sync'
    # to retry") was the one command with no retry and no idea what contention
    # is, while #181 had already taught the role and the insurance push to spend
    # their three attempts on a push another push had merely beaten to a ref
    # (#183). Nothing is duplicated here: the retry-only output, the "errors
    # always on STDERR, --quiet silences only the banners" contract, and the
    # refusal-versus-contention verdict all live in the role.
    unless ($push_only) {
        print STDERR "Pulling refs/karr/ from remote...\n" unless $self->quiet;
        # --prune is the one place that may reconcile the board down to
        # nothing, and --accept-foreign-board the one place that may adopt a
        # remote whose board identity is not this board's; everywhere else
        # App::karr::Git refuses and says so (#82, #95). The role forwards both
        # to App::karr::Git::pull unchanged, on every attempt -- neither is ever
        # implied, and a retry does not quietly widen what was allowed.
        my @accept = (
            accept_wipe    => $self->prune,
            accept_foreign => $self->accept_foreign_board,
        );
        # sync_before is sync_pull plus a SyncGuard, and a guard left armed is
        # a push at process teardown -- exactly what --pull says not to do. So
        # the pull-only form takes the pull without the insurance.
        $pull_only ? $self->sync_pull(@accept) : $self->sync_before(@accept);
    }

    unless ($pull_only) {
        print STDERR "Pushing refs/karr/ to remote...\n" unless $self->quiet;
        $self->sync_after;
    }

    say "Done.";
}

1;
