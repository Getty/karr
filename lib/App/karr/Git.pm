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
use App::karr::Error qw( clean_error );
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

A reconciliation that would delete I<every> remaining board ref is refused
with an exception instead of being applied, and the mirror is left as it was:
that outcome is what a C<karr destroy> on another clone looks like, and
equally what a re-created origin or a mis-edited remote URL looks like.
C<< pull( $remote, accept_wipe => 1 ) >> -- reached from C<karr sync --prune>
-- is the only way through.

The ref count alone cannot tell a swapped remote from the right one, though:
a re-initialised origin or a mis-edited remote URL can present a whole
I<different>, non-empty board, which reconciliation would happily converge
onto (#95). Boards therefore carry an identity in C<refs/karr/meta/board-id>,
stamped at init and compared on every pull before any reconciliation. A
mismatch is refused the same way as a wholesale wipe, mirror rolled back and
all, and C<< pull( $remote, accept_foreign => 1 ) >> -- C<karr sync
--accept-foreign-board> -- is the deliberate way through.

C<push> fails when the far side rejects refs, even though libgit2 returns
success in that case: the per-ref outcome only exists in the
L<Git::Native::Remote::Result> it hands back, and L</push_rejections> carries
it on to the caller. The CLI fallback pushes with C<--porcelain> and parses
the same outcomes, so both transports fail with the same per-ref reasons.

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

# The identity is read from git config once per process. The timestamp is not,
# and that is the point: libgit2 stamps a signature at the moment the
# git_signature is allocated, so a signature cached for the life of the process
# made every commit it ever wrote carry the time of the first one. In a
# short-lived CLI run that is invisible; in a long-running driver
# (karr-foundation draining boards for hours) every ref it wrote was
# backdated to process start.
#
# App::karr::Lock reads exactly this timestamp back -- via commit_time below --
# to decide whether a lock is stale, so a cached one would have made every lock
# taken by a long-running agent look expired the instant it was written (#45).
sub _signature {
    my ($self) = @_;
    unless ( $self->{_sig_identity} ) {
        $self->_repo or return;
        $self->{_sig_identity} = {
            name  => $self->git_user_name  || 'karr',
            email => $self->git_user_email || 'karr@localhost',
        };
    }
    return Git::Native::Signature->new(
        %{ $self->{_sig_identity} },
        when   => time,
        offset => 0,
    );
}

# Committer time of the commit a ref points at, as a Unix epoch. Takes the OID
# rather than the ref name so the caller can judge the age of the same revision
# it is about to guard a compare-and-swap against: reading the ref a second time
# here would let it move in between, and a lock steal decided on one revision
# but applied to another silently evicts a live holder.
sub commit_time {
    my ( $self, $oid ) = @_;
    return undef unless defined $oid && length $oid;
    my $repo = $self->_repo or return undef;
    return try { $repo->commit($oid)->time } catch { undef };
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
        # Pick locks (App::karr::Lock). They were moved out of refs/karr/ so
        # that no refspec could publish them (#93); `karr set-refs` names a ref
        # and pushes it, so leaving it able to reach them would put the same
        # hole back one command over.
        'refs/karr-local/',
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
# aborted a command mid-body (#46). App::karr::Error::clean_error is the one
# reduction to a single line of prose -- this used to carry its own copy of it
# -- and the trailing newline stops perl appending " at ... line N." on top.
sub _ref_error {
    my ( $verb, $ref, $err ) = @_;
    return "karr: could not $verb $ref: " . clean_error($err) . "\n";
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
    return $self->_write_ref_oid( $ref, $self->_commit_for_content( $repo, $content ) );
}

# The ref-moving half of write_ref, split out for replace_board_refs, which
# has to build every commit in a restore before it moves the first ref.
sub _write_ref_oid {
    my ( $self, $ref, $commit_oid ) = @_;
    my $repo = $self->_repo or return;

    return $self->retry_contended( "ref $ref", sub {
        my $wrote = try {
            $repo->reference_create( $ref, $commit_oid, force => 1 );
            1;
        } catch {
            my $err = $_;
            return 0 if _is_contended_ref_error( $err, 0 );
            die _ref_error( 'write', $ref, $err );
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
        die _ref_error( 'write', $ref, $err );
    };
    return 0 unless $wrote;
    $WRITES++;
    return 1;
}

# Compare-and-swap sibling of delete_ref, and the mirror image of
# write_ref_cas: the ref is removed only if it still holds $expected_old.
#
# libgit2 has two removals and karr only ever reached the unguarded one.
# git_reference_remove(repo, name) -- what delete_ref uses -- takes a name and
# no expected-old OID, so a delete can never be guarded: whatever the caller
# checked may have changed by the time the ref goes. git_reference_delete()
# takes a looked-up reference instead and refuses with GIT_EMODIFIED when the
# ref on disk no longer matches the one that was looked up, which is exactly
# the guarantee the claim guards need (#94).
#
# Both halves are needed. The explicit OID comparison covers the window
# between the caller's read and the lookup here; libgit2's own check covers
# the window between that lookup and the removal. Neither alone is a CAS.
#
# Returns 1 when the delete landed and 0 when the ref had moved or gone -- the
# same contract write_ref_cas answers with, so a caller inside retry_contended
# re-reads what it decided on and tries again. Contention that has not
# committed to an answer yet (another process holding refs/<name>.lock) is
# reported as 0 as well, for the same reason: read again and retry. A real
# failure dies with a karr-level message.
sub delete_ref_cas {
    my ( $self, $ref, $expected_old ) = @_;
    defined $expected_old
        or die "karr: could not delete $ref: no expected revision given\n";
    my $repo = $self->_repo
        or die "karr: could not delete $ref: "
             . ( $self->last_error // 'no usable git repository' ) . "\n";

    # A miss is "somebody got there first", not an error, and asking first
    # keeps libgit2 from building a full Throwable stack trace for it.
    return 0 unless $repo->reference_exists($ref);

    my $reference = try { $repo->reference($ref) } catch { undef };
    return 0 unless $reference;
    my $target = try { $reference->target } catch { undef };
    return 0 unless $target && $target->hex eq $expected_old;

    my $deleted = try {
        $reference->delete;
        1;
    } catch {
        my $err = $_;
        return 0 if _is_contended_ref_error( $err, 1 );
        die _ref_error( 'delete', $ref, $err );
    };
    return 0 unless $deleted;
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

# Returns 1 only when this call actually removed the ref, 0 otherwise -- the
# ref was not there, or libgit2 refused. It used to swallow the exception and
# answer 1 regardless (#51), which made a delete that did nothing look like a
# delete that worked, and bumped $WRITES either way. That counter is what
# SyncGuard reads to decide whether local refs still need pushing, so it may
# only ever count writes that landed.
#
# Contention retries on the same terms as write_ref: losing the race for
# refs/<name>.lock is not a failed delete, it is one that has not been
# attempted yet.
sub delete_ref {
    my ( $self, $ref ) = @_;
    my $repo = $self->_repo or return 0;

    return $self->retry_contended( "ref $ref", sub {
        # Asking first keeps "nothing to delete" -- a no-op, not a write --
        # apart from the failures below, which libgit2 reports the same way.
        return 0 unless $repo->reference_exists($ref);

        my $outcome = try {
            $repo->reference_delete($ref);
            'deleted';
        } catch {
            _is_contended_ref_error( $_, 0 ) ? 'contended' : 'failed';
        };
        return () if $outcome eq 'contended';
        return 0  if $outcome eq 'failed';
        $WRITES++;
        return 1;
    } );
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

# The board's identity (#95): stamped once at board birth, compared on every
# pull before any reconciliation -- see _check_board_identity. Declared with
# the other namespace constants because use constant is only visible from its
# textual point on, and _check_board_identity needs it.
use constant BOARD_ID_REF => 'refs/karr/meta/board-id';

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
        # The Result's ->updated names the refs this fetch actually moved.
        # karr deliberately does not use it: reconciliation has to consider
        # the refs the fetch did *not* move as well (unpushed local work is
        # exactly that), so it reads the ref OIDs itself -- and the CLI
        # transport has no such list to hand back, so consuming it would make
        # the two transports differ again, which is what #41 was. ->rejected
        # is always empty on fetch.
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

# Per-ref rejections from the most recent push, as
# [ { ref => $name, reason => $text }, ... ]. Empty when the last push
# succeeded, and empty when it failed as a whole (no connection, killed
# transport) rather than ref by ref -- a rejection is the server's final
# answer, so App::karr::Role::SyncLifecycle uses this to stop retrying it.
sub push_rejections {
    my ($self) = @_;
    return $self->{_push_rejections} || [];
}

# libgit2 returns 0 from git_remote_push even when the server refused every
# single ref -- a pre-receive hook, a protected ref, a non-ff on a non-forced
# refspec. The per-ref status only exists in the Result Git::Native 0.004
# hands back, and karr threw that away, so a push that landed nothing was
# reported as a completed sync and the board diverged in silence (#84).
#
# A rejection is not a transport failure: the connection worked and the far
# side said no. So this does not fall through to the CLI fallback -- that
# would just collect the same refusal a second time, and hide the reason
# behind a generic exit code.
sub _accept_push_result {
    my ( $self, $remote, $result ) = @_;
    return 1 unless $result;                    # CLI fallback ran instead
    my $rejected = $result->rejected;
    return 1 unless $rejected && @$rejected;
    $self->{_push_rejections} = $rejected;
    $self->{_last_error} =
        _push_rejection_error( $remote, $rejected, scalar @{ $result->updated } );
    return 0;
}

# One line per refused ref, with the reason the far side gave, because "the
# push failed" without naming the ref is not actionable on a board where one
# protected ref among fifty is the normal case.
sub _push_rejection_error {
    my ( $remote, $rejected, $accepted ) = @_;
    my $total = @$rejected + ( $accepted // 0 );
    my $head  = @$rejected == $total
        ? sprintf( "the remote '%s' rejected all %d ref%s",
            $remote, $total, $total == 1 ? '' : 's' )
        : sprintf( "the remote '%s' rejected %d of %d refs",
            $remote, scalar @$rejected, $total );
    return join "\n", "$head:", map {
        '    '
          . $_->{ref} . ': '
          . ( defined $_->{reason} && length $_->{reason}
                ? $_->{reason} : 'no reason given' )
    } @$rejected;
}

sub push {
    my ( $self, $remote, $refspec ) = @_;
    $remote //= 'origin';
    my $repo = $self->_repo or return 0;
    return 1 unless $repo->has_remote($remote);
    $refspec //= BOARD_REFSPEC;
    $self->{_push_rejections} = [];

    my $result;
    my $ok = try {
        my $r = $repo->remote($remote);
        $result = $r->push(
            refspecs    => [$refspec],
            credentials => _default_credentials_cb(),
            prune       => 1,
        );
        1;
    } catch {
        $self->{_last_error} = "$_";
        $self->_cli_transport( 'push', $remote, [$refspec], prune => 1 );
    };
    return 0 unless $ok;
    return 0 unless $self->_accept_push_result( $remote, $result );

    # A push that went through made the remote identical to the local board
    # (forced refspec, prune), so the mirror has to follow. Without this every
    # ref this clone ever pushed would still look "changed locally" on the next
    # pull, and the other agent's perfectly ordinary update would be reported
    # as a conflict.
    $self->_mirror_local_state($remote) if $refspec eq BOARD_REFSPEC;
    return 1;
}

# %opt: accept_wipe => bool, the caller's answer to _refuse_wholesale_wipe;
# accept_foreign => bool, its answer to _check_board_identity. Only
# `karr sync --prune` sets the first and `karr sync --accept-foreign-board`
# the second; every other pull refuses to reconcile the whole board out of
# existence, or onto a different board (#82, #95).
sub pull {
    my ( $self, $remote, %opt ) = @_;
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

    $self->_check_board_identity( $remote, $tracked, $opt{accept_foreign} );
    $self->_reconcile_with_mirror( $remote, $tracked, $opt{accept_wipe} );
    return 1;
}

# The identity half of the pull guards (#95), run after the fetch and before
# any reconciliation. The wipe guard cannot see this case at all: a remote
# swapped for a DIFFERENT non-empty board -- a stale clone, a re-initialised
# origin, a typo in the remote URL -- has plenty of refs, just not this
# board's, and reconciliation used to converge the local board onto it in one
# step, silently and totally. The four shapes a pull can meet:
#
#   both sides stamped, ids differ   the remote was swapped -> refuse, mirror
#                                    rolled back, unless the caller opted in
#                                    with accept_foreign
#   remote stamped, local not        a clone's first pull -> reconciliation
#                                    adopts the id ref along with the board
#   local stamped, remote not        a pre-change remote (or one an old karr
#                                    pruned the stamp off with its forced,
#                                    pruning push) -> keep the local id; the
#                                    next push re-arms the remote
#   neither stamped                  a pre-change board -> stamp it now, and
#                                    the ordinary push path arms the remote
#
# An absent id is never a refusal by itself: an empty remote remains the wipe
# guard's case, and a non-empty one a board from before identities existed.
sub _check_board_identity {
    my ( $self, $remote, $tracked, $accept_foreign ) = @_;
    my $prefix    = $self->_mirror_prefix($remote);
    my $remote_id = $self->_read_id_ref( $prefix . 'meta/board-id' );
    my $local_id  = $self->read_board_id_ref;

    if ( defined $remote_id && defined $local_id && $remote_id ne $local_id ) {
        return if $accept_foreign;
        # Same rule as the wipe guard: put the mirror back first, or the
        # refusal is a one-shot -- the next pull would read the foreign board
        # as already-reconciled state and walk straight through.
        $self->_restore_mirror( $remote, $tracked );
        die "karr: refusing to sync: the remote '$remote' is a different board.\n"
          . "This clone has been syncing with board $local_id, but the remote "
          . "now presents board $remote_id.\n"
          . "That is what a re-initialised origin, an edited remote URL, or a "
          . "stale clone pointed at the wrong repository looks like.\n"
          . "Check the remote first (git remote -v). Then either republish this "
          . "board over it with 'karr sync --push', or -- if the remote's board "
          . "really is the one you want now -- adopt it with 'karr sync "
          . "--accept-foreign-board'.\n";
    }

    if ( defined $local_id && !defined $remote_id ) {
        # A pre-change karr's forced, pruning push drops the stamp off the
        # remote while the rest of the board stays. That remote is still this
        # board, so keep the identity continuous: point the mirror's stamp
        # slot back at the local stamp, or reconciliation would read the
        # missing ref as "the remote deleted the id" and strip it here too.
        # Only while the remote still IS a board -- an empty one is the wipe
        # guard's case, and the stamp must not count as a survivor there.
        my $remote_now = $self->ref_oids($prefix) || {};
        if ( %$remote_now ) {
            my ( $oid ) = $self->read_ref_with_oid(BOARD_ID_REF);
            $self->_write_ref_untracked( $prefix . 'meta/board-id', $oid )
                if defined $oid;
        }
        return;
    }

    if ( !defined $remote_id && !defined $local_id ) {
        # Only when there is a board to name at all: an empty clone pulling
        # an empty remote gets no stray meta ref.
        my $remote_now = $self->ref_oids($prefix)    || {};
        my $local      = $self->ref_oids(BOARD_ROOT) || {};
        $self->ensure_board_id_ref if %$remote_now || %$local;
    }
    return;
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
# The decision is taken for every ref before any of it is applied, because the
# guard against a wholesale wipe (#82) is a property of the plan as a whole,
# not of a single ref, and it has to fire before the first deletion lands.
sub _reconcile_with_mirror {
    my ( $self, $remote, $tracked, $accept_wipe ) = @_;
    return unless $self->_repo;

    my $prefix     = $self->_mirror_prefix($remote);
    my $remote_now = $self->ref_oids($prefix)    || {};
    my $local      = $self->ref_oids(BOARD_ROOT) || {};

    my %names = map { $_ => 1 } keys %$local;
    for my $mirror ( keys %$remote_now, keys %$tracked ) {
        $names{ BOARD_ROOT . substr( $mirror, length $prefix ) } = 1;
    }

    # [ ref, remote oid (undef = delete), local oid to park, is a conflict ]
    my @plan;
    my ( $survivors, $deletes ) = ( 0, 0 );
    for my $ref ( sort keys %names ) {
        my $mirror = $prefix . substr( $ref, length BOARD_ROOT );
        my ( $l, $r, $t ) =
            ( $local->{$ref}, $remote_now->{$mirror}, $tracked->{$mirror} );

        if ( _same_oid( $l, $r ) ) {        # already converged
            $survivors++ if defined $l;
            next;
        }

        if ( _same_oid( $l, $t ) ) {
            CORE::push @plan, [ $ref, $r, undef, 0 ];
            # What the wipe guard counts, and why only here: this branch is
            # the deletion the clone cannot see coming and cannot undo -- it
            # holds nothing of its own for this ref, so nothing is parked and
            # nothing is warned about. Those are the ones that add up to a
            # board disappearing without a word (#82). The case-4 branch below
            # also deletes, but it parks the local version and says so, so it
            # is not a silent loss and does not count. A ref the remote never
            # had (both undef) is not a loss either.
            if    ( defined $r ) { $survivors++ }
            elsif ( defined $l ) { $deletes++ }
        }
        elsif ( _same_oid( $r, $t ) ) {     # unpushed local work: keep it
            $survivors++ if defined $l;
        }
        else {
            CORE::push @plan, [ $ref, $r, $l, 1 ];
            $survivors++ if defined $r;
        }
    }

    $self->_refuse_wholesale_wipe( $remote, $tracked, $deletes )
        if $deletes && !$survivors && !$accept_wipe;

    my @conflicts;
    for my $step (@plan) {
        my ( $ref, $oid, $displaced, $conflict ) = @$step;
        # Nothing to park when the local side of a conflict is a deletion:
        # there is no commit left to keep reachable, but the clone that made
        # that deletion is still told the remote undid it.
        $self->_park_conflicting_local( $remote, $ref, $displaced )
            if defined $displaced;
        $self->_adopt_remote_ref( $ref, $oid );
        CORE::push @conflicts, $ref if $conflict;
    }

    $self->_warn_conflicts( $remote, \@conflicts ) if @conflicts;
    return;
}

# Refuse to reconcile a board out of existence.
#
# "The remote had these refs at the last sync and does not have them now" is a
# well-founded observation once the mirror is in place, and acting on it is
# what makes a `karr delete` propagate and a `karr destroy` take effect across
# clones. It is also indistinguishable from a remote that is empty for the
# wrong reason -- origin re-created or re-initialised, the remote URL edited to
# point somewhere else, a hosting-side restore that rolled the namespace back
# -- and in those, a routine writing command reconciles the whole board down to
# nothing, in one step and without a word (#82).
#
# Nothing in the refs can tell those apart, so the wholesale case, and only
# that one, asks a human. A pull that would leave at least one board ref
# standing is ordinary reconciliation and still runs unattended.
#
# The mirror is rolled back to what it was before the fetch first. Leaving it
# emptied would make the very next pull read every local ref as unpushed work
# (L != T, R == T), keep the board, and then push it back at whatever the
# remote has become -- turning one refusal into a silent resurrection, and
# making the refusal a one-shot that never fires again.
sub _refuse_wholesale_wipe {
    my ( $self, $remote, $tracked, $deletes ) = @_;
    $self->_restore_mirror( $remote, $tracked );
    die "karr: refusing to sync: this would delete the whole board.\n"
      . "The remote '$remote' no longer has any of the $deletes board ref"
      . ( $deletes == 1 ? '' : 's' ) . " it had at the last sync.\n"
      . "That is what 'karr destroy' on another clone looks like -- and also "
      . "what a re-created origin, an edited remote URL, or a rolled-back "
      . "hosting-side restore look like.\n"
      . "Check the remote first (git remote -v). Then either republish this "
      . "board with 'karr sync --push', or accept the deletion with "
      . "'karr sync --prune'.\n";
}

# Put the mirror back the way the caller found it. Safe to do with bare OIDs:
# the refs/karr/* refs still point at those commits (that is what makes this a
# wholesale wipe), so nothing has become unreachable in between.
sub _restore_mirror {
    my ( $self, $remote, $tracked ) = @_;
    my $prefix = $self->_mirror_prefix($remote);
    my $now    = $self->ref_oids($prefix) || {};

    for my $name ( keys %$tracked ) {
        next if _same_oid( $now->{$name}, $tracked->{$name} );
        $self->_write_ref_untracked( $name, $tracked->{$name} );
    }
    for my $name ( keys %$now ) {
        $self->_delete_ref_untracked($name) unless exists $tracked->{$name};
    }
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
    $self->{_push_rejections} = [];

    my $result;
    my $ok = try {
        my $r = $repo->remote($remote);
        $result = $r->push(
            refspecs    => ["+$ref:$ref"],
            credentials => _default_credentials_cb(),
        );
        1;
    } catch {
        $self->{_last_error} = "$_";
        $self->_cli_transport( 'push', $remote, ["+$ref:$ref"] );
    };
    return 0 unless $ok;
    return $self->_accept_push_result( $remote, $result );
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
#
# `push` runs with --porcelain so the per-ref outcomes come back parseable.
# The CLI already exits non-zero on a rejection, so the failure was never
# invisible here the way it was natively (#84) -- but the error contract has
# to be the same on both transports, or "which ref did the server refuse, and
# why" would depend on which one happened to run.
sub _cli_transport {
    my ( $self, $verb, $remote, $refspecs, %opt ) = @_;
    return 0 if $ENV{KARR_NO_CLI_FALLBACK};

    my @args = ($verb);
    CORE::push @args, '--porcelain' if $verb eq 'push';
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

    if ( $verb eq 'push' ) {
        my $rejected = _parse_push_porcelain( $run->{out} );
        if (@$rejected) {
            $self->{_push_rejections} = $rejected;
            $self->{_last_error} =
                _push_rejection_error( $remote, $rejected,
                    _count_push_porcelain_accepted( $run->{out} ) );
            return 0;
        }
    }

    $self->{_last_error} = "git $verb (CLI fallback) failed: $detail";
    return 0;
}

# `git push --porcelain` writes one machine-readable line per ref to stdout:
#
#   <flag>TAB<src>:<dst>TAB<summary>
#
# '!' is the flag for a ref the far side refused, and the summary carries the
# reason in parentheses -- "[remote rejected] (pre-receive hook declined)".
# That is the CLI's equivalent of the push_update_reference status libgit2
# reports, so parsing it is what makes both transports name the same refs with
# the same reasons (#84).
sub _parse_push_porcelain {
    my ($out) = @_;
    my @rejected;
    for my $line ( split /\n/, $out // '' ) {
        next unless $line =~ /\A!\t([^\t]*)\t(.*)\z/;
        my ( $refspec, $summary ) = ( $1, $2 );
        # "<src>:<dst>", and <src> is empty for a delete. The board ref is the
        # destination either way.
        my $ref = $refspec =~ /:([^:]*)\z/ ? $1 : $refspec;
        my $reason = $summary =~ /\(([^)]*)\)\s*\z/ ? $1 : $summary;
        CORE::push @rejected, { ref => $ref, reason => $reason };
    }
    return \@rejected;
}

# Everything that is not a rejection line and not git's own "To <url>" /
# "Done" framing was a ref the server took, which is what turns the message
# into "rejected 2 of 5" instead of a bare list.
sub _count_push_porcelain_accepted {
    my ($out) = @_;
    my $accepted = 0;
    for my $line ( split /\n/, $out // '' ) {
        next unless $line =~ /\A([ +\-*=!])\t[^\t]*\t/;
        $accepted++ unless $1 eq '!';
    }
    return $accepted;
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

# ----- Board identity (ticket #95) -----

# The wipe guard can only see ref counts, so a remote swapped for a different
# non-empty board sailed straight through it. The board-id ref is the
# discriminator the refs otherwise lacked: stamped once at board birth,
# compared on every pull (see _check_board_identity).

# Meta refs are plain text with a trailing newline; both sides of the
# comparison go through this one normalization, or a formatting difference
# would read as a foreign board.
sub _read_id_ref {
    my ( $self, $ref ) = @_;
    my $raw = $self->read_ref($ref) // '';
    $raw =~ s/\s+//g;
    return length $raw ? $raw : undef;
}

sub read_board_id_ref {
    my ($self) = @_;
    return $self->_read_id_ref(BOARD_ID_REF);
}

sub write_board_id_ref {
    my ( $self, $id ) = @_;
    return $self->write_ref( BOARD_ID_REF, "$id\n" );
}

# 128 bits of hex. This is an accident guard, not a secret, and rand is the
# same source App::karr::Cmd::AgentName uses; modern perls seed it from OS
# entropy.
sub new_board_id {
    my ($self) = @_;
    return join '', map { sprintf '%02x', int rand 256 } 1 .. 16;
}

# Read-before-write on purpose: an existing id is never re-keyed. That is
# what makes re-init of a half-board safe -- re-keying would make every other
# clone read this board as a foreign one.
sub ensure_board_id_ref {
    my ($self) = @_;
    my $id = $self->read_board_id_ref;
    return $id if defined $id;
    $id = $self->new_board_id;
    $self->write_board_id_ref($id);
    return $id;
}

# ----- Task / config refs (sit on top of write_ref/read_ref) -----

sub save_task_ref {
  my ($self, $task) = @_;
  my $ref = "refs/karr/tasks/" . $task->id . "/data";
  $self->write_ref($ref, $task->to_markdown);
}

sub load_task_ref {
  my ($self, $id) = @_;
  return ( $self->load_task_ref_with_oid($id) )[1];
}

# The task plus the OID of the commit it was read from, for callers that then
# write it back under compare-and-swap (App::karr::Cmd::Pick). Same pairing
# rule as read_ref_with_oid: guarding a write against an OID fetched
# independently of the content would guard the wrong revision.
sub load_task_ref_with_oid {
  my ($self, $id) = @_;
  my ($oid, $content) = $self->read_ref_with_oid("refs/karr/tasks/$id/data");
  return (undef, undef) unless defined $oid && length $content;
  return ($oid, App::karr::Task->from_string(
    $content,
    repair_frontmatter => $self->board_is_legacy_encoded,
  ));
}

sub save_task_ref_cas {
  my ($self, $task, $expected_old) = @_;
  my $ref = "refs/karr/tasks/" . $task->id . "/data";
  return $self->write_ref_cas($ref, $task->to_markdown, $expected_old);
}

# Only the data ref makes a task exist. The pattern used to be
# m{refs/karr/tasks/(\d+)/}, which also matched .../N/lock -- so a lock left
# behind by an agent that died mid-pick put its task id into this list even
# after the card itself was deleted, load_tasks mapped that id to undef, and
# every command that walks the board died on the undef. One orphaned lock ref
# bricked the whole board with no way out from inside karr (#45).
sub list_task_refs {
  my ($self) = @_;
  my %ids;
  for my $ref ( $self->list_refs('refs/karr/tasks/') ) {
    $ids{$1} = 1 if $ref =~ m{\Arefs/karr/tasks/(\d+)/data\z};
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

# ----- Whole-board replacement (restore) -----

# The mirror image of validate_helper_ref, which keeps helper refs out of the
# board namespace: a snapshot may only address refs inside it. Without this a
# hand-edited backup could point refs/heads/main at a parentless karr commit,
# because restore fed whatever keys the YAML carried straight to
# reference_create.
sub validate_board_ref {
    my ( $self, $ref ) = @_;
    defined $ref && length $ref
        or die "karr: snapshot contains a ref with no name\n";
    die "karr: '$ref' is outside the board namespace " . BOARD_ROOT . "\n"
        unless index( $ref, BOARD_ROOT ) == 0;
    die "karr: '$ref' is not a valid git ref name\n"
        unless Git::Native->reference_name_is_valid($ref);
    return $ref;
}

# Make the board consist of exactly the refs in %$refs (name => content).
#
# `karr restore` used to delete refs/karr/* first and write the snapshot back
# one ref at a time, so anything that failed on the way took the board with it.
# A single unusable ref name in the snapshot -- one that sorts before
# refs/karr/config is enough -- left the board empty locally and on the remote,
# because the END-block push insurance faithfully mirrored the half-executed
# destruction, prune and all (#47). The tool people reach for when they are
# already in trouble is the one that must not be able to make it worse.
#
# Nothing destructive happens here until the whole restore is known to be
# writable. Phase one validates every name and builds every commit object;
# neither touches a ref, so a failure leaves the board exactly as it was.
# Phase two then overwrites in place instead of starting from an empty
# namespace, so the board is never empty in between.
sub replace_board_refs {
    my ( $self, $refs ) = @_;
    my $repo = $self->_repo
        or die "karr: no usable git repository: "
             . ( $self->last_error // 'unknown error' ) . "\n";

    my @wanted = sort keys %$refs;
    for my $ref (@wanted) {
        $self->validate_board_ref($ref);
        die "karr: snapshot value for '$ref' is not text\n" if ref $refs->{$ref};
    }

    my %commit;
    for my $ref (@wanted) {
        $commit{$ref} =
            $self->_commit_for_content( $repo, $refs->{$ref} // '' );
    }

    $self->_write_ref_oid( $_, $commit{$_} ) for @wanted;

    # Only now the refs the snapshot does not carry. One left behind means the
    # board holds more than the snapshot did -- worth saying out loud, but not
    # worth failing a restore whose data is already in place.
    my @stuck;
    for my $ref ( $self->list_refs(BOARD_ROOT) ) {
        next if exists $commit{$ref};
        CORE::push @stuck, $ref unless $self->delete_ref($ref);
    }
    warn "karr: restored the snapshot, but could not remove "
       . join( ', ', @stuck ) . "\n" if @stuck;

    # The snapshot may carry a different meta/encoding than the board had.
    delete $self->{_encoding_version};
    return 1;
}

sub delete_refs {
    my ( $self, $prefix ) = @_;
    $self->delete_ref($_) for $self->list_refs($prefix);

    # Re-read rather than trust the loop. Now that delete_ref can say no
    # (#51), swallowing that here would just move the old lie one level up and
    # let `karr destroy` report success over refs that are still on disk. It is
    # also the only answer that stays right when a ref vanished underneath us:
    # gone is gone, whoever removed it.
    my @left = $self->list_refs($prefix);
    die "karr: could not delete " . join( ', ', @left ) . "\n" if @left;
    return 1;
}

1;
