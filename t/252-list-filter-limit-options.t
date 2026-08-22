use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path getcwd );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );
use YAML::XS qw( Dump );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;
use App::karr::Cmd::List;

# Ticket #252: the scope decision on kanban-md's list filter set. Three of the
# four options the maintainer accepted are pinned here -- --limit/-n, --class
# and --blocked/--not-blocked. The fourth, --unclaimed, landed after these and
# is pinned in t/252-list-unclaimed-agrees-with-pick.t, a file of its own: its
# one hard requirement was to reuse App::karr::Role::PickRules/pickable's claim
# test rather than spell a second one, and that test was not reachable on its
# own until it was lifted into App::karr::Role::ClaimTimeout/claim_held.
# Nothing here asserts anything about --unclaimed, which is why this file did
# not have to change when it landed.
#
# Probed against the pre-change code on a default board:
#
#   karr list --limit 2      Unknown option: limit          (exit 2)
#   karr list -n 2           Unknown option: n              (exit 2)
#   karr list --class expedite   Unknown option: class      (exit 2)
#   karr list --blocked      Unknown option: blocked        (exit 2)
#
# The interesting assertions are not "the option exists" but the three
# decisions taken with it: the cut happens after the sort and on every output
# form, an unknown class is a usage error rather than an empty list, and
# --blocked with --not-blocked is refused instead of silently resolved.

sub _init_repo {
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or die "git init failed";
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
  system( 'git', '-C', $repo, 'config', 'user.name',  'Test User' );
  return $repo;
}

# A board whose config can be overridden per test, so "the board's classes"
# is proven to come from the board rather than from a hardcoded default list.
sub _board {
  my (%override) = @_;
  my $repo = _init_repo();
  my $git  = App::karr::Git->new( dir => $repo );
  $git->write_ref( 'refs/karr/config',
    Dump( { version => 1, board => { name => 'Filter Board' }, %override } ) );
  return App::karr::BoardStore->new( git => $git );
}

sub mk {
  my ( $store, %a ) = @_;
  my $t = App::karr::Task->new(
    id       => $a{id},
    title    => $a{title},
    status   => $a{status}   // 'backlog',
    priority => $a{priority} // 'medium',
    class    => $a{class}    // 'standard',
  );
  $t->block( $a{block_reason} ) if $a{blocked};
  $store->save_task($t);
  return $t;
}

# Returns the task ids in the order `karr list` rendered them, from whichever
# output form the options ask for. The capture carries the :encoding(UTF-8)
# layer F<bin/karr> installs (App::karr::Encoding::enable_std_utf8), because
# reopening STDOUT drops it and the command prints characters.
sub list_out {
  my ( $store, %opt ) = @_;
  my $cmd = App::karr::Cmd::List->new( store => $store, %opt );
  my $buf = '';
  {
    local *STDOUT;
    open STDOUT, '>:encoding(UTF-8)', \$buf or die $!;
    $cmd->execute( [], [] );
  }
  return $buf;
}

