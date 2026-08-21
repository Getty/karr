# ABSTRACT: The one definition of which card karr pick may hand out, and in what order

package App::karr::Role::PickRules;
our $VERSION = '0.501';
use Moo::Role;
use App::karr::Config;

=head1 DESCRIPTION

Two things decide what C<karr pick> hands an agent: whether a card is available
at all, and which of the available ones comes first. Both were written twice --
once in L<App::karr::Cmd::Pick> and once in L<App::karr::Foundation::Picker>,
which has to name the card the agent's own C<karr pick> would have handed it or
the coordinator is arguing with its own board. They agreed because they were
copied; nothing kept them agreeing (ticket #198).

This role is the definition both call. It lives in a role rather than in
L<App::karr::Task> or L<App::karr::BoardStore> because the eligibility test
needs three things at once: the task, the board (C<< $self->store >> for the
board's terminal statuses and its C<priorities>/C<classes> lists), and the
claim-expiry parser in L<App::karr::Role::ClaimTimeout> -- which this role
composes, so a consumer gets the whole rule by asking for one name. A function
in C<Task> would have had to be handed all three; a method on C<BoardStore>
would have put command-selection policy in the storage layer, which belongs to
a different owner.

What is deliberately B<not> here: claiming, locking and the compare-and-swap
that binds a pick (L<App::karr::Cmd::Pick/EXCLUSIVITY>), because foundation
must not do any of them (L<App::karr::Foundation::Picker>), and the C<--status>
and C<--tags> option parsing, which stays with the command that has options.
This role takes the filters already split, applies them, and stops.

Unmet dependencies are not filtered anywhere in here, matching C<karr pick>:
nothing about C<depends_on> blocks anything in karr, the command hands the card
over and warns (ticket #123).

=cut

# Composed, not required: claim expiry is half the eligibility rule, and its
# RFC3339 parser exists once (App::karr::Role::ClaimTimeout, ticket #57). A
# consumer that also composes ClaimTimeout itself -- App::karr::Cmd::Pick does,
# for the separate lock_timeout parse -- is applying the same role twice, which
# Role::Tiny resolves to one application rather than a method conflict.
with 'App::karr::Role::ClaimTimeout';

sub pickable {
    my ( $self, $task, %filter ) = @_;
    return 0 unless $task;

    my $timeout = defined $filter{timeout} ? $filter{timeout} : $self->claim_timeout_secs;

    if ( $filter{statuses} ) {
        my %allowed = map { $_ => 1 } @{ $filter{statuses} };
        return 0 unless $allowed{ $task->status };
    }
    else {
        # The board's own terminal status, not a hardcoded 'done': a board
        # imported from kanban-md can end in `shipped`, and pick used to hand
        # those finished cards straight back out (ticket #67).
        return 0 if $self->store->is_terminal_status( $task->status );
    }

    # `claimed_by: ""` means unclaimed. kanban-md's omitempty writes the key
    # only when it is non-empty, but a card it read and rewrote -- or any
    # hand-written one -- can carry the empty string, and Moo's predicate calls
    # that "set". So every imported kanban-md card looked as though somebody
    # held it, and pick reported an empty board while `karr list` showed the
    # work sitting there (ticket #59).
    # This is the same emptiness test App::karr::Role::ClaimTimeout/check_claim
    # already applies; the two have to agree or a task pick refuses is a task
    # move happily accepts.
    return 0
      if $task->has_claimed_by
      && length $task->claimed_by
      && !$self->_claim_expired( $task, $timeout );
    return 0 if $task->has_blocked;

    if ( $filter{tags} ) {
        my %wanted = map { $_ => 1 } @{ $filter{tags} };
        return 0 unless grep { $wanted{$_} } @{ $task->tags };
    }

    return 1;
}

=method pickable

    $self->pickable( $task );
    $self->pickable( $task, timeout => $secs, statuses => \@s, tags => \@t );

True when C<$task> is available to be picked right now. In order: it exists;
its status is in C<statuses> if that filter was given, and is not one of the
board's terminal statuses if it was not (the board's own final column and
C<archived>, never a hardcoded C<done>); it is not held by a claim that is
still live under C<timeout>, where C<claimed_by> set to the empty string is
kanban-md for "unclaimed"; it is not blocked; and it carries at least one of
C<tags> if that filter was given.

C<timeout> is the claim window in seconds and defaults to
L<App::karr::Role::ClaimTimeout/claim_timeout_secs>. Pass it explicitly when
asking about many cards in one command run, so one answer covers the whole
run. C<0> is not the shortest window but no window at all: a board with
C<claim_timeout: 0s> never expires a claim, so every claimed card stays
unpickable until the claim is released. C<statuses> and C<tags> are
already-split lists, not the comma-separated option strings -- splitting
belongs to the command that owns the option. An absent (or empty) filter is
not the same as an empty list: no C<statuses> means "anything but terminal",
C<< statuses => [] >> means nothing qualifies.

=cut

sub pick_rank {
    my ( $self, @tasks ) = @_;

    # Both axes are driven by the board's configured lists -- not by a
    # hardcoded table that only knew the four default priorities and classes.
    # A board imported from kanban-md can name anything (ticket #149: a
    # `blocker` priority beat a `critical` one on a non-default board); ranking
    # against the hardcoded table gave the wrong card out while
    # `karr list --sort priority` showed the right one right next to it.
    #
    # Convention, matching kanban-md's pick.go: lower class index = more urgent
    # class; higher priority index = more urgent priority. So the sort key for
    # priority is `(max - priority_index)` -- most-urgent-last in the config
    # list comes out first. A priority the board does not list at all sorts
    # below every listed one; an unlisted class sorts with `standard`.
    #
    # Between class and priority sits kanban-md's one exception, and it is not
    # a general due-date rule: only where both cards carry `fixed-date` does
    # the date come first (ticket #233).
    my $cfg        = App::karr::Config->from_merged( $self->store->effective_config );
    my @priorities = $cfg->priorities;
    my @classes    = $cfg->classes;
    my %pri_idx; $pri_idx{ $priorities[$_] } = $_ for 0 .. $#priorities;
    my %cls_idx; $cls_idx{ $classes[$_] }    = $_ for 0 .. $#classes;
    my $max_pri     = $#priorities;
    my $std_cls_idx = $cls_idx{standard} // 0;

    return sort {
        ( ( $cls_idx{ $a->class } // $std_cls_idx ) <=> ( $cls_idx{ $b->class } // $std_cls_idx ) )
          || $self->_fixed_date_due_cmp( $a, $b )
          || ( ( $max_pri - ( $pri_idx{ $a->priority } // -1 ) )
            <=> ( $max_pri - ( $pri_idx{ $b->priority } // -1 ) ) )
          || $a->id <=> $b->id
    } @tasks;
}

=method pick_rank

    my @ranked = $self->pick_rank( @tasks );

C<karr pick>'s order: class of service first, then priority, then task id. Both
lists come from the board's own C<priorities> and C<classes> config, so a board
imported from kanban-md ranks by its own names (ticket #149). Lower class index
is more urgent, higher priority index is more urgent -- kanban-md's convention,
from its F<pick.go>. The id tie-break makes the order total, so the first
element is well defined however the sort was reached.

One class breaks that order, and only against itself: where B<both> cards are
C<fixed-date>, the due date decides before priority is asked (ticket #233).
Earlier due first; a C<fixed-date> card with no due date sorts behind every
dated one; where neither card is dated, or both are due on the same day,
priority decides as usual. Against any other class -- and between two cards of
any other class -- C<due> is not read at all: a C<fixed-date> card meeting an
C<expedite> or a C<standard> one is ranked by class index alone, however soon
either of them is due. This is kanban-md's exception in
C<sortPickCandidates>/C<compareDue>, and it is the class of service that exists
because a date, not an urgency rating, decides.

=cut

# kanban-md's sortPickCandidates asks the due date only when both candidates
# are `fixed-date` -- the class of service whose whole point is that a date,
# not an urgency rating, decides. Against any other class (and between two
# cards of any other class) the class index and then priority decide exactly as
# before, so this returns 0 and the chain above carries on.
#
# The ordering within the exception is kanban-md's compareDue
# (internal/board/sort.go): earlier date first, a card with no due date last --
# not first and not level -- and two cards it cannot separate (neither dated,
# or both dated the same day) fall through to priority.
#
# `has_due` is the whole emptiness test: L<App::karr::Task/BUILD> normalizes a
# `due:` that is present but empty back to unset on the parse path, so nothing
# reaches here has_due-true-but-blank (ticket #98). Dates are the bare
# `YYYY-MM-DD` kanban-md's date.Date accepts and karr validates
# (L<App::karr::Config/validate_due>), so a string compare is chronological.
sub _fixed_date_due_cmp {
    my ( $self, $left, $right ) = @_;

    # A card with no class at all is not fixed-date, the same way kanban-md's
    # empty-string class is not.
    my $fixed = App::karr::Config->FIXED_DATE_CLASS;
    return 0
      unless ( $left->class // '' ) eq $fixed
      && ( $right->class // '' ) eq $fixed;

    my $l = $left->has_due  ? $left->due  : undef;
    my $r = $right->has_due ? $right->due : undef;
    return 0 unless defined $l || defined $r;
    return 1 unless defined $l;
    return -1 unless defined $r;
    return $l cmp $r;
}

sub pick_candidates {
    my ( $self, $tasks, %filter ) = @_;
    return $self->pick_rank( grep { $self->pickable( $_, %filter ) } @$tasks );
}

=method pick_candidates

    my @ranked = $self->pick_candidates( [ $self->load_tasks ], %filter );

L</pickable> and L</pick_rank> in one call: every eligible task, most urgent
first. C<karr pick> walks the whole list, because a candidate can still be lost
to another agent's lock or compare-and-swap; L<App::karr::Foundation::Picker>
takes the first and stops.

The list is a ranking, not a decision -- nothing here reads a card under a lock
and nothing writes. See L<App::karr::Cmd::Pick/EXCLUSIVITY> for what has to
happen on top before a pick is binding.

=cut

1;
