# t/254-compact-output-role.t
#
# Ticket #254: App::karr::Role::Output declared --compact beside --json, and
# every command with an alternate rendering composed that role for --json --
# so all twenty-two of them advertised --compact in --help while only five
# (board, list, pick, and, half-heartedly, show/context/log/config -- see
# below) ever read the option, and the other thirteen accepted it and threw it
# away without a word. `karr show 5 --compact` printed the same full detail
# view `karr show 5` did; `karr move 5 done --compact` "succeeded" too, having
# ignored the flag entirely. #251 already pinned this failure for `pick`
# specifically and fixed it there; #254 is the rest of the census plus the
# structural fix: --compact moved out of Role::Output into a new role,
# App::karr::Role::CompactOutput, composed by exactly the nine commands that
# render a compact form (board, config, context, dashboard, list, log,
# metrics, pick, show). Everywhere else --compact is now simply not a
# declared option, so MooX::Options rejects it the way it rejects any other
# typo: "Unknown option: compact", the usage block, exit 2 (ADR 0002's usage-
# error contract) -- instead of the old silent no-op.
#
# Since k263 that rejection reads bottom-up -- the usage block first and the
# diagnostic last, where an agent reading `tail -n` will actually see it. An
# unknown option is the one k263 shape that gets no suggestion line under it
# (the only command that would run is the caller's own word deleted), so the
# wording below is exactly what it always was.
#
# Four of the nine also gained a *new* rendering as part of the same ticket
# (show, context, log, config show); the other five (board, list, metrics,
# pick, dashboard) already had one and are unchanged by this ticket beyond
# moving house. This file pins:
#
#   1. The loud rejection -- a representative sample of the thirteen, chosen
#      to cross all three domain-worker boundaries rather than clustering in
#      one file: `move`/`edit`/`delete` (karr-board-worker, three different
#      argument shapes: id+status, id+flag, batch+confirm), `disable`
#      (karr-foundation-worker, a board-config toggle), and
#      `materialize`/`unlock` (karr-ref-worker, the file-view bridge and the
#      lock-management command). All thirteen were probed by hand against the
#      running binary while this file was written and behave identically; six
#      is enough to catch a regression without re-deriving the other seven's
#      usage strings here.
#   2. The nine still take --compact, exit 0.
#   3. The four new renderings, each pinned to its actual shape:
#      - `show --compact` is byte-identical to the line `list --compact`
#        prints for the same card (both now go through
#        App::karr::Task::compact_line, so this is a non-drift guarantee, not
#        a coincidence).
#      - `log --compact` has no column padding, no trailing whitespace, and
#        omits a detail field entirely when the entry carries none.
#      - `config show --compact` prints the same keys as the padded table,
#        as `key=value`.
#      - `context --compact` prints exactly the five keys the --json summary
#        uses.
#   4. --json wins over --compact on all four: `--json --compact` output is
#      byte-identical to `--json` alone.
#   5. The role split itself: App::karr::Role::Output no longer declares
#      compact, and CompactOutput is composed by exactly the nine named
#      above and no other command class -- checked against the full roster
#      of thirty-one Cmd:: classes, so a tenth consumer or a dropped ninth
#      both fail this file rather than only the file for the one command
#      affected.
#
# Every subtest below runs against a throwaway repository under File::Temp;
# the developer's own board is never touched.

use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr ();
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );
use YAML::XS qw( Dump );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;
use App::karr::Role::Output;
use App::karr::Role::CompactOutput;
use App::karr::Cmd::List;
use App::karr::Cmd::Show;
use App::karr::Cmd::Log;
use App::karr::Cmd::Config;
use App::karr::Cmd::Context;

# The full roster, for the role-partition test (point 5). Every Cmd:: class
# under lib/App/karr/Cmd/, loaded so ->does() answers for real composition
# rather than for a name that merely resolves.
use App::karr::Cmd::AgentName;
use App::karr::Cmd::Archive;
use App::karr::Cmd::Backup;
use App::karr::Cmd::Board;
use App::karr::Cmd::Create;
use App::karr::Cmd::Dashboard;
use App::karr::Cmd::Delete;
use App::karr::Cmd::Destroy;
use App::karr::Cmd::Disable;
use App::karr::Cmd::Edit;
use App::karr::Cmd::Enable;
use App::karr::Cmd::GetRefs;
use App::karr::Cmd::Handoff;
use App::karr::Cmd::Import;
use App::karr::Cmd::Init;
use App::karr::Cmd::Materialize;
use App::karr::Cmd::Metrics;
use App::karr::Cmd::Move;
use App::karr::Cmd::Needs;
use App::karr::Cmd::Pick;
use App::karr::Cmd::Repair;
use App::karr::Cmd::Restore;
use App::karr::Cmd::SetRefs;
use App::karr::Cmd::Skill;
use App::karr::Cmd::Sync;
use App::karr::Cmd::Unlock;