sub list_ids {
  my ( $store, %opt ) = @_;
  return [ list_out( $store, %opt ) =~ /^#(\d+)/mg ];
}

# JSON goes through the same capture; the ids are read out of the payload
# rather than off a rendered line, so --limit is proven on the machine-readable
# form and not just on the two text ones.
sub list_json_ids {
  my ( $store, %opt ) = @_;
  my $out = list_out( $store, %opt, json => 1 );
  return [ $out =~ /"id":(\d+)/g ];
}

sub list_error {
  my ( $store, %opt ) = @_;
  my $cmd = App::karr::Cmd::List->new( store => $store, %opt );
  my $buf = '';
  my $ok  = eval {
    local *STDOUT;
    open STDOUT, '>:encoding(UTF-8)', \$buf or die $!;
    $cmd->execute( [], [] );
    1;
  };
  return $ok ? undef : $@;
}

#### --limit / -n

subtest '--limit cuts the result, and 0 means no limit' => sub {
  my $store = _board();
  mk( $store, id => $_, title => "task $_" ) for 1 .. 5;

  is_deeply list_ids( $store, limit => 2 ), [ 1, 2 ], '--limit 2 keeps the first two';
  is_deeply list_ids( $store, limit => 0 ), [ 1 .. 5 ],
    '--limit 0 is the whole board, not an empty list (kanban-md: `if Limit > 0`)';
  is_deeply list_ids($store), [ 1 .. 5 ], 'the default is 0, so no limit';
  is_deeply list_ids( $store, limit => 99 ), [ 1 .. 5 ],
    'a limit larger than the result set is not an error and cuts nothing';
  is_deeply list_ids( $store, limit => 1 ), [1], 'a limit of one keeps exactly one';
};

subtest '--limit cuts after the sort, not before it' => sub {
  # The whole reason the cut is the last stage. Ids ascend while urgency
  # descends, so a limit applied before the sort would keep tasks 1 and 2 --
  # the two least urgent -- and then order those two. kanban-md's board.List
  # runs Filter, Sort, then the slice for the same reason.
  my $store = _board();
  mk( $store, id => 1, title => 'lowest',  priority => 'low' );
  mk( $store, id => 2, title => 'medium',  priority => 'medium' );
  mk( $store, id => 3, title => 'high',    priority => 'high' );
  mk( $store, id => 4, title => 'crit',    priority => 'critical' );

  is_deeply list_ids( $store, sort => 'priority', limit => 2 ), [ 4, 3 ],
    'the two most urgent, not the two lowest ids put in order'
    or diag 'cutting before the sort would have given 1, 2';

  is_deeply list_ids( $store, sort => 'priority', reverse => 1, limit => 2 ), [ 1, 2 ],
    '--reverse is applied before the cut too, so the head is the other end';
};

subtest '--limit cuts after the filters, so the N are N matches' => sub {
  # Filtering after the cut would take the first three ids and then keep only
  # the high ones among them -- two tasks, not three.
  my $store = _board();
  mk( $store, id => 1, title => 'a', priority => 'high' );
  mk( $store, id => 2, title => 'b', priority => 'low' );
  mk( $store, id => 3, title => 'c', priority => 'high' );
  mk( $store, id => 4, title => 'd', priority => 'high' );

  is_deeply list_ids( $store, priority => 'high', limit => 3 ), [ 1, 3, 4 ],
    'three high tasks, not the high ones among the first three';
};

subtest '--limit applies to --json and --compact as well as the table' => sub {
  my $store = _board();
  mk( $store, id => $_, title => "task $_" ) for 1 .. 4;

  is_deeply list_json_ids( $store, limit => 2 ), [ 1, 2 ], '--json is cut';
  is_deeply list_ids( $store, compact => 1, limit => 2 ), [ 1, 2 ], '--compact is cut';
  is_deeply list_ids( $store, limit => 2 ), [ 1, 2 ], 'the table is cut';

  # The footer counts what was printed, not what matched: it names the rows
  # above it, and a table of two rows saying "4 task(s)" would be reporting a
  # number the reader cannot see.
  like list_out( $store, limit => 2 ), qr/^2 task\(s\)$/m,
    'the footer counts the rows shown';
};

subtest 'a negative --limit is a usage error, not silently unlimited' => sub {
  # kanban-md's `if opts.Limit > 0` swallows a negative back into "no limit",
  # so `--limit -1` prints the whole board. karr answers the way `show --last`
  # and `log --last` answer theirs (#76, #151, ADR 0002). Note the asymmetry
  # those two do not have: 0 is legal here, because 0 means "all of them".
  my $store = _board();
  mk( $store, id => 1, title => 'one' );

  my $err = list_error( $store, limit => -1 );
  ok defined $err, '--limit -1 dies';
  like $err, qr/^Usage error: --limit must be 0 or greater \(got -1\)/,
    'the message carries the Usage error: marker bin/karr maps to exit 2';
  is list_error( $store, limit => 0 ), undef, '--limit 0 is still accepted';
};

#### --class

subtest '--class filters on the class of service' => sub {
  my $store = _board();
  mk( $store, id => 1, title => 'normal',   class => 'standard' );
  mk( $store, id => 2, title => 'urgent',   class => 'expedite' );
  mk( $store, id => 3, title => 'deadline', class => 'fixed-date' );
  mk( $store, id => 4, title => 'also urgent', class => 'expedite' );

  is_deeply list_ids( $store, class => 'expedite' ), [ 2, 4 ], 'only the expedite cards';
  is_deeply list_ids( $store, class => 'standard' ), [1],      'only the standard card';
  is_deeply list_ids($store), [ 1 .. 4 ], 'without --class every class is listed';
};

subtest '--class narrows alongside the other filters, it does not replace them' => sub {
  my $store = _board();
  mk( $store, id => 1, title => 'urgent low',  class => 'expedite', priority => 'low' );
  mk( $store, id => 2, title => 'urgent high', class => 'expedite', priority => 'high' );
  mk( $store, id => 3, title => 'plain high',  class => 'standard', priority => 'high' );

  is_deeply list_ids( $store, class => 'expedite', priority => 'high' ), [2],
    'class AND priority, as every other filter pair here combines';
};

subtest 'an unknown --class is a usage error naming the board classes' => sub {
  # The deliberate divergence from kanban-md, whose filter is a bare string
  # equality (internal/board/filter.go): there `--class bogus` prints an empty
  # list, which reads as "no such work" when the truth is "no such class".
  my $store = _board();
  mk( $store, id => 1, title => 'one', class => 'expedite' );

  my $err = list_error( $store, class => 'bogus' );
  ok defined $err, '--class bogus dies instead of printing nothing';
  like $err, qr/^Usage error: invalid class "bogus"/,
    'the message carries the Usage error: marker (exit 2, ADR 0002)';
  like $err, qr/valid: .*expedite/, 'it names the classes the board has';
  unlike $err, qr/List\.pm line \d+/, 'no karr source location leaks out';
};

subtest 'the classes named are the board\'s own, not a default list' => sub {
  # Same guarantee pick_rank makes: a board imported from kanban-md can name
  # anything, and the rejection has to talk about that board.
  my $store = _board( classes => [qw( routine rush )] );
  mk( $store, id => 1, title => 'one', class => 'rush' );

  is_deeply list_ids( $store, class => 'rush' ), [1], 'a board-specific class filters';

  my $err = list_error( $store, class => 'expedite' );
  like $err, qr/valid: routine, rush/,
    'expedite is rejected on a board that does not list it, and the two it does are named';
};

subtest 'an empty --class is refused rather than matching nothing' => sub {
  my $store = _board();
  mk( $store, id => 1, title => 'one' );

  my $err = list_error( $store, class => '' );
  like $err, qr/^Usage error: invalid class/,
    'the empty string is not a class, so it is a usage error (#243)';
};

#### --blocked / --not-blocked

subtest '--blocked and --not-blocked split the board' => sub {
  # Fixture from kanban-md's makeTasksWithBlocked (internal/board/filter_test.go),
  # with its TestFilterBlocked / TestFilterNotBlocked / TestFilterBlockedNil
  # expectations.
  my $store = _board();
  mk( $store, id => 1, title => 'Normal',       status => 'backlog' );
  mk( $store, id => 2, title => 'Blocked',      status => 'in-progress',
      blocked => 1, block_reason => 'waiting' );
  mk( $store, id => 3, title => 'Also blocked', status => 'todo',
      blocked => 1, block_reason => 'dependency' );
  mk( $store, id => 4, title => 'Not blocked',  status => 'in-progress' );

  is_deeply list_ids( $store, blocked     => 1 ), [ 2, 3 ], '--blocked keeps the two blocked cards';
  is_deeply list_ids( $store, not_blocked => 1 ), [ 1, 4 ], '--not-blocked keeps the other two';
  is_deeply list_ids($store), [ 1 .. 4 ], 'neither flag leaves all four in place';
};

subtest '--blocked reads the same flag the meta column prints' => sub {
  # Task::_normalize_blocked guarantees has_blocked is true exactly when the
  # card is blocked, so the filter and the rendered "blocked" cannot disagree
  # (ticket #58). A `blocked: false` document is the case that used to be able
  # to say one thing and show another.
  my $store = _board();
  $store->save_task(
    App::karr::Task->from_string(
      "---\nid: 1\ntitle: says false\nstatus: backlog\npriority: medium\n"
        . "class: standard\nblocked: false\nblock_reason: stale\n"
        . "created: 2026-01-01T00:00:00Z\nupdated: 2026-01-01T00:00:00Z\n---\n"
    )
  );
  mk( $store, id => 2, title => 'really blocked', blocked => 1, block_reason => 'why' );

  is_deeply list_ids( $store, blocked => 1 ), [2],
    '`blocked: false` is not blocked, however the reason field reads';
  is_deeply list_ids( $store, not_blocked => 1 ), [1], '...and it lands on the other side';

  my $out = list_out($store);
  like $out,   qr/^#2 .*\[.*blocked.*\]/m, 'the card the filter keeps is the card that renders blocked';
  unlike $out, qr/^#1 .*\bblocked\b/m,     'and the other one renders no blocked marker';
};

subtest '--blocked with --not-blocked is a usage error, not a silent winner' => sub {
  # kanban-md tests `if blocked` first and lets it win without a word
  # (cmd/list.go). karr refuses the pair, as it does for edit --claim/--release
  # and move --next/--prev (ticket #235): nobody types both on purpose.
  my $store = _board();
  mk( $store, id => 1, title => 'open' );
  mk( $store, id => 2, title => 'stuck', blocked => 1, block_reason => 'why' );

  my $err = list_error( $store, blocked => 1, not_blocked => 1 );
  ok defined $err, 'the pair dies';
  like $err, qr/^Usage error: cannot use --blocked and --not-blocked together/,
    'the message names both flags and carries the exit-2 marker';
  unlike $err, qr/List\.pm line \d+/, 'no karr source location leaks out';

  # The refusal is decided before anything is read, so nothing was printed
  # first -- a half-rendered table followed by an error is the shape ADR 0002
  # exists to avoid.
  is list_error( $store, blocked => 1 ),     undef, 'each flag alone is still fine';
  is list_error( $store, not_blocked => 1 ), undef, '...both of them';
};

#### the CLI, where the exit codes live

subtest 'the CLI wires all three options and their exit codes (ADR 0002)' => sub {
  my $ROOT = abs_path('.');
  my $repo = _init_repo();

  my $run = sub {
    my (@argv) = @_;
    my $old = getcwd();
    chdir $repo or die "chdir $repo: $!";
    my $errfh = gensym;
    my $pid = open3( undef, my $outfh, $errfh, $^X, "-I$ROOT/lib", "$ROOT/bin/karr", @argv );
    my $out = do { local $/; <$outfh> };
    my $err = do { local $/; <$errfh> };
    waitpid( $pid, 0 );
    my $exit = $? >> 8;
    chdir $old or die "chdir $old: $!";
    return { exit => $exit, stdout => $out // '', stderr => $err // '' };
  };

  is $run->( 'init', '--name', 'Filter Board' )->{exit}, 0, 'setup: karr init exits 0';
  is $run->( 'create', '--title', 'one', '--priority', 'low' )->{exit}, 0, 'setup: task 1';
  is $run->( 'create', '--title', 'two', '--priority', 'critical', '--class', 'expedite' )->{exit},
    0, 'setup: task 2';
  is $run->( 'create', '--title', 'three', '--priority', 'high' )->{exit}, 0, 'setup: task 3';
  is $run->( 'edit', '3', '--block', 'waiting' )->{exit}, 0, 'setup: task 3 blocked';

  my $limited = $run->( 'list', '--sort', 'priority', '-n', '2' );
  is $limited->{exit}, 0, '-n is accepted as the short form of --limit';
  is_deeply [ $limited->{stdout} =~ /^#(\d+)/mg ], [ 2, 3 ],
    'the two most urgent, in urgency order';

  my $classed = $run->( 'list', '--class', 'expedite' );
  is $classed->{exit}, 0, '--class is accepted';
  is_deeply [ $classed->{stdout} =~ /^#(\d+)/mg ], [2], 'and filters';

  my $blocked = $run->( 'list', '--blocked' );
  is $blocked->{exit}, 0, '--blocked is accepted';
  is_deeply [ $blocked->{stdout} =~ /^#(\d+)/mg ], [3], 'and filters';

  my $unblocked = $run->( 'list', '--not-blocked' );
  is $unblocked->{exit}, 0, '--not-blocked is accepted in its dashed spelling';
  is_deeply [ $unblocked->{stdout} =~ /^#(\d+)/mg ], [ 1, 2 ], 'and filters';

  my $bad_class = $run->( 'list', '--class', 'bogus' );
  is $bad_class->{exit}, 2, 'karr list --class bogus exits 2, not 0 with an empty list'
    or diag "stderr: $bad_class->{stderr}";
  like $bad_class->{stderr}, qr/^Usage error: invalid class "bogus"/m, 'stderr names the value';
  is $bad_class->{stdout}, '', 'and nothing was printed on stdout';

  my $neg = $run->( 'list', '--limit', '-1' );
  is $neg->{exit}, 2, 'a negative --limit exits 2';
  like $neg->{stderr}, qr/--limit must be 0 or greater/, 'stderr says why';

  # Written --not-blocked first on purpose. MooX::Options rewrites a dashed
  # long option to its underscore name in a pre-pass over @ARGV, but a
  # preceding flag swallows the next argv element as its own value before that
  # pre-pass reaches it -- so `--blocked --not-blocked` reports "Unknown
  # option: not-blocked" instead. Same exit code, wrong sentence, and it is not
  # this option's bug: `karr list --json --claimed-by NAME` has always failed
  # the same way. Filed separately (#256); this asserts the message karr owns.
  my $both = $run->( 'list', '--not-blocked', '--blocked' );
  is $both->{exit}, 2, 'both blocked flags together exit 2';
  like $both->{stderr}, qr/cannot use --blocked and --not-blocked together/,
    'stderr refuses the pair rather than picking one';
};

done_testing;
