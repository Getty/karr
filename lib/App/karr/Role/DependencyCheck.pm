# ABSTRACT: Warn when a card is taken up while its dependencies are unfinished

package App::karr::Role::DependencyCheck;
our $VERSION = '0.500';
use Moo::Role;

# What this role calls on its consumer, said out loud (ticket #128). It used to
# declare nothing, and got away with it only because every consumer happened to
# compose the roles that supply these: store from
# App::karr::Role::BoardDiscovery, find_task from App::karr::Role::BoardAccess,
# usage_error from App::karr::Role::ExitCodes, quiet from
# App::karr::Role::SyncLifecycle. App::karr::Role::TaskMutation composes this
# role, so the next command to reach for the mutation path would have inherited
# four methods whose collaborators nobody had checked for -- and found out at
# the moment a warning was due, as a "Can't locate object method", rather than
# at compile time.
#
# `json` is the one call dependency_report makes that cannot be listed here.
# App::karr::Cmd::Create composes this role for parse_dependency_ids and
# assert_dependencies_exist alone and has no --json of its own, so requiring it
# would refuse a consumer that never reaches the reporting half. Leaving it out
# still narrows the hole the ticket names: `$self->json || $self->quiet`
# evaluated quiet only when json was false, so a consumer missing quiet broke
# only without --json -- json is evaluated first and unconditionally. Splitting
# the set-time helpers from the reporting half is what would let json in too,
# and that has to touch Create and Pick.
requires qw( store find_task usage_error quiet );

=head1 DESCRIPTION

