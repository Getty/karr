# ABSTRACT: What this clone knows about its own push access, kept in git config

package App::karr::CloneState;
our $VERSION = '0.603';
use Moo;
use POSIX ();
use Scalar::Util qw( blessed );
use App::karr::Error ();

=head1 SYNOPSIS

    my $state = App::karr::CloneState->for_git($git) or return;

    my $ro = $state->read_only;          # { mode => 'off' | 'denied' | 'on', ... }
    $state->refuse_writes;               # dies with the refusal when read-only

    print STDERR "$_\n" for $state->warning_lines;   # the lasting warnings

=head1 DESCRIPTION

A board is shared by every clone; whether I<this> clone can publish to it is
not. A clone whose remote denies it write access -- a public repository cloned
over https without credentials, a read-only deploy key -- cannot publish a
board change, and a change it cannot publish must not stay in it either:
another clone would never see the card and could hand out the same number.
So such a clone becomes a B<read-only clone>. Its state lives in the
repository's own git config (F<.git/config>), never on the board, because the
board config is every clone's at once.

The state is one of three modes:

=over 4

=item C<off>

No state recorded (or one that no longer applies, see below): writes and
pushes go as usual.

=item C<denied>

Learned from a push that was denied write access
(L<App::karr::Git/push_failure>), with the reason and the time (UTC).
L<App::karr::Role::SyncLifecycle/sync_after> learns it, after taking the
command's own writes back.

=item C<on>

Set (or confirmed) by hand, with C<karr readonly on>, for a clone that is only
for reading.

=back

Either mode applies only to the push URL it was recorded for -- the remote's
effective push URL (L<App::karr::Git/push_url>), stored without userinfo. When
that URL changes (C<git remote set-url --push>, a new C<pushurl> or C<url>) the
state no longer applies, writes and pushes go as usual, and the stale keys are
dropped after the next push that lands (L</note_push_landed>).

While a mode applies, every command that writes board refs is refused after
its pull and before its first ref write (L</refuse_writes>,
L<App::karr::Role::SyncLifecycle/sync_before>). Reading keeps working.

Beside the mode, this class remembers why the last push that failed for
another reason failed -- unreachable, rejected, stale, anything else -- and
when, so the lasting warning about B<unpublished changes> (L</warning_lines>)
can say so without a network round trip.

=head2 Git config keys

All in the C<karr> section of the repository's git config:

    karr.readonly          denied | on
    karr.readonlyPushUrl   the push URL the mode applies to, without userinfo
    karr.readonlyReason    for denied: the short reason (App::karr::Git/push_failure)
    karr.readonlySince     when the mode was recorded, UTC, 2026-11-20T18:41:46Z
    karr.lastPushFailure   class of the last failed push that was not denied
    karr.lastPushReason    its short reason
    karr.lastPushAt        its time, UTC

The C<lastPush*> keys are cleared by the next push that succeeds.

=cut

has git => ( is => 'ro', required => 1 );

has remote => ( is => 'ro', default => sub { 'origin' } );

=attr git

The L<App::karr::Git> of the clone. Required.

=attr remote

The remote the board syncs with. Default C<origin>.

=cut

use constant {
    KEY_MODE        => 'karr.readonly',
    KEY_PUSH_URL    => 'karr.readonlyPushUrl',
    KEY_REASON      => 'karr.readonlyReason',
    KEY_SINCE       => 'karr.readonlySince',
    KEY_LAST_CLASS  => 'karr.lastPushFailure',
    KEY_LAST_REASON => 'karr.lastPushReason',
    KEY_LAST_AT     => 'karr.lastPushAt',
};

my @READ_ONLY_KEYS = ( KEY_MODE, KEY_PUSH_URL, KEY_REASON, KEY_SINCE );
my @LAST_PUSH_KEYS = ( KEY_LAST_CLASS, KEY_LAST_REASON, KEY_LAST_AT );

sub for_git {
    my ( $class, $git, %arg ) = @_;
    return undef unless blessed($git)
        && $git->can('git_config_get') && $git->can('push_url');
    return $class->new( git => $git, %arg );
}

