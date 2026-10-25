# ABSTRACT: Role running a command again when its push found the board moved

package App::karr::Role::ReapplyOnStale;
our $VERSION = '0.603';
use Moo::Role;
# Loaded without importing, for the reason App::karr::Role::SyncLifecycle gives:
# a role composes every sub in its package into its consumers, imported ones
# included.
use App::karr::Error ();

requires 'execute';

# Set by App::karr::Role::SyncLifecycle when it takes a stale push's writes back
# and wants the command to run again; read and cleared by the wrapper below.
has _stale_reapply => (
  is      => 'rw',
  default => 0,
);

=head1 DESCRIPTION

Composed by the commands that can decide again when their push finds that
another clone published in the window since their pull (k322): C<create>, whose
card simply takes the next free id, and C<pick>, which moves on to the next
candidate when the card it claimed was claimed elsewhere first.

L<App::karr::Role::SyncLifecycle/sync_after> takes the command's own writes
back, pulls the other clone's version in, and asks for the run again; this role
wraps C<execute> and runs it once more from the top -- pull, decide, write,
push -- against the board as it is now. Every such command writes its output
after C<sync_after>, so a run that is taken back has printed nothing. Up to
three runs; a board that moves underneath every one of them ends the command
with exit 1 and nothing of it published.

Commands that print per card before their push, ask for confirmation, or
change a card the caller named (C<move>, C<edit>, C<handoff>, C<archive>,
C<delete>) do not compose this role. They stop with exit 1 and name the card
that changed: re-applying a person's change on top of somebody else's, unseen,
is the silent merge the guarded push exists to prevent.

=cut

use constant REAPPLY_RUNS => 3;

sub reapplies_after_stale_push { 1 }

=method reapplies_after_stale_push

Always true. L<App::karr::Role::SyncLifecycle> asks for it to know whether a
command whose push went stale can run again or has to stop.

=cut

around execute => sub {
  my ( $orig, $self, @args ) = @_;
  for my $run ( 1 .. REAPPLY_RUNS ) {
    $self->_stale_reapply(0);
    my @result;
    my $ok = eval { @result = $self->$orig(@args); 1 };
    return wantarray ? @result : $result[-1] if $ok;
    my $err = $@;
    die $err unless $self->_stale_reapply;
  }
  App::karr::Error::user_error(
      "The board kept changing underneath this command; it ran "
    . REAPPLY_RUNS . " times and published nothing.\n"
    . "Run it again once the board is quieter." );
};

1;