C<depends_on> was stored, round-tripped and written into the frontmatter by
L<App::karr::Task> long before anything read it. That is worse than a missing
feature: a card recording C<< depends_on: [5] >> looked as though karr would
hold it back until 5 was finished -- the field was accepted, kept and
materialized -- while C<move>, C<edit --status> and C<pick> handed it out with
no word said (ticket #123).

This role is what reads it. Taking a card up with unsatisfied dependencies
B<proceeds and exits 0>, but says so. "Taking up" is a status change into a
non-terminal status, and on C<pick> it is also the claim itself -- an agent
that runs C<< karr pick --claim X >> holds the card and starts on it whether
or not a C<--move> came with it.

Consumed by L<App::karr::Role::TaskMutation>, so every command that changes a
status through C<apply_status_change> is covered by the one call there, and
directly by L<App::karr::Cmd::Pick>, which has its own compare-and-swap loop
and does not go through that path.

=head2 What counts as satisfied

A dependency in one of the board's own terminal statuses
(L<App::karr::Config/is_terminal_status>), never the literal C<done>: a board
whose final column is C<shipped> would otherwise have every finished
dependency reported as outstanding. Same rule as kanban-md's C<allDepsSatisfied>
(F<internal/board/filter.go>:148).

=head2 Which channel it comes out of

The rules L<App::karr::Role::TaskMutation/run_batch> already set for its per-id
errors, rather than a second convention: the human copy goes to STDERR so
STDOUT stays parseable, C<--json> carries the identical sentence in the result
object instead -- a JSON consumer never reads STDERR, so a warning left there
is a warning nobody sees -- and C<--quiet> silences the STDERR copy. The JSON
field is data, not chatter, so C<--quiet> does not remove it; the key is simply
absent when there is nothing to report.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Role::TaskMutation>,
L<App::karr::Cmd::Pick>, L<App::karr::Cmd::Move>, L<App::karr::Cmd::Show>,
L<App::karr::Config>

=cut

# Keyed by task id rather than a flat list, because check_dependencies runs
# inside a compare-and-swap callback that re-runs when another agent gets in
# first (App::karr::Role::TaskMutation/update_task_guarded,
# App::karr::Cmd::Pick/_claim_under_lock). A list would grow one copy of every
# warning per attempt; a keyed slot is replaced by the attempt that wins.
has _dependency_warnings => (
    is      => 'ro',
    default => sub { {} },
);

sub check_dependencies {
    my ( $self, $task, $new_status ) = @_;

    my $id = $task->id;
    delete $self->_dependency_warnings->{$id};

    # A move into a terminal status is not taking work up, it is finishing it,
    # and what a finished card was once waiting for is no longer anybody's
    # decision to make. The board's own statuses answer this, not done/archived
    # (tickets #67, #98).
    return () if $self->store->is_terminal_status($new_status);

    my @deps = @{ $task->depends_on };
    return () unless @deps;

    my @warnings;
    for my $dep_id (@deps) {
        my $dep = $self->find_task($dep_id);

        # A deliberate divergence from the reference. kanban-md treats an id
        # that is not on the board as *satisfied*
        # (internal/board/filter.go:151-154): "Missing dependency IDs can occur
        # after legacy hard-deletes. Treat as satisfied so dependents are
        # recoverable via edit/cleanup." That reasoning is about not stranding a
        # card, and it is sound there, where an unsatisfied dependency makes the
        # card unpickable. Here nothing is blocked, so there is no card to
        # strand -- and a dependency pointing at an id that does not exist is
        # exactly the kind of thing whoever is about to start work wants told.
        if ( !$dep ) {
            push @warnings, sprintf
              'Warning: task %s depends on task %s, which does not exist on this board',
              $id, $dep_id;
            next;
        }

        next if $self->store->is_terminal_status( $dep->status );
        push @warnings, sprintf
          'Warning: task %s depends on task %s, which is still %s',
          $id, $dep_id, $dep->status;
    }

    $self->_dependency_warnings->{$id} = \@warnings if @warnings;
    return @warnings;
}

=method check_dependencies

    $self->check_dependencies( $task, $new_status );

Records, for C<< $task->id >>, one warning per dependency that is not finished
and one per dependency naming an id the board does not have. Returns the
warnings and stashes them for L</dependency_report> to emit; it prints nothing
and changes nothing itself, which is what makes it safe to call from inside a
compare-and-swap callback that may run more than once.

A C<$new_status> that is terminal for this board, or a task with no
C<depends_on>, records nothing. Call it with the status the task is moving
B<to>, not the one it is moving from -- or, where nothing is moving and the
card is merely being taken up (C<< karr pick --claim >> with no C<--move>),
with the status it stays in.

=cut

# The set-time half of the ticket pair (#124, gated on the CLI route existing;
# the move-time warning above is #123). kanban-md does both too
# (ValidateDependencyIDs, internal/task/validate.go:155) -- set-time catches a
# typo while the author still remembers what they meant, move-time catches
# state that changed afterwards, which set-time can never see.
#
# Both rejections here condemn the whole invocation rather than one id of a
# batch: a malformed or unknown dependency id is wrong for every id at once, so
# it is a usage error (exit 2) raised before anything is written -- ticket #54's
# rule, the same reason Cmd::Create runs them before allocating an id. The one
# per-id case, a self-reference, cannot live here: which id is "self" differs
# per batch id, so the caller checks it inside its batch loop (#61).
sub parse_dependency_ids {
    my ( $self, $flag, $value ) = @_;
    my ( @ids, %seen );
    for my $raw ( split /,/, $value ) {
        $self->usage_error(
            qq{invalid $flag id "$raw" (ids are comma-separated numbers)} )
            unless $raw =~ /\A[0-9]+\z/;
        # Numified on purpose: YAML::XS and JSON::MaybeXS both encode by the
        # scalar's own type, so a string "2" would round-trip as '2' / "2" --
        # which go-yaml refuses to unmarshal into kanban-md's IntSlice. Same
        # care run_batch takes when echoing batch ids. Deduplicated here, once
        # for every flag, so `--depends-on 2,2` cannot store [2,2]: a repeated
        # id carries no meaning in any of the three flags, and edit's
        # append-unique only guards against ids the card already carries.
        push @ids, $raw + 0 unless $seen{ $raw + 0 }++;
    }
    $self->usage_error("$flag requires at least one id") unless @ids;
    return \@ids;
}

=method parse_dependency_ids

    my $ids = $self->parse_dependency_ids( '--depends-on', $self->depends_on );

Splits a comma-separated dependency option value into an arrayref of numeric
ids, in order, duplicates collapsed. A value that is not a plain number is a
usage error naming the flag and the value, raised before any task is touched
-- it condemns the invocation, never one id of a batch. The ids are returned
as numbers so they round-trip numerically through the frontmatter and
C<--json> (kanban-md models the field as an C<IntSlice>).

=cut

sub assert_dependencies_exist {
    my ( $self, $ids ) = @_;
    for my $dep_id (@$ids) {
        $self->usage_error(
            "dependency task $dep_id does not exist on this board" )
            unless $self->find_task($dep_id);
    }
    return $ids;
}

=method assert_dependencies_exist

    $self->assert_dependencies_exist($ids);

Usage error unless every id names a task on this board, archived included --
the same L<App::karr::Role::BoardAccess/find_task> lookup
L</check_dependencies> resolves ids with, so set-time and move-time can never
disagree about what exists. Called with ids that are about to be B<added>;
removing an id the board no longer has must stay legal, because that is how a
dependency on a deleted task is cleaned up.

=cut

sub dependency_report {
    my ( $self, $id ) = @_;

    my $warnings = $self->_dependency_warnings->{$id};
    return () unless $warnings && @$warnings;

    print STDERR map { "$_\n" } @$warnings
      unless $self->json || $self->quiet;

    return ( dependency_warnings => $warnings );
}

=method dependency_report

    return { id => $task->id, ..., $self->dependency_report( $task->id ) };

Emits whatever L</check_dependencies> recorded for C<$id> and returns it as the
C<< dependency_warnings => \@warnings >> pair for the command's C<--json>
payload, or the empty list when there is nothing to report -- so the key is
absent rather than an empty array a consumer would have to test the length of.

Emitting and reporting are one call on purpose: they are the same warning on
two channels, and splitting them is how the two drift apart. STDERR is skipped
under C<--json> (where the pair carries it) and under C<--quiet>.

Call it after the write has landed, never from inside the guarded callback: a
warning about a move that then lost its compare-and-swap is a warning about
something that did not happen.

=cut

1;
