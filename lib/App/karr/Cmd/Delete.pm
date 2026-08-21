# ABSTRACT: Delete a task

package App::karr::Cmd::Delete;
our $VERSION = '0.501';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr delete ID[,ID,...] [--yes] [--json]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Role::TaskMutation;
use App::karr::Task;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output',
     'App::karr::Role::TaskMutation';

=head1 SYNOPSIS

    karr delete 9
    karr delete 9,10,11 --yes
    karr delete 9 --json

=head1 DESCRIPTION

Permanently removes one or more tasks' refs from the board. This is the
destructive alternative to L<App::karr::Cmd::Archive>, which only changes the
status to C<archived>.

=head1 OPTIONS

=over 4

=item * C<--yes>

Skips the interactive confirmation prompt for each task. Required whenever
nothing will answer that prompt: if stdin is not a terminal and carries no
answer, the command refuses rather than guessing.

=back

=head1 CLAIMS

A task with a live claim is not deleted, whoever holds it. Release the claim
with C<< karr edit ID --release >> or wait for C<claim_timeout> to expire it.

=head1 DEPENDENTS

Before an id is removed the board is searched for the cards that point at it --
a C<depends_on> entry naming it, or C<parent> set to it -- and each one is named
on STDERR as a C<Warning:>, offering C<karr archive> as the way to keep the card
instead. The delete then proceeds: karr warns about dependencies rather than
blocking on them (L<App::karr::Role::DependencyCheck>), and this warning exists
to send a caller from the destructive way to the soft one, not to refuse them
the destructive one.

It comes before the confirmation prompt, so it can still change the answer, and
it comes under C<--yes> as well, which is the mode agents delete in. C<--json>
carries the identical sentences as C<dependent_warnings> in the result object
instead, and C<--quiet> silences the STDERR copy.

The search is board-local. A card on another board waiting on this one through
a C<needs:> link (L<App::karr::CrossBoard>) cannot be seen from here; C<karr
needs> reports such a link as missing once the card is gone.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Archive>,
L<App::karr::Cmd::Backup>, L<App::karr::Cmd::Destroy>

=cut

option yes => (
  is => 'ro',
  short => 'y',
  doc => 'Skip confirmation',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->check_positional_args($args_ref, 1);

  $self->sync_before;
  $self->require_board;

  my @pos = $self->positional_args($args_ref);
  my $id_str = $pos[0] or die "Usage: karr delete ID[,ID,...] [--yes] [--json]\n";
  # See the note in Cmd::Move: a comma with no ids around it is truthy here and
  # splits to nothing, so the command used to exit 0 having done nothing --
  # which on a delete reads as "deleted", and is the worst possible place for
  # that ambiguity.
  my @ids = $self->parse_ids($id_str);
  die "Usage: karr delete ID[,ID,...] [--yes] [--json]\n" unless @ids;

  # Every id is attempted, whatever the ones before it did. A missing id used to
  # die from inside this loop, which on delete was the worst version of the bug
  # in ticket #61: the ids already removed locally never reached sync_after, so
  # the batch reported failure with the remote still holding cards karr had
  # deleted.
  my ($results, $failed) = $self->run_batch(\@ids, sub {
    my ($id) = @_;

    my $task = $self->find_task($id);
    die "Task $id not found\n" unless $task;

    # A live claim blocks the delete whoever holds it -- an empty claimant, the
    # way kanban-md's cmd/delete.go calls CheckClaim. Neither implementation
    # gives delete a --claim option, so releasing the claim (or letting it
    # expire) is the way through, for the holder as much as for anybody else.
    $self->check_claim($task, undef);

    # Before the confirmation, never after it. The point of the warning is that
    # it can still change the answer, and the operator who reads it and types
    # "n" is the one it worked on -- so it deliberately does not wait for the
    # write the way App::karr::Role::DependencyCheck/dependency_report waits for
    # its own. That rule ("a warning about a move that then lost its
    # compare-and-swap is a warning about something that did not happen") is
    # about a card that survives to be read afterwards. Here the write is what
    # removes the card, so a warning that waits for it is a warning about
    # something nobody can choose to keep any more.
    #
    # Under --yes there is no prompt to precede and it comes anyway: --yes is
    # the mode agents delete in, so a warning only on the interactive path warns
    # exactly where nobody is left to read it.
    my @dependents = $self->_dependent_warnings($task);
    # The channel App::karr::Role::DependencyCheck argues for one module over,
    # rather than a third convention: the human copy on STDERR so STDOUT stays
    # parseable, --quiet silencing that copy, and --json carrying the identical
    # sentence in the result object below because a JSON consumer never reads
    # STDERR.
    print STDERR map { "$_\n" } @dependents
      unless $self->json || $self->quiet;
    my @dependent_report = @dependents ? ( dependent_warnings => \@dependents ) : ();

    unless ($self->yes) {
      printf "Delete task %d: %s? [y/N] ", $task->id, $task->title;
      my $answer = <STDIN>;

      # <STDIN> returns undef at EOF, and karr used to run straight on into
      # `chomp $answer` -- two "Use of uninitialized value $answer" warnings on
      # stderr, then "Skipped task 2: d", for every agent or CI run that forgot
      # --yes (ticket #73). What the right answer to a non-answer is depends on
      # where stdin came from:
      #
      #   a terminal   the user pressed Ctrl-D. That is "no": skip the task and
      #                exit 0, the same as typing n, and now without warnings.
      #
      #   anything else  nobody is there and nobody will be, so there is no
      #                point pretending the prompt happened. Refuse and say what
      #                to do, the way karr's other destructive commands refuse
      #                without --yes and the way kanban-md refuses when
      #                term.IsTerminal is false.
      #
      # An answer that *is* there is honoured either way, so piping "y" or "n"
      # into `karr delete` keeps working.
      die "No answer on stdin and stdin is not a terminal. Re-run with --yes.\n"
        if !defined $answer && !-t STDIN;

      $answer = '' unless defined $answer;
      chomp $answer;
      unless ($answer =~ /^y/i) {
        # Answering "n" is an answer, not a failure: the batch carries on and
        # the command still exits 0 if nothing else went wrong.
        printf "Skipped task %d: %s\n", $task->id, $task->title unless $self->json;
        # The dependents ride along on a card that was kept, too. Under --json
        # the pair is the warning's only channel, and this is the case the
        # warning was for: `deleted => false` sits beside it and says plainly
        # that the delete it named did not happen.
        return { id => $task->id, title => $task->title, deleted => \0,
                 @dependent_report };
      }
    }

    $self->delete_task_guarded($task->id, undef);
    printf "Deleted task %d: %s\n", $task->id, $task->title unless $self->json;
    # Reported here and not before the prompt, because a card the operator
    # answered "n" for had its claim examined but not overridden. The two
    # check_claim calls on this path -- the one above and the one inside
    # delete_task_guarded -- record into the same slot, so this is still one
    # line (#177). Deleting the card is also the one case where nothing survives
    # to be read afterwards, which is what makes the trace matter most here.
    return { id => $task->id, title => $task->title, deleted => \1,
             @dependent_report,
             $self->expired_claim_report( $task->id ) };
  });

  $self->sync_after;

  $self->print_json_results(@$results);

  $self->report_batch_failure($failed, scalar @ids);
}