# ---------------------------------------------------------------- helpers --

sub init_board {
  my (%opts) = @_;
  my $name = $opts{name} // 'Compact';
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
    or BAIL_OUT('git config failed');
  system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
    or BAIL_OUT('git config failed');

  my $git = App::karr::Git->new( dir => $repo );
  $git->write_ref( 'refs/karr/config',
    Dump( { version => 1, board => { name => $name } } ) );
  $git->write_ref( 'refs/karr/meta/next-id', "2\n" );
  return ( App::karr::BoardStore->new( git => $git ), $repo, $git );
}

sub run_execute {
  my ( $cmd, @args ) = @_;
  my $out = '';
  my $err = do {
    local $@;
    eval {
      local *STDOUT;
      open STDOUT, '>', \$out or die $!;
      $cmd->execute( \@args, [] );
    };
    $@;
  };
  return ( $err, $out );
}

# In-process runner (t/lib/TestKarr.pm), wrapped to keep this file's own
# NO_COLOR/KARR_NO_AUTO_FETCH env setup. KARR_TEST_SUBPROC=1 restores the old
# open3 path.
sub run_karr {
  my ( $cwd, @argv ) = @_;
  local $ENV{NO_COLOR}           = 1;
  local $ENV{KARR_NO_AUTO_FETCH} = 1;
  return TestKarr::run_karr( $cwd, @argv );
}

sub cli_setup_repo {
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
    or BAIL_OUT('git config failed');
  system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
    or BAIL_OUT('git config failed');

  my $init = run_karr( $repo, 'init', '--name', 'Compact CLI Board' );
  is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};
  return $repo;
}

# ------------------------------------------------------------ 5. role split

subtest 'App::karr::Role::Output no longer declares --compact' => sub {
  {
    package OutputOnlyConsumer;
    use Moo;
    use MooX::Options;
    with 'App::karr::Role::Output';
  }
  ok( !OutputOnlyConsumer->can('compact'),
    'a class composing only Role::Output has no ->compact accessor' );
  ok( OutputOnlyConsumer->can('json'),
    '...but still has ->json -- that half of the old role stayed' );
};

subtest 'CompactOutput is composed by exactly the nine rendering commands' => sub {
  my @NINE = qw( Board Config Context Dashboard List Log Metrics Pick Show );
  my @ALL  = qw(
    AgentName Archive Backup Board Config Context Create Dashboard Delete
    Destroy Disable Edit Enable GetRefs Handoff Import Init List Log
    Materialize Metrics Move Needs Pick Repair Restore SetRefs Show Skill
    Sync Unlock
  );
  is( scalar(@ALL), 31, 'sanity: the roster covers every Cmd:: class on disk' );

  my %expect_compact = map { $_ => 1 } @NINE;

  for my $name (@ALL) {
    my $class    = "App::karr::Cmd::$name";
    my $does     = $class->does('App::karr::Role::CompactOutput') ? 1 : 0;
    my $expected = $expect_compact{$name} ? 1 : 0;
    is( $does, $expected,
      "$class ->does(CompactOutput) is " . ( $expected ? 'true' : 'false' ) );
  }
};

# ---------------------------------------------------- 1. the loud rejection