=method for_git

    my $state = App::karr::CloneState->for_git( $git, remote => 'origin' );

The state of the clone C<$git> belongs to, or C<undef> when C<$git> cannot
carry one -- the duck-typed git doubles the sync tests drive
L<App::karr::Role::SyncLifecycle> with. Every caller in the distribution goes
through this rather than C<new>, so a double without git config degrades to
"no state" instead of dying.

=cut

sub _now {
    return POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
}

sub _get {
    my ( $self, $key ) = @_;
    my $val = $self->git->git_config_get($key);
    return defined $val && length $val ? $val : undef;
}

sub _set {
    my ( $self, %kv ) = @_;
    my $git = $self->git;
    for my $key ( sort keys %kv ) {
        $git->git_config_set( $key, $kv{$key} )
            or die 'karr: could not record the read-only state in git config: '
                 . ( $git->last_error // 'unknown error' ) . "\n";
    }
    return 1;
}

sub _unset {
    my ( $self, @keys ) = @_;
    $self->git->git_config_unset($_) for @keys;
    return 1;
}

sub read_only {
    my ($self) = @_;
    my $mode = $self->_get(KEY_MODE) // 'off';
    $mode = 'off' unless $mode eq 'denied' || $mode eq 'on';

    my %state = (
        mode             => $mode,
        remote           => $self->remote,
        current_push_url => $self->git->push_url( $self->remote ),
        applies          => 0,
    );
    return \%state if $mode eq 'off';

    $state{push_url} = $self->_get(KEY_PUSH_URL) // '';
    $state{since}    = $self->_get(KEY_SINCE);
    $state{reason}   = $self->_get(KEY_REASON) if $mode eq 'denied';
    $state{applies}  = $state{push_url} eq ( $state{current_push_url} // '' ) ? 1 : 0;
    return \%state;
}

=method read_only

    my $ro = $state->read_only;
    # {
    #   mode             => 'denied',        # or 'on', or 'off'
    #   applies          => 1,               # the mode is in force right now
    #   remote           => 'origin',
    #   push_url         => 'https://github.com/owner/repo.git',  # recorded for
    #   current_push_url => 'https://github.com/owner/repo.git',  # configured now
    #   since            => '2026-11-20T18:41:46Z',
    #   reason           => 'no credentials for HTTPS',            # denied only
    # }

The recorded state, as data: no rendering, no network. C<applies> is true
when a mode is recorded I<and> the remote's current effective push URL is the
one it was recorded for; a mode whose URL has changed is reported with
C<applies> false. C<push_url>, C<since> and C<reason> are only present when a
mode is recorded; C<current_push_url> is C<undef> when the remote is not
configured. This is what C<karr readonly> shows, C<--json> included.

=cut

sub read_only_mode {
    my ($self) = @_;
    my $ro = $self->read_only;
    return $ro->{applies} ? $ro->{mode} : undef;
}

=method read_only_mode

    my $mode = $state->read_only_mode;   # 'denied', 'on' or undef

The mode in force right now, or C<undef> when this clone may write. What
karr-foundation asks to leave a board alone and to mark it in its overview.

=cut

sub set_read_only_on {
    my ($self) = @_;
    $self->_set(
        KEY_MODE,     'on',
        KEY_PUSH_URL, $self->git->push_url( $self->remote ) // '',
        KEY_SINCE,    _now(),
    );
    $self->_unset(KEY_REASON);
    return $self->read_only;
}

=method set_read_only_on

    my $ro = $state->set_read_only_on;

Puts the clone into C<on> for its current push URL -- C<karr readonly on>, for
a clone that is only for reading, or to confirm a C<denied> one. Returns the
new L</read_only>. Dies when git config cannot be written.

=cut

sub clear_read_only {
    my ($self) = @_;
    my $had = defined $self->_get(KEY_MODE) ? 1 : 0;
    $self->_unset(@READ_ONLY_KEYS);
    return $had;
}

=method clear_read_only

    my $had = $state->clear_read_only;

Drops the read-only state -- C<karr readonly off>. The next write pushes
again, and learns C<denied> again if the remote still denies it. Returns true
when there was a state to drop.

=cut

sub learn_denied {
    my ( $self, $failure ) = @_;
    $failure ||= {};
    my $was = $self->read_only;
    # Denied again for the same URL (karr sync trying): still denied since the
    # first time.
    my $since = $was->{applies} && $was->{mode} eq 'denied' && $was->{since}
        ? $was->{since} : _now();
    $self->_set(
        KEY_MODE,     'denied',
        KEY_PUSH_URL, $self->git->push_url( $self->remote ) // '',
        KEY_REASON,   $failure->{reason} // 'write access denied',
        KEY_SINCE,    $since,
    );
    # The last push was this denial; an older unreachable no longer is.
    $self->_unset(@LAST_PUSH_KEYS);
    return $self->read_only;
}

=method learn_denied

    $state->learn_denied( $git->push_failure );

Records C<denied> for the current push URL, with the failure's reason and the
time. L<App::karr::Role::SyncLifecycle> and L<App::karr::SyncGuard> call it on
the first push denied write access, through L</denied_push>. A clone already
denied for that URL keeps the time of the first denial. Dies when git config
cannot be written.

=cut

sub note_push_failure {
    my ( $self, $failure ) = @_;
    return unless $failure && $failure->{class};
    return if $failure->{class} eq 'denied';
    $self->_set(
        KEY_LAST_CLASS,  $failure->{class},
        KEY_LAST_REASON, $failure->{reason} // '',
        KEY_LAST_AT,     _now(),
    );
    return 1;
}

=method note_push_failure

    $state->note_push_failure( $git->push_failure );

Remembers a board push that failed for any reason but a denial (those are
L</learn_denied>'s): its class, reason and time, for the lasting warning about
unpublished changes.

=cut

sub note_push_landed {
    my ( $self, %opt ) = @_;
    $self->_unset( grep { defined $self->_get($_) } @LAST_PUSH_KEYS );
    return 0 unless $opt{sent};

    my $ro = $self->read_only;
    if ( $ro->{mode} eq 'off' ) {
        # Keys a hand edit left without their mode mean nothing; tidy them.
        $self->_unset( grep { defined $self->_get($_) } @READ_ONLY_KEYS );
        return 0;
    }
    # A mode by hand stays while it applies: no push lands in it anyway.
    return 0 if $ro->{mode} eq 'on' && $ro->{applies};
    $self->clear_read_only;
    return $ro->{applies} ? 1 : 0;
}

=method note_push_landed

    my $lifted = $state->note_push_landed( sent => $git->push_sent );

After a push that succeeded: forgets the last failure, and -- when the push
really sent something (C<sent>, L<App::karr::Git/push_sent>), which proves this
clone can write -- drops a C<denied> state, and any state recorded for a push
URL that is no longer the remote's. Returns true when a C<denied> state that
applied was lifted, so the caller can say so. An empty push proves nothing and
lifts nothing.

=cut

sub last_push_failure {
    my ($self) = @_;
    my $class = $self->_get(KEY_LAST_CLASS) or return undef;
    return {
        class  => $class,
        reason => $self->_get(KEY_LAST_REASON) // '',
        at     => $self->_get(KEY_LAST_AT),
    };
}

=method last_push_failure

    my $last = $state->last_push_failure;   # { class, reason, at } or undef

The failure L</note_push_failure> recorded, until a push succeeds.

=cut

sub unpublished {
    my ($self) = @_;
    my $git = $self->git;
    return () unless $git->can('unpublished_refs');
    return short_ref_names( $git->unpublished_refs( $self->remote ) );
}

=method unpublished

    my @names = $state->unpublished;   # ('#452', 'log', 'next-id')

The changes in this clone that are not on the remote, by the short names the
messages use (L</short_ref_names>). Read from the remote's last known state
(L<App::karr::Git/unpublished_refs>), no network. Empty when no remote is
configured.

=cut

sub short_ref_names {
    my ($refs) = @_;
    $refs = $_[1] if @_ > 1;    # also callable as a class method
    my ( %card, %other );
    for my $ref ( keys %{ $refs || {} } ) {
        my $deleted = ( $refs->{$ref} // '' ) eq 'deleted';
        if ( $ref =~ m{\Arefs/karr/tasks/(\d+)/(.+)\z} ) {
            my ( $id, $rest ) = ( $1, $2 );
            # The card's data ref says what happened to the card.
            next if exists $card{$id} && $rest ne 'data';
            $card{$id} = $deleted && $rest eq 'data' ? "#$id (deleted)" : "#$id";
            next;
        }
        # A name that stands for one ref (next-id, config) can say it was
        # deleted; one that stands for a family (log) cannot.
        my ( $name, $single ) =
              $ref =~ m{\Arefs/karr/meta/(.+)\z}        ? ( $1, 1 )
            : $ref =~ m{\Arefs/karr/([^/]+)\z}          ? ( $1, 1 )
            : $ref =~ m{\Arefs/karr/([^/]+)/}           ? ( $1, 0 )
            : $ref =~ m{\Arefs/(karr-foundation/[^/]+)} ? ( $1, 0 )
            :                                             ( $ref, 1 );
        $other{ $deleted && $single ? "$name (deleted)" : $name } = 1;
    }
    return ( map( { $card{$_} } sort { $a <=> $b } keys %card ), sort keys %other );
}

=method short_ref_names

    my @names = App::karr::CloneState->short_ref_names(
        { 'refs/karr/tasks/12/data' => 'changed', 'refs/karr/meta/next-id' => 'changed' } );
    # ('#12', 'next-id')

The names messages give refs: a card as C<#12> (C<#12 (deleted)> for a
deletion not published yet), the id counter as C<next-id>, the board config as
C<config>, every activity log ref as C<log>, a fleet ref as
C<karr-foundation/chain> and so on. Cards first, by number; the rest sorted,
each named once.

=cut

# ----- Messages ---------------------------------------------------------

sub _url_kind {
    my ($url) = @_;
    return 'none'  unless defined $url && length $url;
    return 'http'  if $url =~ m{\Ahttps?://}i;
    return 'ssh'   if $url =~ m{\A(?:ssh|git\+ssh|ssh\+git)://}i;
    return 'local' if $url =~ m{\Afile://}i;
    return 'other' if $url =~ m{\A[A-Za-z][A-Za-z0-9+.\-]*://};
    # The reading App::karr::Git gives a URL: a drive letter is a path, a colon
    # before the first slash an scp-style ssh remote, the rest a path.
    return 'local' if $^O eq 'MSWin32' && $url =~ m{\A[A-Za-z]:[\\/]};
    return 'ssh'   if $url =~ m{\A[^/]*:};
    return 'local';
}

sub fix_lines {
    my ( $class, %arg ) = @_;
    my $remote = $arg{remote} // 'origin';
    my $url    = $arg{push_url};
    my $kind   = _url_kind($url);

    my @lines;
    if ( $kind eq 'http' && $url =~ m{\Ahttps?://([^/:]+)(?::\d+)?/(.+?)/*\z}i ) {
        my ( $host, $path ) = ( $1, $2 );
        $path .= '.git' unless $path =~ /\.git\z/;
        CORE::push @lines,
            "Either push over SSH, which keeps fetching as it is: "
              . "git remote set-url --push $remote git\@$host:$path",
            'or give git a credential for HTTPS.';
    }
    elsif ( $kind eq 'http' ) {
        CORE::push @lines, 'Push over SSH (git remote set-url --push), or give git a '
          . 'credential for HTTPS.';
    }
    elsif ( $kind eq 'ssh' ) {
        CORE::push @lines, 'The SSH key is missing, or the remote only lets it read: '
          . 'this clone needs a key with write access.';
    }
    elsif ( $kind eq 'local' ) {
        CORE::push @lines, "This user cannot write the repository at $url: "
          . 'it needs write access to its files.';
    }
    else {
        CORE::push @lines, "This clone needs write access to the remote '$remote'.";
    }
    CORE::push @lines,
        'Then run the command again. The read-only state lifts by itself when '
          . "the push URL changes; otherwise run 'karr readonly off' first.",
        'If this clone is only for reading: karr readonly on.';
    return @lines;
}

=method fix_lines

    my @lines = App::karr::CloneState->fix_lines(
        remote => 'origin', push_url => 'https://github.com/owner/repo.git' );

The way out of a denial, as lines: for an https push URL the SSH push URL that
keeps fetching as it is (C<git remote set-url --push ...>) or a credential;
for SSH a key with write access; for a local path write access to its files.
Then how the read-only state lifts, and C<karr readonly on> for a clone that
is only for reading. Part of both L</denial_message> and L</refusal_message>.

=cut

sub denial_message {
    my ( $class, %arg ) = @_;
    my $failure = $arg{failure} || {};
    my $remote  = $failure->{remote} // $arg{remote} // 'origin';
    my $reason  = $failure->{reason} // 'write access denied';
    my $url     = $arg{push_url};
    my $where   = defined $url ? "'$remote' ($url)" : "'$remote'";

    my @lines = ( "karr: write access to the remote $where was denied: $reason." );
    if ( @{ $arg{taken_back} || [] } ) {
        CORE::push @lines, "Nothing was changed: this command's change was taken back, "
          . 'and this clone is now read-only for the board. Run the command again '
          . 'once this clone can write.';
    }
    elsif ( $arg{already} ) {
        CORE::push @lines, 'Nothing was published: this clone stays read-only for the board.';
    }
    else {
        CORE::push @lines, 'Nothing was published, and this clone is now read-only '
          . 'for the board.';
    }
    if ( my @still = @{ $arg{unpublished} || [] } ) {
        CORE::push @lines, 'Still only in this clone, not on the remote: '
          . join( ', ', @still ) . '.';
    }
    CORE::push @lines, $class->fix_lines( remote => $remote, push_url => $url );
    return join "\n", @lines;
}

=method denial_message

    my $text = App::karr::CloneState->denial_message(
        failure     => $git->push_failure,   # { class, reason, remote }
        push_url    => $git->push_url,
        taken_back  => \@refs,               # what take_back_journal returned
        already     => 0,                    # the clone was read-only before
        unpublished => [ $state->unpublished ],
    );

The message at a denial, as one string without a trailing newline:

    karr: write access to the remote 'origin' (URL) was denied: REASON.
    Nothing was changed: this command's change was taken back, and this clone
    is now read-only for the board. Run the command again once this clone can
    write.

then L</fix_lines>. (The second sentence is one line.) A push that took
nothing of the command back -- C<karr sync> -- says C<Nothing was published>
instead, and C<stays read-only> when the clone already was. Changes older than
the command that are still only here are listed on a line of their own.

=cut

sub refusal_message {
    my ($self) = @_;
    my $ro = $self->read_only;
    return undef unless $ro->{applies};
    return 'karr: this clone is read-only for the board (karr readonly on). '
      . 'Nothing was changed.' if $ro->{mode} eq 'on';

    my $remote = $ro->{remote};
    my $since  = $ro->{since}  // 'an unknown time';
    my $reason = $ro->{reason} // 'write access denied';
    my $url    = length $ro->{push_url} ? " ($ro->{push_url})" : '';
    return join "\n",
        "karr: this clone is read-only for the board: write access to '$remote'$url "
          . "was denied on $since ($reason). Nothing was changed.",
        $self->fix_lines( remote => $remote,
            push_url => length $ro->{push_url} ? $ro->{push_url} : undef );
}

=method refusal_message

    my $text = $state->refusal_message;   # undef when this clone may write

The refusal of a write in a read-only clone. In C<denied>:

    karr: this clone is read-only for the board: write access to 'origin' (URL)
    was denied on TIME (REASON). Nothing was changed.

(one line) followed by L</fix_lines>; in C<on> the one line
C<karr: this clone is read-only for the board (karr readonly on). Nothing was
changed.>

=cut

sub refuse_writes {
    my ($self) = @_;
    my $text = $self->refusal_message;
    return 1 unless defined $text;
    $self->mark_reported;
    App::karr::Error::user_error($text);
}

=method refuse_writes

    $state->refuse_writes;

Dies with L</refusal_message> (exit 1, through
L<App::karr::Error/user_error>) when a read-only mode applies, and returns
true otherwise. The door every board write passes:
L<App::karr::Role::SyncLifecycle/sync_before> calls it after its pull and
before the command's first ref write, C<--local-only> included; C<karr init>
and C<karr set-refs>, which write without that door, call it themselves.

=cut

sub warning_lines {
    my ($self) = @_;
    my $git = $self->git;
    return () unless $git->can('has_remote') && $git->has_remote( $self->remote );

    my $ro     = $self->read_only;
    my $remote = $self->remote;
    my $denied = $ro->{applies} && $ro->{mode} eq 'denied';
    my @lines;
    if ($denied) {
        my $since = $ro->{since} // 'an unknown time';
        CORE::push @lines, "karr: this clone cannot write the board: write access to "
          . "'$remote' was denied on $since. Fix the access, or 'karr readonly on' "
          . 'if this clone is only for reading.';
    }

    my @names = $self->unpublished;
    if (@names) {
        CORE::push @lines, "karr: changes still not on the remote '$remote': "
          . join( ', ', @names ) . '. ' . $self->_unpublished_tail($ro);
    }
    return @lines;
}

sub _unpublished_tail {
    my ( $self, $ro ) = @_;
    if ( $ro->{applies} && $ro->{mode} eq 'on' ) {
        return 'This clone is read-only for the board (karr readonly on), so they '
          . "are not pushed; 'karr readonly off' and 'karr sync' publish them.";
    }
    if ( $ro->{applies} && $ro->{mode} eq 'denied' ) {
        return 'Last push: write access denied (' . ( $ro->{since} // 'unknown time' )
          . "). They stay in this clone until it can write; then 'karr sync' "
          . 'publishes them.';
    }
    my $last = $self->last_push_failure
        or return "Run 'karr sync' to publish them.";
    my $at = $last->{at} // 'unknown time';
    return "Last push: remote unreachable ($at). Run 'karr sync' once the remote "
      . 'can be reached.' if $last->{class} eq 'unreachable';
    return "Last push: rejected by the remote ($at). Run 'karr sync' to see "
      . 'what it refuses.' if $last->{class} eq 'rejected';
    return "Last push: the remote had changed ($at). Run 'karr sync' to pull "
      . 'that in and push again.' if $last->{class} eq 'stale';
    my $why = length $last->{reason} ? ": $last->{reason}" : '';
    return "Last push: failed$why ($at). Run 'karr sync' to retry.";
}

=method warning_lines

    print STDERR "$_\n" for $state->warning_lines;

The lasting warnings, as lines without newlines, for every command to print on
STDERR -- read commands included, C<--quiet> or not, and never on STDOUT, so
C<--json> output stays parseable. No network: the lines come from git config
and the remote's last known state. Nothing at all when no remote is
configured. At most two lines:

=over 4

=item * In C<denied>:
C<karr: this clone cannot write the board: write access to 'origin' was denied
on TIME. Fix the access, or 'karr readonly on' if this clone is only for
reading.> Nothing for C<on>.

=item * When this clone holds changes the remote does not have
(L</unpublished>):
C<karr: changes still not on the remote 'origin': #452, next-id.> followed by
what is known about why: C<Last push: remote unreachable (TIME). Run 'karr
sync' once the remote can be reached.>, the same for a rejected, stale or
otherwise failed push, a note that the clone is read-only, or C<Run 'karr
sync' to publish them.> when no failed push was recorded (C<--local-only>, a
clone from before this was recorded).

=back

A command that already printed a denial, a refusal or a push failure in this
process (L</reported>) has said all of this; the caller skips the lines then.

=cut

# Whether this process has already told the user about the push state -- a
# denial, a refusal, a failed push -- so the lasting warnings would only
# repeat it. Process-global for the reason App::karr::Git's $WRITES is.
our $REPORTED = 0;

sub reported       { return $REPORTED }
sub mark_reported  { $REPORTED = 1; return 1 }
sub reset_reported { $REPORTED = 0; return 1 }

=method reported

    unless ( App::karr::CloneState->reported ) {
        print STDERR "$_\n" for $state->warning_lines;
    }

True once this process has printed a denial (L</denial_message>), a refusal
(L</refuse_writes>) or a failed push's verdict
(L<App::karr::Role::SyncLifecycle/sync_after>, L<App::karr::SyncGuard>): the
lasting warnings would only repeat what the user just read.

=method mark_reported

    App::karr::CloneState->mark_reported;

Sets L</reported>. Called by everything that prints one of those messages.

=method reset_reported

    App::karr::CloneState->reset_reported;

Clears L</reported>. Process-global (C<$App::karr::CloneState::REPORTED>), so
a runner that executes several commands in one process -- the in-process test
runner -- resets it per command, or localizes the variable.

=cut

sub denied_push {
    my ( $class, $git, %opt ) = @_;
    my $failure = ( $git->can('push_failure') && $git->push_failure ) || {};
    my $remote  = $failure->{remote} // 'origin';

    # First, so nothing of the command outlives the denial: the card, the log
    # entry and the id counter alike (App::karr::Git/take_back_journal).
    my @back = $opt{take_back} && $git->can('take_back_journal')
        ? $git->take_back_journal( next_id => 1 ) : ();

    my $state = $class->for_git( $git, remote => $remote );
    my ( $already, $url, @still, $unrecorded );
    if ($state) {
        my $was = $state->read_only;
        $already = $was->{applies} && $was->{mode} eq 'denied';
        $url     = $was->{current_push_url};
        eval { $state->learn_denied($failure); 1 } or $unrecorded = $@;
        @still = $state->unpublished;
    }
    $class->mark_reported;
    my $text = $class->denial_message(
        failure     => $failure,
        remote      => $remote,
        push_url    => $url,
        taken_back  => \@back,
        already     => $already,
        unpublished => \@still,
    );
    if ( defined $unrecorded ) {
        $unrecorded =~ s/\s+\z//;
        $text .= "\n$unrecorded";
    }
    return $text;
}

sub failed_push {
    my ( $class, $git ) = @_;
    my $failure = $git->can('push_failure') ? $git->push_failure : undef;
    my $remote  = ( $failure && $failure->{remote} ) // 'origin';
    if ( my $state = $class->for_git( $git, remote => $remote ) ) {
        # A record that cannot be written costs the later warning its
        # "Last push:" clause, not this report.
        eval { $state->note_push_failure($failure) if $failure; 1 };
    }
    $class->mark_reported;
    my @names = $git->can('unpublished_refs')
        ? short_ref_names( $git->unpublished_refs($remote) ) : ();
    return $class->saved_here_line(@names);
}

=method failed_push

    my $line = App::karr::CloneState->failed_push($git);

After a push that failed for any reason but a denial: remembers why
(L</note_push_failure>), sets L</reported>, and returns the
L</saved_here_line> naming what is still only in this clone.

=cut

sub saved_here_line {
    my ( $class, @names ) = @_;
    return 'Saved in this clone, not on the remote.' unless @names;
    my $line = 'Saved in this clone, not on the remote: ' . join( ', ', @names ) . '.';
    my $cards   = grep { /\A#/ } @names;
    my $counter = grep { $_ eq 'next-id' } @names;
    $line .= ' Other clones do not see this yet'
      . ( $counter ? ' and can hand out the same card number' : '' ) . '.'
      if $cards || $counter;
    return $line;
}

=method saved_here_line

    my $line = App::karr::CloneState->saved_here_line( '#12', 'log', 'next-id' );
    # Saved in this clone, not on the remote: #12, log, next-id. Other clones
    # do not see this yet and can hand out the same card number.

The line every failed push ends its report with, in place of the old "Local
refs are intact": what is in this clone and not on the remote, and what that
risks.

=cut

=method denied_push

    my $text = App::karr::CloneState->denied_push( $git, take_back => 1 );

Everything that follows a push denied write access, in order: the command's
own writes are taken back (C<take_back>, L<App::karr::Git/take_back_journal>
with the id counter), the clone learns C<denied> (L</learn_denied>), and
L</reported> is set. Returns the L</denial_message> for the caller to raise or
warn. A C<$git> without git config (a test double) learns nothing and gets
the message alone.

=cut

1;
