# t/229-context-only-archived-excluded.t
#
# Ticket #229: `karr context` dropped every terminal card from the list it
# summarises, under a comment that said "Exclude archived from all operations".
# The comment described kanban-md's rule (cmd/context.go filters with
# cfg.IsArchivedStatus, and that is `s == "archived"`); the code carried out a
# wider one, so on the default board `done` disappeared too. The narrowing was
# not a decision: the initial release filtered `$_->status ne 'archived'`, and
# the "use is_terminal_status() throughout" sweep in 85f6e9f widened it while
# claiming only to centralize config knowledge.
#
# Two reported values move with that list -- the header total and the blocked
# count/section -- and both are pinned here. The three that must NOT move
# (active, overdue, and the In Progress section) re-test the terminal status
# themselves, so they are pinned too: this file is only correct if it fails on
# the old filter and on a fix that overshoots into them.

use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Time::Piece;
use JSON::MaybeXS qw( decode_json );

use App::karr::Config;
use App::karr::Task;
use App::karr::Cmd::Context;
use MockStore;

sub mk {
  my (%a) = @_;
  my $t = App::karr::Task->new(
    id       => $a{id},
    title    => $a{title},
    status   => $a{status},
    priority => $a{priority} // 'medium',
    class    => 'standard',
  );
  $t->due( $a{due} )             if defined $a{due};
  $t->completed( $a{completed} ) if defined $a{completed};
  $t->block( $a{blocked} )       if defined $a{blocked};
  return $t;
}

sub run_context {
  my (%opt) = @_;
  my $tasks = delete $opt{tasks};
  my $ec    = delete $opt{ec};
  my $store = MockStore->new(
    tasks => $tasks,
    ( $ec ? ( ec => $ec ) : () ),
  );
  my $cmd = App::karr::Cmd::Context->new( store => $store, %opt );
  my $buf = '';
  {
    local *STDOUT;
    # Same layer bin/karr installs via enable_std_utf8: reopening STDOUT drops
    # it, and App::karr::Encoding's POD makes putting it back the in-process
    # capturer's job. Without it the em dash in a noted item prints wide and
    # warns.
    open STDOUT, '>:encoding(UTF-8)', \$buf or die $!;
    $cmd->execute( [], [] );
  }
  return $buf;
}

# One board, read twice: the Markdown header and the --json summary are
# rendered from the same four numbers, so any disagreement between them is a
# bug in itself.
#
#   #1 backlog                     counted, not active
#   #2 in-progress, overdue        counted, active, overdue, In Progress
#   #3 done, overdue, completed    counted, but none of the three above
#   #4 done and blocked            counted and blocked
#   #5 archived and blocked        excluded from everything
sub board {
  return [
    mk( id => 1, title => 'Waiting to start', status => 'backlog' ),
    mk( id => 2, title => 'Under way', status => 'in-progress',
      priority => 'high', due => '2000-01-01' ),
    mk( id => 3, title => 'Finished work', status => 'done',
      due => '2000-01-01', completed => gmtime->strftime('%Y-%m-%d') ),
    mk( id => 4, title => 'Finished but stuck', status => 'done',
      blocked => 'waiting on the release' ),
    mk( id => 5, title => 'Put away', status => 'archived',
      blocked => 'nobody cares any more' ),
  ];
}

subtest 'finished cards count in the header total' => sub {
  my $out = run_context( tasks => board() );

  like( $out, qr/^\*\*4 tasks\*\*/m,
    'four of the five cards are summarised -- the two done ones included' )
    or diag("got:\n$out");
  unlike( $out, qr/Put away/,
    'and the archived one is in none of it' ) or diag("got:\n$out");
};

subtest 'a blocked card that reached done is still blocked' => sub {
  my $out = run_context( tasks => board() );

  like( $out, qr/\| 1 blocked \|/,
    'the blocked count sees it' ) or diag("got:\n$out");
  like( $out, qr/^### Blocked$/m,
    'the Blocked section is rendered' ) or diag("got:\n$out");
  like( $out, qr/\*\*#4\*\* Finished but stuck/,
    'with the done-and-blocked card in it' ) or diag("got:\n$out");
  like( $out, qr/waiting on the release/,
    'carrying its reason' ) or diag("got:\n$out");
  unlike( $out, qr/nobody cares any more/,
    'while an archived card stays blocked-and-gone' ) or diag("got:\n$out");
};