subtest 'a representative sample of the thirteen reject --compact loudly' => sub {
  my $repo = cli_setup_repo();
  my $create = run_karr( $repo, 'create', '--title', 'T1', '--status', 'todo' );
  is( $create->{exit}, 0, 'seed task created' ) or diag $create->{stderr};

  my @CASES = (
    # [ label, argv (without --compact), usage-prefix ]
    [ 'move',        [ 'move', 1, 'done' ],                 'move' ],
    [ 'edit',         [ 'edit', 1, '--title', 'New' ],        'edit' ],
    [ 'delete',       [ 'delete', 1, '--yes' ],               'delete' ],
    [ 'disable',      [ 'disable' ],                          'disable' ],
    [ 'materialize',  [ 'materialize' ],                      'materialize' ],
    [ 'unlock',       [ 'unlock' ],                           'unlock' ],
  );

  for my $case (@CASES) {
    my ( $label, $argv, $usage_cmd ) = @$case;
    my $rv = run_karr( $repo, @$argv, '--compact' );

    is( $rv->{exit}, 2, "karr $label ... --compact exits 2" )
      or diag "stdout: $rv->{stdout}\nstderr: $rv->{stderr}";
    is( $rv->{stdout}, '', "karr $label ... --compact prints nothing to stdout" );
    like( $rv->{stderr}, qr/^Unknown option: compact$/m,
      "karr $label ... --compact: STDERR says so on its own line" );
    unlike( $rv->{stderr}, qr/^  karr /m,
      "karr $label ... --compact: and offers no command in its place" );
    like( $rv->{stderr}, qr/^USAGE: karr \Q$usage_cmd\E\b/m,
      "karr $label ... --compact: the usage block is there too" );
  }

  # The rejection happens at option-parse time, before execute() ever runs --
  # confirmed by nothing the rejected calls asked for having happened.
  my $show = run_karr( $repo, 'show', 1 );
  is( $show->{exit}, 0, 'task 1 is still readable' ) or diag $show->{stderr};
  like( $show->{stdout}, qr/^Status:\s+todo$/m,
    'move --compact never ran: task 1 is still todo' );
  like( $show->{stdout}, qr/^Task #1: T1$/m,
    'edit --compact never ran: task 1 title is unchanged' );

  my $cfg = run_karr( $repo, 'config', 'get', 'foundation.enabled' );
  is( $cfg->{exit}, 0, 'config get foundation.enabled succeeds' ) or diag $cfg->{stderr};
  is( $cfg->{stdout}, "1\n", 'disable --compact never ran: foundation is still enabled' );

  ok( !-d "$repo/tasks", 'materialize --compact never ran: no tasks/ directory was written' );
};

# --------------------------------------------------- 2. the nine still take
# --compact, and exit 0.

subtest 'the nine rendering commands still accept --compact (exit 0)' => sub {
  my $repo = cli_setup_repo();
  my $create = run_karr( $repo, 'create', '--title', 'T1', '--status', 'todo' );
  is( $create->{exit}, 0, 'seed task created' ) or diag $create->{stderr};

  my @CASES = (
    [ 'board',     [ 'board', '--compact' ] ],
    [ 'config',    [ 'config', 'show', '--compact' ] ],
    [ 'context',   [ 'context', '--compact' ] ],
    [ 'dashboard', [ 'dashboard', '--compact' ] ],
    [ 'list',      [ 'list', '--compact' ] ],
    [ 'log',       [ 'log', '--compact' ] ],
    [ 'metrics',   [ 'metrics', '--compact' ] ],
    [ 'pick',      [ 'pick', '--claim', 'probe', '--compact' ] ],
    [ 'show',      [ 'show', 1, '--compact' ] ],
  );

  for my $case (@CASES) {
    my ( $label, $argv ) = @$case;
    my $rv = run_karr( $repo, @$argv );
    is( $rv->{exit}, 0, "karr @$argv exits 0" ) or diag $rv->{stderr};
    unlike( $rv->{stderr}, qr/Unknown option: compact/,
      "karr @$argv: --compact was not rejected" );
  }
};

# ---------------------------------------------- 3./4. the four new renderings

