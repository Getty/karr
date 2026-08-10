# ABSTRACT: The one guarded path for changing an existing task

package App::karr::Role::TaskMutation;
our $VERSION = '0.403';
use Moo::Role;
use Time::Piece;
use App::karr::Task;
use App::karr::Config;
use App::karr::Role::ClaimTimeout;

with 'App::karr::Role::ClaimTimeout';

=head1 DESCRIPTION

Commands that change a task that already exists -- C<move>, C<edit>, C<delete>
-- share two things through this role: the compare-and-swap loop that persists
the change, and the single implementation of "this task's status becomes that".

Claim ownership is checked by the caller, inside the callback it hands to
C<update_task_guarded>, rather than by C<update_task_guarded> itself, because
C<edit --release> deliberately acts on somebody else's claim. Putting the check
in the callback is what keeps it under the same guard as the write: a check
made before the loop is a check made against a revision that may no longer be
there (tickets #44, #46, #56).

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Role::ClaimTimeout>,
L<App::karr::Cmd::Move>, L<App::karr::Cmd::Edit>, L<App::karr::Cmd::Delete>

=cut

# The canonical location of a task. BoardStore and App::karr::Git build the
# same string; this role needs it directly because it reads the OID and the
# content together (App::karr::Git::read_ref_with_oid), which is the pair a
# compare-and-swap has to guard against, and no BoardStore method hands both
# back.
sub _task_data_ref {
    my ($self, $id) = @_;
    return "refs/karr/tasks/$id/data";
}

sub update_task_guarded {
    my ($self, $id, $mutate) = @_;
    my $git = $self->git;
    my $ref = $self->_task_data_ref($id);

    return $git->retry_contended( "task $id", sub {
        my ( $oid, $content ) = $git->read_ref_with_oid($ref);
        die "Task $id not found\n" unless defined $oid && length $content;

        my $task = App::karr::Task->from_string( $content,
            repair_frontmatter => $git->board_is_legacy_encoded );

        $mutate->($task);

        # What BoardStore::save_task does centrally for the unguarded path: an
        # existing task gets a fresh `updated` on every mutation. The ref was
        # just read, so it exists by definition and the stamp is unconditional.
        $task->updated( gmtime->datetime . 'Z' );

        return () unless $git->write_ref_cas( $ref, $task->to_markdown, $oid );
        return $task;
    } );
}

=head2 update_task_guarded

Reads the task, runs the callback against it, and writes it back only if the
task ref is still exactly where it was when it was read. If another agent got
in first the callback's work is discarded and the callback is re-run against
the fresh task, so the decision it makes and the bytes that land are always the
same revision. Returns the written task.

    my $task = $self->update_task_guarded( $id, sub {
        my ($task) = @_;
        $self->check_claim( $task, $self->claim );
        $task->title('New title');
    } );

The callback runs once per attempt, so it must be a function of the task it is
handed -- read C<< $task->status >>, never a status captured beforehand -- and
it must not have side effects outside the task object.

=cut

# Deleting has no compare-and-swap equivalent: karr's App::karr::Git::delete_ref
# goes through libgit2's git_reference_remove(repo, name), which takes no
# expected-old OID. (The guarded form exists -- git_reference_delete on a looked
# up reference fails if the ref moved since the lookup -- but wiring it through
# is App::karr::Git's lane, not this role's.)
#
# So this re-reads the task and re-applies the claim rule immediately before the
# delete. That closes the window that actually matters, the one that can stay
# open for minutes while a confirmation prompt waits for a human, and leaves
# only the microseconds between this read and the remove. Not atomic; smaller
# than it was.
sub delete_task_guarded {
    my ($self, $id, $claimant) = @_;
    my $task = $self->find_task($id);
    die "Task $id not found\n" unless $task;
    $self->check_claim( $task, $claimant );
    return $self->delete_task($id);
}

=head2 delete_task_guarded

Re-reads the task, re-applies the claim rule, and deletes it. Not atomic --
see the note above the implementation.

=cut

# One status-change path, because there used to be two: `karr move` enforced
# require_claim and stamped the lifecycle dates, while `karr edit --status` just
# assigned the field. So `edit --status in-progress` quietly bought what `move
# 1 in-progress` refused to sell, and require_claim -- the guarantee karr's
# whole multi-agent coordination rests on -- was one flag away from being
# optional (ticket #55).
#
# The require_claim condition is move's, unchanged: a claim passed on the
# command line satisfies it, and so does a claim the task already carries.
#
# Being the one status-change path, this is also where the status *name* is
# checked (ticket #54) and where the lifecycle stamps are maintained (ticket
# #68) -- both for `move` and for `edit --status`.
sub apply_status_change {
    my ($self, $task, $new_status, $claimant) = @_;

    # First, so a batch dies on its first id having written nothing: the check
    # runs inside update_task_guarded's callback, and a die there means the
    # compare-and-swap write is never reached. `move 1 ZZZ` and `edit 1
    # --status ZZZ` used to exit 0 and park the task in a column that does not
    # exist -- invisible on `karr board`, still in the total, and fatal to the
    # next `karr move --next`.
    my $config = App::karr::Config->from_merged( $self->store->effective_config );
    $config->validate_status($new_status);

    die "Status '$new_status' requires --claim\n"
        if $self->store->status_requires_claim($new_status)
        && !( defined $claimant && length $claimant )
        && !$task->has_claimed_by;

    my $old_status = $task->status;
    $task->status($new_status);
    # The lifecycle rules themselves live on the task, mirroring kanban-md's
    # internal/task/lifecycle.go: `started` on the first move out of the first
    # configured status, `completed` on any terminal status, and `completed`
    # cleared again when a task is reopened.
    $task->update_timestamps( $old_status, $new_status, ( $config->statuses )[0] );

    return $old_status;
}

=head2 apply_status_change

The only place a task's status is assigned. Rejects a status the board does not
configure, applies C<require_claim> and the lifecycle stamps, and returns the
status the task had before the change.

    my $old_status = $self->apply_status_change( $task, 'in-progress', $claimant );

=cut

1;