subtest 'the counts that test the terminal status themselves do not move' => sub {
  my $out = run_context( tasks => board() );

  like( $out, qr/\| 1 active \|/,
    'active is the one non-terminal card past the first status, not three' )
    or diag("got:\n$out");
  like( $out, qr/1 overdue/,
    'a past due date on a done card is not overdue' ) or diag("got:\n$out");
  like( $out, qr/^### Overdue$/m, 'the Overdue section is rendered' )
    or diag("got:\n$out");
  # The em dash between title and note is a UTF-8 sequence in this captured
  # buffer, so the pattern steps over it rather than spelling it.
  like( $out, qr/\*\*#2\*\* Under way \(high\).+due 2000-01-01/,
    'and lists the card still being worked on' ) or diag("got:\n$out");
};

subtest 'the In Progress section stays the span it always was' => sub {
  my $out = run_context( tasks => board(), sections => 'in-progress' );

  like( $out, qr/\*\*#2\*\* Under way/, 'the working card is in it' )
    or diag("got:\n$out");
  unlike( $out, qr/Finished work/, 'a done card is not "in progress"' )
    or diag("got:\n$out");
  unlike( $out, qr/Finished but stuck/, 'nor a done blocked one' )
    or diag("got:\n$out");
  unlike( $out, qr/Waiting to start/, 'nor one in the first status' )
    or diag("got:\n$out");
};

subtest 'recently-completed is unchanged by the wider list' => sub {
  # It has scanned every task rather than this list since ticket #99, so it
  # reported #3 before the fix and reports exactly #3 after it -- not #3 twice,
  # and still not the archived card.
  my $out = run_context( tasks => board(), sections => 'recently-completed' );

  my @lines = grep { /^- / } split /\n/, $out;
  is( scalar @lines, 1, 'one entry, not one per pass over the list' )
    or diag("got:\n$out");
  like( $out, qr/\*\*#3\*\* Finished work/, 'the card finished today' )
    or diag("got:\n$out");
};

subtest '--json reports the same four numbers' => sub {
  my $out  = run_context( tasks => board(), json => 1 );
  my $data = decode_json($out);

  is( $data->{summary}{total_tasks}, 4, 'total_tasks matches the header' );
  is( $data->{summary}{blocked},     1, 'blocked matches the header' );
  is( $data->{summary}{active},      1, 'active matches the header' );
  is( $data->{summary}{overdue},     1, 'overdue matches the header' );

  my ($blocked) = grep { $_->{name} eq 'blocked' } @{ $data->{sections} };
  ok( $blocked, 'the blocked section is in --json too' ) or diag("got:\n$out");
  is_deeply( [ map { $_->{id} } @{ $blocked->{items} } ], [ 4 ],
    'holding the done-and-blocked card and nothing else' )
    or diag("got:\n$out");

  my ($overdue) = grep { $_->{name} eq 'overdue' } @{ $data->{sections} };
  is_deeply( [ map { $_->{id} } @{ $overdue->{items} } ], [ 2 ],
    'and the overdue section still skips the done card with a past due date' )
    or diag("got:\n$out");
};

subtest 'the boundary is archived, not whatever this board calls finished' => sub {
  # An imported kanban-md board can name its final column anything (ticket
  # #67). `shipped` is terminal there, so the old filter dropped it; the rule
  # kanban-md applies here is IsArchivedStatus, which is literally
  # `s == "archived"`, so a shipped card is summarised like any other.
  my $out = run_context(
    ec => {
      %{ App::karr::Config->default_config },
      board    => { name => 'Custom' },
      statuses => [qw( backlog doing shipped archived )],
    },
    tasks => [
      mk( id => 1, title => 'Delivered', status => 'shipped' ),
      mk( id => 2, title => 'Delivered but stuck', status => 'shipped',
        blocked => 'customer has not signed off' ),
      mk( id => 3, title => 'Put away', status => 'archived' ),
    ],
  );

  like( $out, qr/^\*\*2 tasks\*\*/m,
    'both shipped cards count, the archived one does not' )
    or diag("got:\n$out");
  like( $out, qr/\*\*#2\*\* Delivered but stuck/,
    'and a blocked shipped card is reported blocked' ) or diag("got:\n$out");
};

done_testing;