# The backward search kanban-md runs before a delete (board.FindDependents,
# internal/board/board.go:53-72), which karr had no counterpart for: the claim
# check was the only thing between `karr delete 2` and card 6 keeping a
# depends_on pointing at an id the board no longer has (#236). karr already
# *shows* that damage -- `karr show 6` renders "2 (unknown)" through
# Cmd::Show::_dependency_label -- so the information existed; it simply arrived
# after the last moment anybody could act on it.
#
# It warns and deletes, as the reference does. Refusing would make a hard delete
# depend on cards the operator may not care about, and karr answers the whole
# depends_on family by warning rather than blocking (App::karr::Role::
# DependencyCheck, #123). What the warning is *for* here is the door karr has
# and kanban-md does not: `karr archive` keeps the ref, so the dependency still
# resolves and `show` labels it `archived` instead of `unknown`. Naming that
# command is the difference between reporting damage and preventing it.
#
# `parent` is checked beside depends_on, as it is over there. No karr command
# sets it (App::karr::Task) so on a karr-native board the branch never fires --
# but `karr import` brings the field in from a kanban-md board and Task keeps
# it, and unlike a dependency nothing in karr ever renders it afterwards, so
# this is the only place an orphaned child would be named at all. The cost is a
# comparison over a list this method already holds.
#
# Deliberately board-local, and not only because it is cheap that way: a card on
# another board waiting on this one through a `needs:` link
# (App::karr::CrossBoard) is invisible from here, because reading the far board
# needs a path this command does not have and must not invent -- the same line
# App::karr::Role::DependencyCheck draws for the cross-board half of its own
# warning. `karr needs` reports such a link as `missing` once the card is gone.
#
# Re-read per id rather than once for the batch: `karr delete 6,2` should not
# warn that 6 depends on 2 after 6 itself has been deleted, so each id is asked
# about the board as it stands when its turn comes.
sub _dependent_warnings {
  my ($self, $task) = @_;

  my $id = $task->id;
  # Frontmatter carries whatever the document said, so only values that are ids
  # at all are compared: `depends_on: [abc]` is a hand-edited card, not a
  # dependent, and `==` on it would add "Argument isn't numeric" to the output
  # of a delete -- the same care run_batch takes when echoing a non-numeric
  # batch id.
  my $names_id = sub {
    my ($value) = @_;
    return 0 unless defined $value && $value =~ /\A[0-9]+\z/;
    return $value + 0 == $id ? 1 : 0;
  };

  my @warnings;
  # load_tasks is already in ascending id order (App::karr::BoardStore).
  for my $other ($self->load_tasks) {
    next if $other->id == $id;
    push @warnings, sprintf
      'Warning: task %d (%s) depends on task %d, which is being deleted '
      . '(use "karr archive %d" to keep the card)',
      $other->id, $other->title, $id, $id
      if grep { $names_id->($_) } @{ $other->depends_on };
    push @warnings, sprintf
      'Warning: task %d (%s) has task %d as its parent, which is being deleted '
      . '(use "karr archive %d" to keep the card)',
      $other->id, $other->title, $id, $id
      if $names_id->( $other->parent );
  }
  return @warnings;
}

1;
