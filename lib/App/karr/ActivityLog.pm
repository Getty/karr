# ABSTRACT: Activity log writer for karr board operations

package App::karr::ActivityLog;
our $VERSION = '0.403';
use Moo;
use App::karr::Encoding qw( json_encode json_decode );
use POSIX qw( strftime );

=head1 SYNOPSIS

    use App::karr::ActivityLog;
    use App::karr::Git;

    my $git = App::karr::Git->new(dir => '.');
    my $log = App::karr::ActivityLog->new(git => $git, role => 'agent');

    $log->log_entry(
        agent   => 'agent-fox',
        action  => 'pick',
        task_id => 5,
        detail  => 'in-progress',
    );

=head1 DESCRIPTION

Writes append-style JSON log entries to C<refs/karr/log/E<lt>identityE<gt>>
refs. Each entry receives an automatic timestamp if not provided.

The identity is C<E<lt>roleE<gt>/E<lt>emailE<gt>>: the Git user email
(sanitized for ref names) qualified by a B<role> (C<user> or C<agent>). The
role disambiguates a human and an AI agent that share one Git config. It
defaults to the C<KARR_ROLE> environment variable, or C<user>.

=head1 METHODS

=cut

has git => (
    is       => 'ro',
    required => 1,
);

=head2 role

The actor role, C<user> (default) or C<agent>. Read from C<KARR_ROLE> when not
given explicitly.

=cut

has role => (
    is      => 'ro',
    default => sub { $ENV{KARR_ROLE} || 'user' },
);

sub _sanitize {
    my ($self, $s) = @_;
    $s //= '';
    $s =~ s/[^a-zA-Z0-9._-]/_/g;
    return $s;
}

sub _email {
    my ($self) = @_;
    return $self->git->git_user_email || 'unknown';
}

=head2 identity

    my $id = $log->identity;   # e.g. "agent/getty_conflict.industries"

The sanitized C<E<lt>roleE<gt>/E<lt>emailE<gt>> string keying this actor's log.

=cut

sub identity {
    my ($self) = @_;
    return $self->_sanitize($self->role) . '/' . $self->_sanitize($self->_email);
}

sub _ref {
    my ($self) = @_;
    return 'refs/karr/log/' . $self->identity;
}

# Pre-role logs were keyed by bare sanitized email. Read them back for the
# default 'user' role so existing history is not orphaned.
sub _legacy_ref {
    my ($self) = @_;
    return 'refs/karr/log/' . $self->_sanitize($self->_email);
}

=head2 log_entry

    $log->log_entry(
        agent   => 'agent-fox',
        action  => 'pick',
        task_id => 5,
        detail  => 'in-progress',
        ts      => '2026-05-15T10:00:00Z',  # optional, auto-generated
    );

Writes a JSON log line to the per-identity ref. The ref path is
C<refs/karr/log/E<lt>roleE<gt>/E<lt>sanitized_emailE<gt>>.

Returns the result of L<Git/write_ref>.

=cut

sub log_entry {
    my ($self, %entry) = @_;
    $entry{ts} //= strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
    my $ref = $self->_ref;
    my $existing = $self->git->read_ref($ref);
    my $line = json_encode(\%entry);
    my $new = $existing ? "$existing\n$line" : $line;
    return $self->git->write_ref($ref, $new);
}

=head2 entries

    my @entries = $log->entries;

Returns the decoded log entries for this identity, oldest first. For the
C<user> role, falls back to the legacy bare-email ref when the role-qualified
ref does not yet exist.

=cut

sub entries {
    my ($self) = @_;
    my $content = $self->git->read_ref($self->_ref);
    if ((!defined $content || !length $content) && $self->role eq 'user') {
        $content = $self->git->read_ref($self->_legacy_ref);
    }
    return () unless defined $content && length $content;
    my @entries;
    for my $line (split /\n/, $content) {
        next unless length $line;
        my $decoded = eval { json_decode($line) };
        push @entries, $self->git->maybe_repair_legacy($decoded) if $decoded;
    }
    return @entries;
}

=head2 last_entry

    my $entry = $log->last_entry;

The most recent decoded log entry for this identity, or C<undef> if none.

=cut

sub last_entry {
    my ($self) = @_;
    my @entries = $self->entries;
    return @entries ? $entries[-1] : undef;
}

1;
