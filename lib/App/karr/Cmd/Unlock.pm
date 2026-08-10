# ABSTRACT: Show and break task pick locks

package App::karr::Cmd::Unlock;
our $VERSION = '0.403';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr unlock [ID[,ID,...]] [--all] [--json]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Lock;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output', 'App::karr::Role::ClaimTimeout';

=head1 SYNOPSIS

    karr unlock
    karr unlock 12
    karr unlock 12,14 --json
    karr unlock --all

=head1 DESCRIPTION

Shows the C<karr pick> locks currently held on the board, and breaks them on
request.

Run with no arguments it only reports: one line per lock with the task it
covers, the identity holding it, how long it has been held, and whether that is
past the board's C<lock_timeout>. Nothing is destroyed unless a task id or
C<--all> is given.

=head1 WHY THIS EXISTS

C<karr pick> takes a lock ref, claims a card, and gives the lock back inside one
command, so under normal use there is nothing here to see. An agent that dies in
between -- killed mid-run, or a push that failed and aborted the command -- left
one behind, and before #45 that ref was permanent: no command could clear it,
C<karr delete> could not reach it, and every other agent skipped that task
forever. Digging the board out took a C<git update-ref -d> by hand.

Locks now expire on their own (C<lock_timeout>, default C<5m>), which is what an
unattended agent needs. This command is the other half: the way a human sees
what is stuck and clears it now instead of waiting, and the only way out at all
on a board that has set C<lock_timeout> to C<0s>.

Breaking a lock is safe by construction: it is not what makes a pick exclusive.
The claim is written under a compare-and-swap on the card itself
(L<App::karr::Cmd::Pick/EXCLUSIVITY>), so an agent whose lock is broken out from
under it mid-pick either completes its claim untouched or loses that swap to
whoever got there first. It can never overwrite somebody else's claim.

=head1 OPTIONS

=over 4

=item * C<--all>

Break every lock on the board instead of named ones.

=item * C<--json>

Emit the locks, or the results of breaking them, as JSON.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Pick>, L<App::karr::Lock>,
L<App::karr::Cmd::Config>

=cut

option all => (
  is  => 'ro',
  doc => 'Break every lock on the board',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->check_positional_args($args_ref, 1);

  # Pull first: a lock pushed by a command that died before it could release
  # one is on the remote, and this is the command for exactly that mess. The
  # guard is disarmed on the reporting path below, which writes nothing.
  my $guard = $self->sync_before;

  my $ec = $self->store->effective_config;
  my $lock = App::karr::Lock->new(
    git => $self->git,
    ttl => $self->_parse_timeout($ec->{lock_timeout},
                                 App::karr::Lock->DEFAULT_TTL),
  );

  my @pos = $self->positional_args($args_ref);
  my @held = $lock->locks;

  # No target: report only. Clearing a lock is destructive to whoever holds it,
  # so it takes an explicit id or --all.
  unless ($self->all || defined $pos[0]) {
    $guard->done;
    $self->_report(@held);
    return;
  }

  my @ids = $self->all ? map { $_->{task_id} } @held
                       : $self->parse_ids($pos[0]);

  my @results;
  for my $id (@ids) {
    my ($ok, $owner) = $lock->break_lock($id);
    push @results, {
      id      => 0 + $id,
      broken  => $ok ? \1 : \0,
      ( $ok ? ( owner => $owner ) : () ),
    };
    next if $self->json;
    if ($ok) { printf "Broke lock on task %d (was held by %s)\n", $id, $owner }
    else     { printf "Task %d is not locked\n", $id }
  }

  $self->sync_after;

  $self->print_json_results(@results);
}

sub _report {
  my ($self, @held) = @_;

  if ($self->json) {
    $self->print_json([ map { { %$_, expired => $_->{expired} ? \1 : \0 } } @held ]);
    return;
  }

  unless (@held) {
    print "No locks held.\n";
    return;
  }

  for my $l (@held) {
    printf "Task %-4d held by %s%s%s\n",
      $l->{task_id},
      $l->{owner},
      ( defined $l->{age} ? sprintf( ' for %s', _duration( $l->{age} ) ) : '' ),
      ( $l->{expired} ? ' [expired]' : '' );
  }
  print "\nBreak one with 'karr unlock ID', or all of them with 'karr unlock --all'.\n";
}

sub _duration {
  my ($secs) = @_;
  return "${secs}s" if $secs < 60;
  return int( $secs / 60 ) . 'm' if $secs < 3600;
  return int( $secs / 3600 ) . 'h';
}

1;