subtest 'show --compact is exactly the line list --compact prints for the card' => sub {
  my ($store) = init_board();
  $store->save_task( App::karr::Task->new(
    id => 1, title => 'Ship the compact rendering', status => 'todo',
    priority => 'high', class => 'standard',
  ) );
  $store->save_task( App::karr::Task->new(
    id => 2, title => 'Also in progress', status => 'in-progress',
    priority => 'medium', class => 'standard',
  ) );
  $store->save_task( App::karr::Task->new(
    id => 3, title => 'Finished already', status => 'done',
    priority => 'low', class => 'standard',
  ) );

  my ( $lerr, $list_out ) =
    run_execute( App::karr::Cmd::List->new( store => $store, compact => 1 ) );
  is( $lerr, '', 'list --compact does not die' ) or diag "died with: $lerr";

  # list excludes the terminal status (done) by default, so only 1 and 2 are
  # in here -- extract each card's own line by its leading id rather than
  # assuming order, so this test does not also have to pin list's sort order.
  my %list_line_by_id;
  for my $line ( split /\n/, $list_out ) {
    $list_line_by_id{$1} = $line if $line =~ /^#(\d+)/;
  }
  is( scalar( keys %list_line_by_id ), 2, 'list --compact prints the two non-terminal cards' )
    or diag "got:\n$list_out";

  for my $id ( 1, 2 ) {
    my ( $serr, $show_out ) = run_execute(
      App::karr::Cmd::Show->new( store => $store, compact => 1 ), $id );
    is( $serr, '', "show $id --compact does not die" ) or diag "died with: $serr";
    is( $show_out, $list_line_by_id{$id} . "\n",
      "show $id --compact is byte-identical to list --compact's line for card $id" );
  }

  # And the line itself has the documented shape: #id, right-aligned status,
  # then the title -- not merely "shorter than the full view".
  like( $list_line_by_id{1}, qr/^#1\s+todo\s+Ship the compact rendering$/,
    'the line carries id, status and title in that shape' );
};

subtest '--json wins over --compact for show' => sub {
  my ($store) = init_board();
  $store->save_task( App::karr::Task->new(
    id => 1, title => 'T1', status => 'todo', priority => 'high', class => 'standard',
  ) );

  my ( undef, $json_only ) = run_execute(
    App::karr::Cmd::Show->new( store => $store, json => 1 ), 1 );
  my ( undef, $json_and_compact ) = run_execute(
    App::karr::Cmd::Show->new( store => $store, json => 1, compact => 1 ), 1 );

  is( $json_and_compact, $json_only,
    'show --json --compact is byte-identical to show --json' );
  ok( length($json_only), 'sanity: the json payload is not empty' );
};

