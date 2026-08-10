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

        # Through the role's own door rather than straight at write_ref_cas:
        # BoardAccess::save_task is where the `updated` bump and the activity
        # log entry live for every command write, guarded or not, and reaching
        # past it is what dropped move and edit out of `karr log` (#64).
        return () unless $self->save_task( $task, $oid );
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

# The same shape as update_task_guarded, and for the same reason: the claim rule
# is applied to the revision the delete is guarded against, so the two can never
# be about different bytes.
#
# This used to re-read the task and delete by name, because karr had no guarded
# delete to reach for -- App::karr::Git::delete_ref goes through libgit2's
# git_reference_remove(repo, name), which takes no expected-old OID. Re-reading
# closed the window that can stay open for minutes behind a confirmation prompt
# and left the microseconds between the read and the remove, in which a claim
# landing on the card was deleted along with it. App::karr::Git::delete_ref_cas
# closes that one too (#94).
sub delete_task_guarded {
    my ($self, $id, $claimant) = @_;
    my $git = $self->git;
    my $ref = $self->_task_data_ref($id);

    my $task = $git->retry_contended( "task $id", sub {
        my ( $oid, $content ) = $git->read_ref_with_oid($ref);
        die "Task $id not found\n" unless defined $oid && length $content;

        my $found = App::karr::Task->from_string( $content,
            repair_frontmatter => $git->board_is_legacy_encoded );
        $self->check_claim( $found, $claimant );

        return () unless $git->delete_ref_cas( $ref, $oid );
        return $found;
    } );

    # L<App::karr::Role::BoardAccess/delete_task> is the activity-log funnel for
    # the unguarded path; this one writes the ref itself, so it records the same
    # entry rather than going without one (#64).
    $self->log_task_write($id);
    return $task;
}

=head2 delete_task_guarded

Deletes a task, but only if the task ref is still exactly where it was when the
claim rule was applied to it. If another agent got in first the check is re-run
against the fresh task -- so a claim that lands in the window blocks the delete
instead of being deleted with the card -- and a task another agent deleted
meanwhile is reported as not found. Returns the deleted task.

    $self->delete_task_guarded( $id, undef );

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
