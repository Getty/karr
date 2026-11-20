# ABSTRACT: Show, set or clear whether this clone may write the board

package App::karr::Cmd::Readonly;
our $VERSION = '0.603';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr readonly [on|off] [--json]',
);
use App::karr::CloneState;
use App::karr::Error ();
use App::karr::Role::BoardDiscovery;
use App::karr::Role::CliArgs;
use App::karr::Role::Output;

# BoardDiscovery and not BoardAccess: this command reads and writes the clone's
# git config and nothing else, so it takes no sync lifecycle -- no pull, no
# push, and no read-only door in front of it, which would refuse the very
# command that lifts the state.
with 'App::karr::Role::BoardDiscovery';
with 'App::karr::Role::CliArgs';
with 'App::karr::Role::Output';

=head1 SYNOPSIS

    karr readonly              # show the state
    karr readonly --json
    karr readonly on           # this clone is only for reading
    karr readonly off          # let this clone try to write again

=head1 DESCRIPTION

A board is shared by every clone; whether I<this> clone may publish to it is
not. A clone whose remote denies it write access -- a public repository cloned
over https without credentials, a read-only deploy key, a directory this user
cannot write -- is B<read-only for the board> (L<App::karr::CloneState>). The
first push that is denied takes the command's change back and records the
state; from then on every command that writes board refs is refused after its
pull and before it writes anything, so no change is left in a clone that could
never publish it. Reading keeps working.

This command shows that state and changes it by hand. It reads and writes the
clone's own git config (F<.git/config>) and nothing else: no board ref, no
pull, no push, no network. It needs a Git repository but no board, so
C<karr readonly on> works right after C<git clone>, before the board was ever
fetched.

=head2 karr readonly

Shows the state, one of:

=over 4

=item * C<off> -- board writes are pushed to the remote as usual.

=item * C<denied> -- the remote denied this clone write access: since when,
why, and for which push URL.

=item * C<on> -- set by hand, for a clone that is only for reading.

=back

A recorded state applies only to the push URL it was recorded for. When the
remote's effective push URL has changed since (C<git remote set-url --push>, a
new C<pushurl> or C<url>), the output says that the state no longer applies:
board writes push again, and the old record is dropped after the next push
that lands.

=head2 karr readonly on

Puts this clone into C<on> for the remote's current push URL, or confirms an
C<on> already in force (and then changes nothing). It replaces a C<denied>
state: the clone's maintainer has decided that it is only for reading.
C<karr sync> then only pulls.

=head2 karr readonly off

Clears the state, C<denied> or C<on>. The next board write pushes again; if
the remote still denies it, that write is taken back and the clone is
read-only again.

Any other argument is a usage error (exit C<2>).

=head1 OPTIONS

=over 4

=item * C<--json>

Emit the state as one JSON object -- L<App::karr::CloneState/read_only>:
C<mode> (C<off>, C<denied> or C<on>), C<applies>, C<remote> and
C<current_push_url>, and for a recorded state C<push_url>, C<since> and, for
C<denied>, C<reason>. After C<on> or C<off>, the state they leave.

=back

=head1 EXIT CODES

C<0> on success, C<1> when git config cannot be written, C<2> for an unknown
or surplus argument (ADR 0002).

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::CloneState>, L<App::karr::Cmd::Sync>,
L<App::karr::Role::SyncLifecycle>

=cut

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->check_positional_args($args_ref, 1);
  my ($action) = $self->positional_args($args_ref);
  $self->usage_error(
    "unknown argument '$action' (use on, off, or nothing to show the state)")
    if defined $action && $action ne 'on' && $action ne 'off';

  # for_git answers undef only for a git double without config methods; the
  # repository this command discovered always has them.
  my $state = App::karr::CloneState->for_git( $self->git )
    or App::karr::Error::user_error(
      'karr: the read-only state of this clone cannot be read.');

  my $ro = $state->read_only;
  my @lines;

  if ( defined $action && $action eq 'off' ) {
    my $was = $ro;
    my $had = $state->clear_read_only;
    $ro = $state->read_only;
    App::karr::Error::user_error(
      'karr: could not clear the read-only state in git config: '
      . ( $self->git->last_error // 'unknown error' ) )
      if $ro->{mode} ne 'off';
    @lines = $self->_off_lines( $was, $had );
  }
  else {
    # `on` when already on for this push URL: confirmed, untouched, so its
    # time stays the time it was set.
    $ro = $state->set_read_only_on
      if defined $action && !( $ro->{applies} && $ro->{mode} eq 'on' );
    @lines = $self->_state_lines($ro);
  }

  if ($self->json) {
    $self->print_json($ro);
    return;
  }
  print "$_\n" for @lines;
}

# The state as text, one line saying it and the details under it.
sub _state_lines {
  my ($self, $ro) = @_;
  my $remote = $ro->{remote};
  my $now    = $ro->{current_push_url};

  if ( $ro->{mode} eq 'off' ) {
    return defined $now
      ? "Read-only: off -- this clone writes the board and pushes it to '$remote' ($now)."
      : "Read-only: off -- no remote '$remote' is configured, so board writes stay in this clone.";
  }

  unless ( $ro->{applies} ) {
    my $for = length $ro->{push_url}
      ? "for $ro->{push_url}"
      : 'while no push URL was configured';
    my $when = defined $ro->{since}  ? " on $ro->{since}"  : '';
    my $why  = defined $ro->{reason} ? " ($ro->{reason})" : '';
    return (
      "Read-only: off -- the '$ro->{mode}' state recorded $for$when$why no longer applies: "
        . ( defined $now
            ? "the push URL of '$remote' is now $now."
            : "no remote '$remote' is configured now." ),
      'Board writes push again; the old record is dropped after the next push that lands.',
    );
  }

  my @lines = $ro->{mode} eq 'denied'
    ? 'Read-only: denied -- the remote denied this clone write access, so every '
      . 'board write is refused before anything is written.'
    : 'Read-only: on -- set by hand (karr readonly on), so every board write is '
      . 'refused before anything is written.';
  push @lines, '  Remote: ' . $remote
    . ( defined $now ? " ($now)" : ' (not configured)' );
  push @lines, "  Since:  $ro->{since}"  if defined $ro->{since};
  push @lines, "  Reason: $ro->{reason}" if defined $ro->{reason};

  if ( $ro->{mode} eq 'denied' ) {
    push @lines,
      'Reading and pulling keep working. Once this clone can write: a new push URL '
        . "lifts this by itself, 'karr sync' lifts it with the push that lands, "
        . "or 'karr readonly off' clears it.",
      'If this clone is only for reading: karr readonly on.';
  }
  else {
    push @lines,
      "Reading and pulling keep working; 'karr sync' only pulls. "
        . "'karr readonly off' lets this clone write again.";
  }
  return @lines;
}

# What `karr readonly off` did, given the state before it.
sub _off_lines {
  my ($self, $was, $had) = @_;
  return 'This clone was not read-only for the board; nothing changed.'
    unless $had;
  return "Dropped a '$was->{mode}' state that no longer applied; board writes "
    . 'push as usual.'
    unless $was->{applies};
  my $line = 'This clone is no longer read-only for the board: the next board '
    . 'write pushes again.';
  $line .= ' If the remote still denies it, that write is taken back and this '
    . 'clone is read-only again.'
    if $was->{mode} eq 'denied';
  return $line;
}

1;