subtest 'log --compact: no column padding, no trailing whitespace, no empty detail' => sub {
  my ( $store, $repo, $git ) = init_board();

  # Written directly as log refs (the shape App::karr::Cmd::Log reads), one
  # entry with a detail and one without -- t/17-log.t seeds entries the same
  # way. One extra field (detail) is the whole difference between the two
  # rendering rules under test.
  my $with_detail =
    '{"ts":"2026-03-19T10:00:00Z","agent":"agent-a","action":"pick","task_id":1,"detail":"in-progress"}';
  my $without_detail =
    '{"ts":"2026-03-19T10:05:00Z","agent":"agent-b","action":"move","task_id":2}';
  $git->write_ref( 'refs/karr/log/agent-a_test.com', $with_detail );
  $git->write_ref( 'refs/karr/log/agent-b_test.com', $without_detail );

  my ( $err, $out ) =
    run_execute( App::karr::Cmd::Log->new( store => $store, compact => 1 ) );
  is( $err, '', 'log --compact does not die' ) or diag "died with: $err";

  is( $out,
      "2026-03-19T10:00:00Z agent-a pick #1 in-progress\n"
    . "2026-03-19T10:05:00Z agent-b move #2\n",
    'one space-separated line per entry, in timestamp order' )
    or diag("got:\n$out");

  # Named apart from the exact-string check above, because these are the two
  # promises the ticket makes about this rendering specifically.
  unlike( $out, qr/ \n/, 'no trailing space before any newline' );
  like( $out, qr/move #2$/m,
    'the entry with no detail ends at the task id -- nothing appended for it' );

  # And the padded default still pads, so the two renderings actually differ.
  my ( undef, $padded ) = run_execute( App::karr::Cmd::Log->new( store => $store ) );
  isnt( $padded, $out, 'the default rendering is not the same string' );
  like( $padded, qr/task#1/, 'the padded rendering still spells the id as task#N' );
};

subtest '--json wins over --compact for log' => sub {
  my ( $store, $repo, $git ) = init_board();
  $git->write_ref( 'refs/karr/log/agent-a_test.com',
    '{"ts":"2026-03-19T10:00:00Z","agent":"agent-a","action":"pick","task_id":1}' );

  my ( undef, $json_only ) =
    run_execute( App::karr::Cmd::Log->new( store => $store, json => 1 ) );
  my ( undef, $json_and_compact ) =
    run_execute( App::karr::Cmd::Log->new( store => $store, json => 1, compact => 1 ) );

  is( $json_and_compact, $json_only,
    'log --json --compact is byte-identical to log --json' );
  ok( length($json_only), 'sanity: the json payload is not empty' );
};

subtest 'config show --compact prints the same keys as the padded table, as key=value' => sub {
  my ($store) = init_board( name => 'Compact Config Board' );

  my ( $perr, $padded ) =
    run_execute( App::karr::Cmd::Config->new( store => $store ), 'show' );
  is( $perr, '', 'config show does not die' ) or diag "died with: $perr";

  my ( $cerr, $compact ) =
    run_execute( App::karr::Cmd::Config->new( store => $store, compact => 1 ), 'show' );
  is( $cerr, '', 'config show --compact does not die' ) or diag "died with: $cerr";

  my @compact_pairs;
  for my $line ( split /\n/, $compact ) {
    like( $line, qr/^[^=\s]+=/, "compact line has key=value shape: $line" );
    my ( $key, $val ) = $line =~ /^([^=]+)=(.*)$/;
    push @compact_pairs, [ $key, $val ];
  }
  ok( scalar(@compact_pairs) > 5, 'more than a handful of keys are printed' );

  my @padded_keys = map { /^(\S+)/ ? $1 : () } split /\n/, $padded;
  my @compact_keys = map { $_->[0] } @compact_pairs;
  is_deeply( [ sort @compact_keys ], [ sort @padded_keys ],
    'the compact rendering names exactly the same keys as the padded table' );

  # Same values too, not just the same key names: for every compact
  # "key=value" line, the padded table has a line starting with that key,
  # padding, then that exact value.
  for my $pair (@compact_pairs) {
    my ( $key, $val ) = @$pair;
    like( $padded, qr/^\Q$key\E\s+\Q$val\E$/m,
      "padded table agrees with compact on $key" );
  }

  # And it really did drop the padding -- the two renderings differ.
  isnt( $compact, $padded, 'compact and padded are different strings' );
  unlike( $compact, qr/^\S+ {2,}\S/m,
    'no compact line pads its key out with multiple spaces' );
};

subtest '--json wins over --compact for config show' => sub {
  my ($store) = init_board();

  my ( undef, $json_only ) =
    run_execute( App::karr::Cmd::Config->new( store => $store, json => 1 ), 'show' );
  my ( undef, $json_and_compact ) = run_execute(
    App::karr::Cmd::Config->new( store => $store, json => 1, compact => 1 ), 'show' );

  is( $json_and_compact, $json_only,
    'config show --json --compact is byte-identical to config show --json' );
  ok( length($json_only), 'sanity: the json payload is not empty' );
};

subtest 'context --compact prints exactly the five --json summary keys' => sub {
  my ($store) = init_board( name => 'Compact Context Board' );
  $store->save_task( App::karr::Task->new(
    id => 1, title => 'T1', status => 'todo', priority => 'high', class => 'standard',
  ) );

  my ( $err, $out ) =
    run_execute( App::karr::Cmd::Context->new( store => $store, compact => 1 ) );
  is( $err, '', 'context --compact does not die' ) or diag "died with: $err";

  is( $out,
      "board_name=Compact Context Board\n"
    . "total_tasks=1\n"
    . "active=1\n"
    . "blocked=0\n"
    . "overdue=0\n",
    'exactly the five keys, in the order the --json summary reports them' )
    or diag("got:\n$out");

  # No headings, no sections, no sentinels -- unlike the Markdown rendering.
  unlike( $out, qr/^##/m,        'no Markdown heading' );
  unlike( $out, qr/BEGIN kanban-md/, 'no sentinel comment' );
};

subtest '--json wins over --compact for context' => sub {
  my ($store) = init_board();
  $store->save_task( App::karr::Task->new(
    id => 1, title => 'T1', status => 'todo', priority => 'high', class => 'standard',
  ) );

  my ( undef, $json_only ) =
    run_execute( App::karr::Cmd::Context->new( store => $store, json => 1 ) );
  my ( undef, $json_and_compact ) = run_execute(
    App::karr::Cmd::Context->new( store => $store, json => 1, compact => 1 ) );

  is( $json_and_compact, $json_only,
    'context --json --compact is byte-identical to context --json' );
  ok( length($json_only), 'sanity: the json payload is not empty' );

  my $data = decode_json($json_only);
  is( $data->{summary}{total_tasks}, 1, 'sanity: the json payload has the real summary' );
};

done_testing;
