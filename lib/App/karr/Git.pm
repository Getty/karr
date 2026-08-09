# ABSTRACT: Git operations for karr sync (native via Git::Native + libgit2, with a git-CLI transport fallback)

package App::karr::Git;
our $VERSION = '0.403';
use strict;
use warnings;
use Path::Tiny qw( path );
use Try::Tiny;
use IPC::Open3 qw( open3 );
use IO::Select;
use Symbol qw( gensym );
use Errno qw( EINTR );
use POSIX qw( WNOHANG );
use Scalar::Util qw( blessed );
use Time::HiRes ();
use Git::Libgit2 qw( GIT_ELOCKED );
use App::karr::Encoding qw(
    BOARD_ENCODING_VERSION
    to_octets from_octets yaml_dump yaml_load repair_mojibake
);
use Git::Native;
use Git::Native::Signature;
use Git::Native::Credential;
use App::karr::Task;

=head1 SYNOPSIS

    my $git = App::karr::Git->new(dir => '.');

    $git->pull;
    my @ids = $git->list_task_refs;
    my $task = $git->load_task_ref($ids[0]);

=head1 DESCRIPTION

L<App::karr::Git> provides the low-level Git interface used by C<karr> for
syncing board state through C<refs/karr/*>. Local object/ref ops (read/write/
delete of refs, blobs, trees, commits) run natively via L<Git::Native> (FFI
to libgit2) with no fork/exec. SSH-agent and HTTPS-token credentials are
supplied through the libgit2 credential-acquire callback.

Network fetch/push (C<fetch>, C<pull>, C<push>, C<push_ref>, C<pull_ref>)
also try the native libgit2 transport first. If that transport fails, they
fall back to the system C<git> CLI (via L<IPC::Open3>), because libgit2/
libssh2 doesn't read C<~/.ssh/config> and can't run a C<ProxyCommand> —
directives like C<Host> aliases, C<IdentityFile>, and C<insteadOf> only take
effect through the CLI. Set C<KARR_NO_CLI_FALLBACK=1> to disable the
fallback and surface native transport failures directly.

Every CLI transport run is bounded by a wall-clock timeout, 120 seconds by
default; C<KARR_TRANSPORT_TIMEOUT> overrides it (in seconds, C<0> disables
it). A run that blows the timeout is killed and reported as a failure.

C<push> sends C<refs/karr/*> under a forced, pruning refspec. C<pull> is its
inverse, but it never fetches straight into the board: the remote state lands
in a per-remote tracking mirror under C<refs/karr-remote/>, and the local
board is then reconciled against it. That mirror is what tells a ref the
remote I<deleted> apart from one that only exists locally because it has not
been pushed yet -- the first is pruned, the second is kept. Where both sides
changed the same ref the remote version takes the slot, the local one is
parked under C<refs/karr-conflict/>, and a warning names both. Neither extra
namespace is ever pushed.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::BoardStore>, L<App::karr::Task>,
L<App::karr::Config>, L<Git::Native>

=cut

sub new {
    my ( $class, %args ) = @_;
    return bless {
        dir => $args{dir} // '.',
    }, $class;
}

sub dir {
    my ($self) = @_;
    return path( $self->{dir} );
}

# The libgit2 exception text from the most recent remote operation that failed
# (fetch/push/pull). Native operations have no shell exit code, so callers
# report this instead of $?. When the git-CLI transport fallback ran (see
# _cli_transport below), this instead carries the real git-CLI stderr.
sub last_error {
    my ($self) = @_;
    return $self->{_last_error};
}

# Ref writes and deletes performed in this process. App::karr::SyncGuard reads
# it on the die path -- where no push has succeeded by definition -- to tell
# "the command died before writing anything" (nothing to push, stay quiet)
# apart from "local refs changed and never reached the remote" (say so).
#
# Deliberately a package scalar rather than per-object state. The guard reads
# the count from DESTROY during global destruction, and perl tears that phase
# down in two passes: sv_clean_objs() destroys every blessed object first, then
# sv_clean_all() frees everything else. So when DESTROY runs, another object may
# already be gone while a plain non-object SV like this one is still intact.
# Reading the count off $git made the quiet/loud decision a coin flip -- over 60
# identical runs of one failing command $git was still there 52 times and
# already reaped 8, so 13% of plain usage errors printed sync advice for a
# board that had never been written to (#34).
our $WRITES = 0;

sub pending_writes {
    return $WRITES;
}

# ----- Native repository handle (lazy) -----

# libgit2 is reached through FFI::Platypus, and both its type parser and
# FFI::CheckLib's library-search tables are package-level state. Perl frees
# that state during global destruction in no defined order, and re-entering it
# there does not fail cleanly: FFI::CheckLib re-runs its search against
# already-undefined globals and FFI::Platypus::TypeParser::Version1::parse
# recurses without bound, allocating around 700 MB/s until the machine is out
# of memory (#34 -- observed at 53 GB RSS on a 62 GB box, killable only from
# outside).
#
# karr is built to be driven by unattended agents, so that failure mode is not
# survivable. _repo and is_repo are the gate: every native operation reachable
# from a teardown path goes through them, and every caller already treats a
# false _repo as "no usable repository", so the runaway degrades into an
# ordinary failure with last_error set. (validate_helper_ref calls libgit2
# directly, but nothing destroys helper refs during teardown.)
sub _in_global_destruction {
    return ${^GLOBAL_PHASE} eq 'DESTRUCT' ? 1 : 0;
}

sub _repo {
    my ($self) = @_;
    if ( _in_global_destruction() ) {
        $self->{_last_error} =
            'refused: libgit2 is not re-entrant during global destruction';
        return undef;
    }
    return $self->{_repo} if $self->{_repo};
    return undef unless $self->is_repo;
    $self->{_repo} = Git::Native->open_ext( $self->dir->stringify );
    return $self->{_repo};
}

sub _signature {
    my ($self) = @_;
    # Reuse one signature per process; falls back if user.name/email unset.
    return $self->{_sig} if $self->{_sig};
    my $repo = $self->_repo or return;
    $self->{_sig} = try { $repo->signature_default }
                    catch {
                      Git::Native::Signature->new(
                        name  => $self->git_user_name  || 'karr',
                        email => $self->git_user_email || 'karr@localhost',
                      );
                    };
    return $self->{_sig};
}

# ----- Repo discovery -----

sub is_repo {
    my ($self) = @_;
    return 0 if _in_global_destruction();
    my $ok = try {
        # open_ext walks up to find a .git; throws on miss.
        Git::Native->open_ext( $self->dir->stringify );
        1;
    } catch { $self->{_last_error} = "$_"; 0 };
    return $ok;
}

sub repo_root {
    my ($self) = @_;
    my $repo = $self->_repo or return undef;
    # workdir is undef for bare repos; in that case fall back to gitdir.
    my $root = $repo->workdir // $repo->gitdir;
    $root =~ s{/+\z}{};
    return path($root);
}

# ----- Working-tree file status -----

# libgit2's status flags. A path git carries in the index or HEAD reports
# anything *except* these two: GIT_STATUS_WT_NEW is "untracked" and
# GIT_STATUS_IGNORED is "untracked and matched by a .gitignore rule". An
# unmodified tracked file reports GIT_STATUS_CURRENT (0), and ignore rules do
# not apply to tracked files -- which is the case that matters here, because
# `karr init` puts tasks/ and config.yml into .gitignore.
use constant GIT_STATUS_WT_NEW  => 0x0080;
use constant GIT_STATUS_IGNORED => 0x4000;

sub is_tracked {
    my ( $self, $file ) = @_;
    my $repo = $self->_repo   or return 0;
    my $root = $self->repo_root or return 0;

    # status_for_path wants a path relative to the work tree. Resolve both ends
    # through the containing directory (the file itself may not exist yet) so a
    # symlinked work tree does not make every path look like it escapes.
    $file = path($file)->absolute;
    my $parent = try { $file->parent->realpath } catch { undef } or return 0;
    my $base   = try { $root->realpath }        catch { $root };
    my $rel    = $parent->child( $file->basename )->relative($base)->stringify;
    return 0 if $rel =~ m{\A\.\.(?:/|\z)};   # outside the work tree

    # Throws GIT_ENOTFOUND for a path git has never heard of and that is not on
    # disk either; that is simply "not tracked".
    my $status = try { $repo->status_for_path($rel) } catch { undef };
    return 0 unless defined $status;
    return $status & ( GIT_STATUS_WT_NEW | GIT_STATUS_IGNORED ) ? 0 : 1;
}

=head2 is_tracked

Returns true when the given working-tree path is under version control -- known
to the index or to C<HEAD>. Untracked and ignored paths, paths outside the work
tree, and anything in a repository that cannot be opened all return false.

    if ( $git->is_tracked($file) ) {
        # deleting or overwriting it would be data loss
    }

=cut

# ----- User identity (read via native config, not via CLI) -----

sub _config_string {
    my ( $self, $key ) = @_;
    my $repo = $self->_repo or return '';
    my $val = try { $repo->config_string($key) } catch { undef };
    return defined $val ? $val : '';
}

sub git_user_email {
    my ($self) = @_;
    return $self->_config_string('user.email');
}

sub git_user_name {
    my ($self) = @_;
    return $self->_config_string('user.name');
}

sub git_user_identity {
    my ($self) = @_;
    my $name = $self->git_user_name;
    my $email = $self->git_user_email;
    return "$name <$email>" if $name && $email;
    return $email || $name || '';
}

# ----- Ref name validation -----

sub normalize_ref_name {
    my ( $self, $ref ) = @_;
    defined $ref or die "Ref name is required\n";
    $ref =~ s{^/+}{};
    return $ref =~ m{^refs/} ? $ref : "refs/$ref";
}

sub validate_helper_ref {
    my ( $self, $ref ) = @_;
    my $full_ref = $self->normalize_ref_name($ref);

    my @blocked = (
        'refs/heads/',
        'refs/tags/',
        'refs/remotes/',
        'refs/bisect/',
        'refs/replace/',
        'refs/karr/',
    );

    for my $prefix (@blocked) {
        die "Ref '$full_ref' is in a protected namespace\n"
            if index( $full_ref, $prefix ) == 0;
    }
    die "Ref '$full_ref' is in a protected namespace\n"
        if $full_ref eq 'refs/stash' || index( $full_ref, 'refs/stash/' ) == 0;

    # Native validity check via Git::Native.
    die "Ref '$full_ref' is not a valid git ref name\n"
        unless Git::Native->reference_name_is_valid($full_ref);

    return $full_ref;
}

# ----- Ref CRUD (the hotspot — was 4 fork/exec per write_ref) -----

# How many times a contended ref write is re-attempted before karr gives up,
# and the backoff between attempts. Contention here is measured in the time it
# takes libgit2 to take refs/<name>.lock, write and rename -- microseconds --
# so a few milliseconds of randomised sleep is enough to break up a pile-up.
# The randomisation is the point: a fixed delay makes every loser wake up
# together and collide again.
#
# Bounded on purpose. karr is driven by unattended agents, and a write loop
# that can spin forever on a genuinely wedged ref is worse than one that fails
# with something the agent can report.
use constant CAS_ATTEMPTS       => 32;
use constant CAS_BACKOFF_STEP   => 0.001;   # seconds, times the attempt number
use constant CAS_BACKOFF_CAP    => 0.010;   # ...but never longer than this
use constant CAS_BACKOFF_JITTER => 0.005;

# Run $attempt until it commits to an answer, with backoff in between.
#
# $attempt returns the empty list to mean "another writer got in first, read
# again and retry"; any other return value is the final answer and comes back
# to the caller untouched (in list context as the list it returned). Anything
# it dies with propagates immediately -- a real failure is not retried.
#
# Every compare-and-swap caller goes through here, so the rules for what counts
# as contention live in exactly one place (see _is_contended_ref_error).
sub retry_contended {
    my ( $self, $what, $attempt ) = @_;
    for my $try ( 1 .. CAS_ATTEMPTS ) {
        my @answer = $attempt->($try);
        return wantarray ? @answer : $answer[0] if @answer;
        _cas_backoff($try);
    }
    die "karr: gave up updating $what after " . CAS_ATTEMPTS
      . " attempts -- too many agents are writing the board at once. "
      . "Try again.\n";
}

sub _cas_backoff {
    my ($try) = @_;
    my $step = CAS_BACKOFF_STEP * $try;
    $step = CAS_BACKOFF_CAP if $step > CAS_BACKOFF_CAP;
    Time::HiRes::sleep( $step + rand CAS_BACKOFF_JITTER );
    return;
}

# A ref write fails for two very different reasons once more than one agent is
# on the board, and telling them apart is the whole fix for #44 and #46:
#
#   GIT_EMODIFIED  the ref moved out from under the OID we guarded against
#   GIT_ENOTFOUND  ...or was deleted, which is the same thing when we expected
#                  a specific old value
#   GIT_ELOCKED    another process holds refs/<name>.lock right now
#
# All three are transient: read again and retry. Everything else is real.
#
# GIT_ELOCKED is the one that actually decides whether this works. It is the
# common outcome under contention -- libgit2 takes a lock file per ref -- and
# Git::Native::Error has no predicate for it, so it has to be compared against
# the code. A loop that retries only is_not_matched still loses most writes:
# 16 contenders on one counter left 4 processes dead and 4 increments missing.
sub _is_contended_ref_error {
    my ( $err, $guarded ) = @_;
    return 0 unless blessed($err) && $err->isa('Git::Native::Error');
    return 1 if $err->code == GIT_ELOCKED;
    return 1 if $err->is_not_matched;
    return 1 if $guarded && $err->is_not_found;
    return 0;
}

# libgit2 exceptions are Throwable::Error, so stringifying one prints the
# message followed by a stack trace full of module paths and line numbers.
# That used to reach the user verbatim when an ordinary concurrent ref write
# aborted a command mid-body (#46). Keep the first line of libgit2's own
# message and drop the rest; the trailing newline stops perl appending
# " at ... line N." on top.
sub _ref_write_error {
    my ( $ref, $err ) = @_;
    my $detail = blessed($err) && $err->can('message') ? $err->message : "$err";
    $detail =~ s/ at \S+ line \d+\.?.*\z//s;
    $detail =~ s/\n.*\z//s;
    $detail =~ s/\s+\z//;
    $detail = 'unknown git error' unless length $detail;
    return "karr: could not write $ref: $detail\n";
}

# The parentless commit every board ref points at. Built once per write, not
# once per attempt: the content does not change while we are losing races for
# the ref, and rebuilding it would leave a dangling object behind each time.
sub _commit_for_content {
    my ( $self, $repo, $content ) = @_;
    my $blob_oid = $repo->blob_create_frombuffer( to_octets($content) );
    my $tb       = $repo->tree_builder;
    $tb->insert(name => 'data', oid => $blob_oid, mode => 0100644);
    my $tree_oid = $tb->write;

    my $sig = $self->_signature;
    return $repo->commit_create(
        tree       => $tree_oid,
        parents    => [],
        message    => 'karr ref update',
        author     => $sig,
        committer  => $sig,
    );
}

# Ref blobs are the octet edge of the board (see App::karr::Encoding): callers
# above this line hand over and receive character strings, and
# _commit_for_content / read_ref_with_oid are the only two places that convert.
#
# Unconditional last-writer-wins, which is what most callers want. It still
# retries, because losing the race for refs/<name>.lock is not a failed write,
# it is a write that has not been attempted yet -- letting that escape killed
# 9 of 12 contenders outright (#46).
sub write_ref {
    my ( $self, $ref, $content ) = @_;
    my $repo = $self->_repo or return;
    my $commit_oid = $self->_commit_for_content( $repo, $content );

    return $self->retry_contended( "ref $ref", sub {
        my $wrote = try {
            $repo->reference_create( $ref, $commit_oid, force => 1 );
            1;
        } catch {
            my $err = $_;
            return 0 if _is_contended_ref_error( $err, 0 );
            die _ref_write_error( $ref, $err );
        };
        return () unless $wrote;
        $WRITES++;
        return 1;
    } );
}

# Compare-and-swap sibling of write_ref: the write lands only if the ref still
# holds $expected_old, where undef means "the ref must not exist at all".
#
# Returns 1 when the write landed and 0 when someone else got there first --
# the caller is expected to be inside retry_contended, re-read whatever it
# decided on, and try again. A real failure dies with a karr-level message.
#
# $WRITES counts writes that actually landed. SyncGuard reads it to decide
# whether local refs still need pushing, so a lost race must not bump it.
sub write_ref_cas {
    my ( $self, $ref, $content, $expected_old ) = @_;
    my $repo = $self->_repo
        or die "karr: could not write $ref: "
             . ( $self->last_error // 'no usable git repository' ) . "\n";

    my $commit_oid = $self->_commit_for_content( $repo, $content );
    my $wrote = try {
        $repo->reference_create( $ref, $commit_oid,
            expected_old => $expected_old );
        1;
    } catch {
        my $err = $_;
        return 0 if _is_contended_ref_error( $err, defined $expected_old );
        die _ref_write_error( $ref, $err );
    };
    return 0 unless $wrote;
    $WRITES++;
    return 1;
}

# Two answers from one read: the OID the ref points at (undef when the ref is
# absent) and the content of that exact commit. Compare-and-swap callers need
# both together -- deciding on content fetched independently of the OID would
# guard the write against the wrong revision.
sub read_ref_with_oid {
    my ( $self, $ref ) = @_;
    my $repo = $self->_repo or return ( undef, '' );

    # Ask whether the ref is there before looking it up. Letting Git::Native
    # throw for a miss would build a full Throwable stack trace, and this runs
    # once per task load.
    return ( undef, '' ) unless $repo->reference_exists($ref);
    my $oid = try { $repo->reference($ref)->target } catch { undef };
    return ( undef, '' ) unless $oid;

    my $content = try {
        my $commit = $repo->commit($oid);
        my $tree   = $commit->tree;
        my $entry  = $tree->entry_by_name('data');
        return '' unless $entry;
        return $repo->blob( $entry->{oid} )->content;
    } catch { '' };
    $content = from_octets($content);
    # Match historical CLI behaviour: cat-file's trailing newline was chomped.
    chomp $content if defined $content;
    return ( $oid->hex, $content );
}

sub read_ref {
    my ( $self, $ref ) = @_;
    return ( $self->read_ref_with_oid($ref) )[1];
}

sub ref_exists {
    my ( $self, $ref ) = @_;
    my $repo = $self->_repo or return 0;
    return $repo->reference_exists($ref) ? 1 : 0;
}

sub delete_ref {
    my ( $self, $ref ) = @_;
    my $repo = $self->_repo or return 0;
    try { $repo->reference_delete($ref) };
    $WRITES++;
    return 1;
}

# ----- Remote / network ops: native via Git::Native::Remote -----

# The push refspec. Forced, because write_ref builds every board commit with
# `parents => []`: no board ref update is ever a fast-forward, so a non-forced
# refspec can never apply one. push has always been forced; pull was not, and
# libgit2 declines a non-ff fetch update without raising an error, so pull
# returned success while leaving the ref stale -- and the next push then
# force-wrote that stale ref over the other agent's work (#40). Both
# directions are forced now; see _fetch_refspec for the pull side.
#
# The semantics this settles on are last-writer-wins, which is what the
# parentless-commit design already implied everywhere else. Doing better
# would need compare-and-swap on the ref (git_reference_create_matching,
# unbound in Git::Libgit2 -- see ticket #81) plus per-ref rejection reporting
# from libgit2's update_tips/push_update_reference callbacks (not installed
# by Git::Native -- ticket #80). Neither is reachable from karr today.
use constant BOARD_REFSPEC => '+refs/karr/*:refs/karr/*';

use constant BOARD_ROOT => 'refs/karr/';

# Remote-tracking mirror: refs/karr-remote/<remote>/<X> holds the remote's
# refs/karr/<X> as of the last successful fetch or push from this clone.
#
# It exists because "the remote does not have this ref" is two different
# situations and the ref alone cannot tell them apart: the remote deleted a
# task (prune is right -- #49), or the ref is local work that has not been
# pushed yet (prune destroys it). karr promises exactly the latter after a
# failed push -- "Local refs are intact. Run 'karr sync' to retry." -- so
# pruning on that signal alone broke the promise the sync guard and the END
# flush (#37) exist to keep.
#
# The mirror makes the four cases decidable. See _reconcile_with_mirror.
use constant MIRROR_ROOT => 'refs/karr-remote';

# Where the local side of a genuine conflict is parked before the remote
# version replaces it. Outside refs/karr/, so it never reaches the remote and
# never shows up on the board.
use constant CONFLICT_ROOT => 'refs/karr-conflict';

sub _mirror_prefix {
    my ( $self, $remote ) = @_;
    return MIRROR_ROOT . "/$remote/";
}

# Fetch never writes into the live board any more: the remote state lands in
# the mirror, and karr decides per ref what that means. Forced and pruning is
# safe here for the same reason -- the mirror is supposed to be an exact copy
# of the remote, nothing of ours lives in it.
sub _fetch_refspec {
    my ( $self, $remote ) = @_;
    return '+refs/karr/*:' . $self->_mirror_prefix($remote) . '*';
}

sub has_remote {
    my ( $self, $remote ) = @_;
    $remote //= 'origin';
    my $repo = $self->_repo or return 0;
    return $repo->has_remote($remote);
}

# Default credentials callback: SSH-agent → ~/.ssh/id_ed25519 → ~/.ssh/id_rsa
# → default → fail. Matches CLI `git`'s implicit auth chain.
sub _default_credentials_cb {
    my @tried;
    return sub {
        my (%args) = @_;
        my $user  = $args{username_from_url} || 'git';
        my $types = $args{allowed_types}    || 0;

        # GIT_CREDENTIAL_SSH_KEY = 1<<1 = 2
        if ( $types & 2 ) {
            return Git::Native::Credential->ssh_agent( username => $user )
                unless $tried[0]++;
            for my $k (qw( id_ed25519 id_rsa )) {
                my $priv = "$ENV{HOME}/.ssh/$k";
                next unless -r $priv;
                next if $tried[1]{$k}++;
                return Git::Native::Credential->ssh_key(
                    username    => $user,
                    private_key => $priv,
                    public_key  => "$priv.pub",
                    passphrase  => '',
                );
            }
        }
        # GIT_CREDENTIAL_DEFAULT = 1<<3 = 8
        if ( ( $types & 8 ) && !$tried[2]++ ) {
            return Git::Native::Credential->default;
        }
        return undef;   # PASSTHROUGH — give up
    };
}

sub fetch {
    my ( $self, $remote ) = @_;
    $remote //= 'origin';
    my $repo = $self->_repo or return 0;
    return 1 unless $repo->has_remote($remote);
    return try {
        my $r = $repo->remote($remote);
        $r->fetch(
            refspecs    => [],   # use configured refspecs
            credentials => _default_credentials_cb(),
        );
        1;
    } catch {
        $self->{_last_error} = "$_";
        $self->_cli_transport( 'fetch', $remote, [] );
    };
}

sub push {
    my ( $self, $remote, $refspec ) = @_;
    $remote //= 'origin';
    my $repo = $self->_repo or return 0;
    return 1 unless $repo->has_remote($remote);
    $refspec //= BOARD_REFSPEC;
    my $ok = try {
        my $r = $repo->remote($remote);
        $r->push(
            refspecs    => [$refspec],
            credentials => _default_credentials_cb(),
            prune       => 1,
        );
        1;
    } catch {
        $self->{_last_error} = "$_";
        $self->_cli_transport( 'push', $remote, [$refspec], prune => 1 );
    };

    # A push that went through made the remote identical to the local board
    # (forced refspec, prune), so the mirror has to follow. Without this every
    # ref this clone ever pushed would still look "changed locally" on the next
    # pull, and the other agent's perfectly ordinary update would be reported
    # as a conflict.
    $self->_mirror_local_state($remote) if $ok && $refspec eq BOARD_REFSPEC;
    return $ok;
}

sub pull {
    my ( $self, $remote ) = @_;
    $remote //= 'origin';
    my $repo = $self->_repo or return 0;
    return 1 unless $repo->has_remote($remote);

    my $refspec = $self->_fetch_refspec($remote);

    # The mirror as it stands now is the remote state at the last sync; the
    # fetch is about to overwrite it with the current one. Both are needed to
    # tell the four cases apart, so snapshot it first.
    my $tracked = $self->ref_oids( $self->_mirror_prefix($remote) ) || {};

    my $ok = try {
        my $r = $repo->remote($remote);
        $r->fetch(
            refspecs    => [$refspec],
            credentials => _default_credentials_cb(),
            prune       => 1,
        );
        1;
    } catch {
        $self->{_last_error} = "$_";
        $self->_cli_transport( 'fetch', $remote, [$refspec], prune => 1 );
    };
    return 0 unless $ok;

    $self->_reconcile_with_mirror( $remote, $tracked );
    return 1;
}

# Bring the local board in line with the remote, one ref at a time, using
# L = local, T = the mirror before this fetch (the remote at the last sync)
# and R = the mirror after it (the remote now).
#
#   L == T, R exists       the local ref carries nothing the remote has not
#                          seen -> take R. This is the #40 fix: without it the
#                          stale local ref survived the pull and the next push
#                          force-wrote it over the other agent's work.
#   L == T, R gone         the remote deleted it -> delete it here too (#49).
#   L != T, R == T         only this clone moved: work that was written but
#                          never pushed -> keep it exactly as it is. Covers a
#                          local deletion too, which must stay deleted rather
#                          than being restored from a remote that has not been
#                          told about it yet.
#   L != T, R != T         both sides moved. Last-writer-wins still applies
#                          and R takes the slot -- including when R is a
#                          deletion -- but the local version is parked and the
#                          user is told, instead of it disappearing without a
#                          word.
#
# A clone that predates the mirror has T empty everywhere, so every ref reads
# as "changed locally". That degrades to the right outcome: refs that already
# match the remote are left alone (the normal case for a clone that pushes at
# the end of every command), a remote-only update is still adopted -- with one
# spurious conflict report -- and nothing local is dropped. From the next pull
# on the mirror is populated and the answers are exact.
sub _reconcile_with_mirror {
    my ( $self, $remote, $tracked ) = @_;
    return unless $self->_repo;

    my $prefix     = $self->_mirror_prefix($remote);
    my $remote_now = $self->ref_oids($prefix)    || {};
    my $local      = $self->ref_oids(BOARD_ROOT) || {};

    my %names = map { $_ => 1 } keys %$local;
    for my $mirror ( keys %$remote_now, keys %$tracked ) {
        $names{ BOARD_ROOT . substr( $mirror, length $prefix ) } = 1;
    }

    my @conflicts;
    for my $ref ( sort keys %names ) {
        my $mirror = $prefix . substr( $ref, length BOARD_ROOT );
        my ( $l, $r, $t ) =
            ( $local->{$ref}, $remote_now->{$mirror}, $tracked->{$mirror} );

        next if _same_oid( $l, $r );        # already converged

        if ( _same_oid( $l, $t ) ) {
            $self->_adopt_remote_ref( $ref, $r );
            next;
        }

        next if _same_oid( $r, $t );        # unpushed local work: keep it

        $self->_park_conflicting_local( $remote, $ref, $l ) if defined $l;
        $self->_adopt_remote_ref( $ref, $r );
        CORE::push @conflicts, $ref;
    }

    $self->_warn_conflicts( $remote, \@conflicts ) if @conflicts;
    return;
}

# Put the remote's answer for one ref in place. An undefined OID is the
# remote's answer too: it means the ref is gone there.
sub _adopt_remote_ref {
    my ( $self, $ref, $oid ) = @_;
    return defined $oid
        ? $self->_write_ref_untracked( $ref, $oid )
        : $self->_delete_ref_untracked($ref);
}

sub _same_oid {
    my ( $left, $right ) = @_;
    return 1 if !defined $left && !defined $right;
    return 0 if !defined $left || !defined $right;
    return $left eq $right ? 1 : 0;
}

# Ref writes that are not board work: reconciling with the remote, and keeping
# the mirror up to date. They deliberately bypass write_ref/delete_ref so that
# $WRITES stays a count of real board edits -- SyncGuard reads it to decide
# whether anything still needs pushing, and counting a pull's own bookkeeping
# there would make read-only commands claim they had unpushed work (#34).
sub _write_ref_untracked {
    my ( $self, $ref, $oid ) = @_;
    my $repo = $self->_repo or return 0;
    return try { $repo->reference_create( $ref, $oid, force => 1 ); 1 }
           catch { 0 };
}

sub _delete_ref_untracked {
    my ( $self, $ref ) = @_;
    my $repo = $self->_repo or return 0;
    return try { $repo->reference_delete($ref); 1 } catch { 0 };
}

# The losing side of a conflict, kept reachable. Without this the displaced
# local commit is unreferenced the moment the ref moves and the next gc takes
# it, so "your edit was overwritten" would be a report with nothing behind it.
# One slot per ref: bounded by board size, and a second conflict on the same
# ref has already been reported once.
sub _park_conflicting_local {
    my ( $self, $remote, $ref, $oid ) = @_;
    my $parked =
        CONFLICT_ROOT . "/$remote/" . substr( $ref, length BOARD_ROOT );
    $self->_write_ref_untracked( $parked, $oid );
    return $parked;
}

sub _warn_conflicts {
    my ( $self, $remote, $refs ) = @_;
    my $names = join ', ', map { substr $_, length BOARD_ROOT } @$refs;
    warn "karr: this clone and the remote both changed $names since the last "
       . "sync.\n"
       . "The remote version is now in place. The local one is kept at "
       . CONFLICT_ROOT . "/$remote/<name> and is never pushed.\n";
    return;
}

# Make the mirror match the local board. Called after a successful push, where
# the remote has just been made identical to it.
sub _mirror_local_state {
    my ( $self, $remote ) = @_;
    return unless $self->_repo;

    my $prefix = $self->_mirror_prefix($remote);
    my $local  = $self->ref_oids(BOARD_ROOT) || {};
    my $mirror = $self->ref_oids($prefix)    || {};

    for my $ref ( keys %$local ) {
        my $name = $prefix . substr( $ref, length BOARD_ROOT );
        next if _same_oid( $mirror->{$name}, $local->{$ref} );
        $self->_write_ref_untracked( $name, $local->{$ref} );
    }
    for my $name ( keys %$mirror ) {
        my $ref = BOARD_ROOT . substr( $name, length $prefix );
        $self->_delete_ref_untracked($name) unless exists $local->{$ref};
    }
    return;
}

sub push_ref {
    my ( $self, $ref, $remote ) = @_;
    $remote //= 'origin';
    $ref = $self->validate_helper_ref($ref);
    my $repo = $self->_repo or return 0;
    return 1 unless $repo->has_remote($remote);
    return try {
        my $r = $repo->remote($remote);
        $r->push(
            refspecs    => ["+$ref:$ref"],
            credentials => _default_credentials_cb(),
        );
        1;
    } catch {
        $self->{_last_error} = "$_";
        $self->_cli_transport( 'push', $remote, ["+$ref:$ref"] );
    };
}

sub pull_ref {
    my ( $self, $ref, $remote ) = @_;
    $remote //= 'origin';
    $ref = $self->validate_helper_ref($ref);
    my $repo = $self->_repo or return 0;
    return 1 unless $repo->has_remote($remote);
    # Forced for the same reason as the board refspec (#40): helper refs are
    # written by write_ref too, so a helper ref that changed on the remote is
    # never a fast-forward and a non-forced fetch would leave `karr get-refs`
    # quietly serving the stale local copy.
    return try {
        my $r = $repo->remote($remote);
        $r->fetch(
            refspecs    => ["+$ref:$ref"],
            credentials => _default_credentials_cb(),
        );
        1;
    } catch {
        $self->{_last_error} = "$_";
        $self->_cli_transport( 'fetch', $remote, ["+$ref:$ref"] );
    };
}

# Fallback transport via the system `git` CLI so that ssh-config directives
# libgit2 ignores (ProxyCommand, Host aliases, IdentityFile, insteadOf) are
# honoured. Returns 1 on success, 0 on failure (setting _last_error to the real
# git-CLI stderr). $verb is 'push' or 'fetch'. @$refspecs may be empty
# (fetch => configured refspecs). %opt: prune => bool. Disabled by
# KARR_NO_CLI_FALLBACK=1.
sub _cli_transport {
    my ( $self, $verb, $remote, $refspecs, %opt ) = @_;
    return 0 if $ENV{KARR_NO_CLI_FALLBACK};

    my @args = ($verb);
    CORE::push @args, '--prune' if $opt{prune};
    CORE::push @args, $remote, @$refspecs;

    my $native = $self->{_last_error};
    my $run    = $self->_run_git(@args);

    if ( $run->{failure} eq 'start' ) {
        $self->{_last_error} =
            "git CLI fallback unavailable: $run->{err}"
          . ( defined $native ? " (native: $native)" : '' );
        return 0;
    }

    my $detail = $run->{err};
    $detail =~ s/\s+\z//;
    my $suffix = length $detail ? ": $detail" : '';

    if ( $run->{failure} eq 'timeout' ) {
        $self->{_last_error} = "git $verb (CLI fallback) timed out after "
          . "$run->{timeout}s and was killed$suffix";
        return 0;
    }

    # `$? >> 8` is 0 both for "exited cleanly" and for "died from a signal",
    # so a git the OOM killer, a Ctrl-C on the process group or a SIGPIPE took
    # down used to be reported as a successful transport -- the task was
    # announced as created and the remote never saw it (#42). The signal bits
    # have to be read first.
    if ( my $sig = $run->{status} & 127 ) {
        $self->{_last_error} =
          "git $verb (CLI fallback) was killed by signal $sig$suffix";
        return 0;
    }
    return 1 unless $run->{status} >> 8;

    $self->{_last_error} = "git $verb (CLI fallback) failed: $detail";
    return 0;
}

# Wall-clock budget for one `git` CLI run, in seconds. 0 (or a non-numeric
# value) disables it. karr is driven by unattended agents, so the default is a
# ceiling rather than a guess at how slow a legitimate transfer may be.
use constant DEFAULT_TRANSPORT_TIMEOUT => 120;

# Cap on how much of each stream is kept. Draining continues past it -- the
# point is only to stop a runaway git from being buffered into memory whole.
use constant CLI_OUTPUT_LIMIT => 65_536;

sub _transport_timeout {
    my $raw = $ENV{KARR_TRANSPORT_TIMEOUT};
    return DEFAULT_TRANSPORT_TIMEOUT
        unless defined $raw && $raw =~ /\A\d+(?:\.\d+)?\z/;
    return $raw + 0;
}

# Run `git -C <dir> @args` and return
#   { ok => 0|1, failure => ''|'start'|'timeout', status => $?, out, err,
#     timeout => $seconds }
#
# Both pipes are drained through one IO::Select loop. Reading stdout to EOF
# first, as this used to, deadlocks the moment the child fills the 64 KiB
# stderr pipe buffer: the child blocks on write and so never exits or closes
# stdout, while the parent is still blocked reading stdout. A diverged board
# reaches that at roughly 700 rejected refs, and it could strike inside
# bin/karr's END flush, i.e. after the command had already printed its result
# (#43). The loop is also bounded by a deadline, so a transport that stalls
# (an ssh ProxyCommand hanging on a jump host, a grandchild holding the pipes
# open past the child's exit) fails instead of hanging an unattended agent.
#
# `status` is the raw waitpid status, not `$? >> 8`, so callers can tell a
# clean exit from a death by signal (#42).
sub _run_git {
    my ( $self, @args ) = @_;

    my @cmd     = ( 'git', '-C', $self->dir->stringify, @args );
    my $timeout = _transport_timeout();
    my %result  = (
        ok => 0, failure => 'start', status => 0,
        out => '', err => '', timeout => $timeout,
    );

    my ( $pid, $timed_out );
    my $started = try {
        local $ENV{GIT_TERMINAL_PROMPT} = 0;   # never hang on an interactive prompt
        my $err_fh = gensym;
        $pid = open3( my $in, my $out_fh, $err_fh, @cmd );
        close $in;

        my %sink = (
            fileno($out_fh) => \$result{out},
            fileno($err_fh) => \$result{err},
        );
        my $select   = IO::Select->new( $out_fh, $err_fh );
        my $deadline = $timeout ? Time::HiRes::time() + $timeout : undef;

        while ( $select->count ) {
            my $left = defined $deadline
                     ? $deadline - Time::HiRes::time() : undef;
            if ( defined $left && $left <= 0 ) { $timed_out = 1; last }
            # Poll in slices so the deadline is still honoured while git is
            # quiet on both streams.
            my $slice = !defined $left || $left > 1 ? 1 : $left;
            for my $fh ( $select->can_read($slice) ) {
                my $read = sysread $fh, my $chunk, 65_536;
                if ( !defined $read ) {
                    next if $! == EINTR;
                    $select->remove($fh);
                    next;
                }
                if ( !$read ) { $select->remove($fh); next }
                my $buffer = $sink{ fileno($fh) };
                $$buffer .= $chunk if length($$buffer) < CLI_OUTPUT_LIMIT;
            }
        }
        1;
    } catch {
        $result{err} = "$_";
        0;
    };
    return \%result unless $started;

    if ($timed_out) {
        $self->_reap_killed($pid);
        $result{failure} = 'timeout';
        return \%result;
    }

    waitpid $pid, 0;
    @result{qw( ok failure status )} = ( 1, '', $? );
    return \%result;
}

# Take down a child that blew the transport timeout: TERM first, KILL if it is
# still around, and reap it either way so it cannot linger as a zombie in a
# long-running embedder.
sub _reap_killed {
    my ( $self, $pid ) = @_;
    return unless $pid;
    kill 'TERM', $pid;
    for ( 1 .. 20 ) {                       # up to ~2s for a clean exit
        return if waitpid( $pid, WNOHANG ) > 0;
        Time::HiRes::sleep(0.1);
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
    return;
}

# ----- Board encoding contract (ticket #53) -----

# karr up to 0.402 handed YAML::XS::Dump output (octets) around as if it were
# characters, so every board written before this ref existed carries UTF-8
# encoded twice in its task frontmatter, its config, and its activity log. The
# ref is the discriminator: absent means "legacy, repair on read", 2 means
# "written under the current contract, hands off". Boards are stamped by
# `karr init`, `karr repair --yes`, and `karr import --yes`.
#
# Cached per object: it is consulted once per task load, and a board does not
# change contract version mid-command.
sub board_encoding_version {
    my ($self) = @_;
    return $self->{_encoding_version} //= do {
        my $raw = $self->read_ref('refs/karr/meta/encoding') // '';
        $raw =~ s/\s+//g;
        $raw =~ /\A(\d+)\z/ ? int($1) : 1;
    };
}

sub write_encoding_version {
    my ( $self, $version ) = @_;
    $version //= BOARD_ENCODING_VERSION;
    delete $self->{_encoding_version};
    return $self->write_ref( 'refs/karr/meta/encoding', "$version\n" );
}

sub board_is_legacy_encoded {
    my ($self) = @_;
    return $self->board_encoding_version < BOARD_ENCODING_VERSION ? 1 : 0;
}

# Repair board payloads read off a pre-contract board, and only those.
sub maybe_repair_legacy {
    my ( $self, $data ) = @_;
    return $data unless $self->board_is_legacy_encoded;
    return repair_mojibake($data);
}

# ----- Task / config refs (sit on top of write_ref/read_ref) -----

sub save_task_ref {
  my ($self, $task) = @_;
  my $ref = "refs/karr/tasks/" . $task->id . "/data";
  $self->write_ref($ref, $task->to_markdown);
}

sub load_task_ref {
  my ($self, $id) = @_;
  my $ref = "refs/karr/tasks/$id/data";
  my $content = $self->read_ref($ref);
  return undef unless $content;
  return App::karr::Task->from_string(
    $content,
    repair_frontmatter => $self->board_is_legacy_encoded,
  );
}

sub list_task_refs {
  my ($self) = @_;
  my %ids;
  for my $ref ( $self->list_refs('refs/karr/tasks/') ) {
    $ids{$1} = 1 if $ref =~ m{refs/karr/tasks/(\d+)/};
  }
  return sort { $a <=> $b } keys %ids;
}

sub list_refs {
    my ( $self, $prefix ) = @_;
    $prefix //= 'refs/karr/';
    my $repo = $self->_repo or return ();
    # Glob to scope the iterator server-side.
    my $names = $repo->reference_names( glob => "$prefix*" );
    return @$names;
}

sub ref_oids {
    my ( $self, $prefix ) = @_;
    $prefix //= 'refs/karr/';
    my $repo = $self->_repo or return undef;
    my %oids;
    for my $ref ( $self->list_refs($prefix) ) {
        my $oid = try {
            my $t = $repo->reference($ref)->target;
            $t ? $t->hex : undef;
        } catch { undef };
        $oids{$ref} = $oid if defined $oid;
    }
    return \%oids;
}

sub read_config_ref {
    my ($self) = @_;
    my $content = $self->read_ref('refs/karr/config');
    return {} unless $content;
    return $self->maybe_repair_legacy( yaml_load($content) );
}

sub write_config_ref {
    my ( $self, $data ) = @_;
    return $self->write_ref( 'refs/karr/config', yaml_dump($data) );
}

use constant NEXT_ID_REF => 'refs/karr/meta/next-id';

sub _parse_next_id {
    my ($raw) = @_;
    $raw = '' unless defined $raw;
    $raw =~ s/\s+\z//;
    return $raw =~ /^\d+$/ ? int($raw) : 1;
}

sub read_next_id_ref {
    my ($self) = @_;
    return _parse_next_id( $self->read_ref(NEXT_ID_REF) );
}

sub write_next_id_ref {
    my ( $self, $next_id ) = @_;
    return $self->write_ref( NEXT_ID_REF, "$next_id\n" );
}

# Hand out one id and move the counter past it in a single guarded step.
#
# The old read-then-write lost tasks outright: two agents that read the same
# counter both got that id, wrote the same refs/karr/tasks/N/data, and the
# loser's task was destroyed with both processes reporting success -- 40
# parallel creates produced 32 tasks (#44). The counter has to be re-read
# inside the loop, not once outside it: retrying with the value that already
# lost would just lose again.
sub allocate_next_id_ref {
    my ($self) = @_;
    return $self->retry_contended( 'the next-id counter', sub {
        my ( $oid, $raw ) = $self->read_ref_with_oid(NEXT_ID_REF);
        my $id = _parse_next_id($raw);
        return () unless $self->write_ref_cas( NEXT_ID_REF, ($id + 1) . "\n", $oid );
        return $id;
    } );
}

sub delete_refs {
    my ( $self, $prefix ) = @_;
    for my $ref ( $self->list_refs($prefix) ) {
        $self->delete_ref($ref);
    }
    return 1;
}

1;
