use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );
use Path::Tiny;

# Ticket #255: `karr config show` filtered its six optional rows by truth, so a
# key a board really set to `0` vanished from the plain-text table while the
# other two surfaces of the same command reported it:
#
#     karr config set board.name 0   -> Set board.name = 0
#     karr config show               -> no board.name row
#     karr config get board.name     -> 0
#     karr config show --json        -> {"board":{"name":"0"}, ...}
#
# Same root as #244 (truth where length/defined was meant) but a different
# site: a rendering filter, not an argument guard, and what it splits is not
# exit code 1 from 2 but `show` from `get` and `--json`.
#
# It also falsified this command's own POD, which promises that
#
#     diff <(karr config show) <(karr config show --defaults)
#
# is exactly the set of keys this board overrides. `board.description` and
# `foundation.reason` have no default row at all, so an override worth `0` fell
# out of both sides and the diff reported agreement where there was none.
#
# The fix is `defined` on all six rows -- not `defined && length`, because the
# empty string is the same disagreement with a different value: `config get`
# prints an empty line at exit 0 for it and `--json` carries "", so the table
# must carry a row too. `config set` refuses an empty argument (#243), but
# `karr import` writes one, which is the path the last subtest takes.
#
# Driven through the real binary: the bug is in the command's renderer, and an
# in-process assertion on App::karr::Config would have stayed green throughout.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

# Fresh throwaway board per subtest -- never the developer's own.
sub _board_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or die 'git config';
    is( _run_karr( $repo, 'init', '--name', 'Zero Board' )->{exit},
        0, 'setup: karr init exits 0' );
    return $repo;
}

# One row of `config show` as key => rendered value, trailing padding removed.
sub _rows {
    my ($text) = @_;
    my %row;
    for my $line ( split /\n/, $text ) {
        next unless $line =~ /\A(\S+)\s*(.*?)\s*\z/;
        $row{$1} = $2;
    }
    return \%row;
}

sub _has_row {
    my ($text, $key) = @_;
    return scalar grep { /\A\Q$key\E(?:\s|\z)/ } split /\n/, $text;
}

subtest 'a board.name of 0 reads the same through show, get and --json (RED, #255)' => sub {
    my $repo = _board_repo();

    my $set = _run_karr( $repo, 'config', 'set', 'board.name', '0' );
    is( $set->{exit}, 0, 'config set board.name 0 exits 0' ) or diag $set->{stderr};

    my $show = _run_karr( $repo, 'config', 'show' );
    is( $show->{exit}, 0, 'config show exits 0' ) or diag $show->{stderr};
    ok( _has_row( $show->{stdout}, 'board.name' ),
        'config show keeps the board.name row for a value of 0' )
        or diag $show->{stdout};
    is( _rows( $show->{stdout} )->{'board.name'}, '0',
        'and renders it as 0' );

    my $get = _run_karr( $repo, 'config', 'get', 'board.name' );
    is( $get->{exit},   0,     'config get board.name exits 0' );
    is( $get->{stdout}, "0\n", 'config get board.name answers 0' );

    my $json = _run_karr( $repo, 'config', 'show', '--json' );
    is( $json->{exit}, 0, 'config show --json exits 0' ) or diag $json->{stderr};
    my $data = decode_json( $json->{stdout} );
    is( $data->{board}{name}, '0', 'config show --json carries board.name 0' );

    # The point of the ticket: not that any one of the three is right, but that
    # they agree. The table row, the bare `get` line and the JSON member are one
    # value read three ways.
    is( _rows( $show->{stdout} )->{'board.name'},
        $data->{board}{name},
        'show and --json agree about board.name' );
    is( _rows( $show->{stdout} )->{'board.name'},
        do { my $t = $get->{stdout}; chomp $t; $t },
        'show and get agree about board.name' );
};

subtest 'foundation.reason of 0 shows up too -- and beside foundation.enabled' => sub {
    my $repo = _board_repo();

    is( _run_karr( $repo, 'config', 'set', 'foundation.reason', '0' )->{exit},
        0, 'config set foundation.reason 0 exits 0' );

    my $show = _run_karr( $repo, 'config', 'show' );
    my $rows = _rows( $show->{stdout} );
    is( $rows->{'foundation.reason'}, '0', 'foundation.reason row says 0' )
        or diag $show->{stdout};

    # foundation.enabled has always printed a bare 0 -- it goes through
    # $c->foundation_enabled with no filter in front of it. That is the proof
    # that a zero row was never a problem for this output, only for the six
    # rows that were filtered.
    is( _run_karr( $repo, 'config', 'set', 'foundation.enabled', 'false' )->{exit},
        0, 'config set foundation.enabled false exits 0' );
    is( _rows( _run_karr( $repo, 'config', 'show' )->{stdout} )->{'foundation.enabled'},
        '0', 'foundation.enabled prints 0 unfiltered, as it always did' );

    my $get = _run_karr( $repo, 'config', 'get', 'foundation.reason' );
    is( $get->{stdout}, "0\n", 'config get foundation.reason answers 0' );
    my $data = decode_json( _run_karr( $repo, 'config', 'show', '--json' )->{stdout} );
    is( $data->{foundation}{reason}, '0', '--json carries foundation.reason 0' );
};

subtest 'the POD diff promise: an override of 0 appears in the diff (#255)' => sub {
    my $repo = _board_repo();

    is( _run_karr( $repo, 'config', 'set', 'board.name', '0' )->{exit}, 0, 'set board.name 0' );
    is( _run_karr( $repo, 'config', 'set', 'foundation.reason', '0' )->{exit},
        0, 'set foundation.reason 0' );

    my $board    = _run_karr( $repo, 'config', 'show' );
    my $defaults = _run_karr( $repo, 'config', 'show', '--defaults' );
    is( $board->{exit},    0, 'config show exits 0' );
    is( $defaults->{exit}, 0, 'config show --defaults exits 0' );

    # What `diff <(karr config show) <(karr config show --defaults)` prints on
    # the `<` side: the lines this board has and the defaults do not.
    my %default_line = map { $_ => 1 } split /\n/, $defaults->{stdout};
    my @only_here = grep { !$default_line{$_} } split /\n/, $board->{stdout};

    ok( ( grep { /\Aboard\.name\s/ } @only_here ),
        'board.name = 0 is in the diff -- the default is "Kanban Board"' )
        or diag join "\n", @only_here;
    ok( ( grep { /\Afoundation\.reason\s/ } @only_here ),
        'foundation.reason = 0 is in the diff -- the defaults have no such key' )
        or diag join "\n", @only_here;

    # Every line the diff reports really is an overridden key, and nothing else
    # drifted into it.
    my %overridden = map { /\A(\S+)/ ? ( $1 => 1 ) : () } @only_here;
    is_deeply( [ sort keys %overridden ],
        [ sort qw( board.name foundation.reason ) ],
        'the diff is exactly the two keys this board overrides' );
};

subtest 'a key the board never set stays out of all three (#255 is not "always print")' => sub {
    my $repo = _board_repo();

    my $show = _run_karr( $repo, 'config', 'show' );
    ok( !_has_row( $show->{stdout}, 'board.description' ),
        'no board.description row on a board that never set one' )
        or diag $show->{stdout};
    ok( !_has_row( $show->{stdout}, 'foundation.reason' ),
        'no foundation.reason row either' );

    my $get = _run_karr( $repo, 'config', 'get', 'board.description' );
    is( $get->{exit}, 1, 'config get board.description exits 1' );
    like( $get->{stderr}, qr/Unknown key/, 'and says the key is unknown' );

    my $data = decode_json( _run_karr( $repo, 'config', 'show', '--json' )->{stdout} );
    ok( !exists $data->{board}{description}, '--json has no description member' );

    # The --defaults side renders through the same filter, so it must not have
    # grown rows either.
    my $defaults = _run_karr( $repo, 'config', 'show', '--defaults' );
    ok( !_has_row( $defaults->{stdout}, 'board.description' ),
        'config show --defaults still lists no board.description' );
    ok( !_has_row( $defaults->{stdout}, 'foundation.reason' ),
        'config show --defaults still lists no foundation.reason' );
};

subtest 'an empty board.description is present in all three, blank in the table' => sub {
    my $repo = _board_repo();

    # `config set` refuses an empty argument (#243), so the only ways to a
    # defined-but-empty value are `karr import` and a hand-edited config.yml.
    # This is the import path, with one card so the import is not an emptying.
    is( _run_karr( $repo, 'create', 'seed card' )->{exit}, 0, 'setup: one card exists' );
    is( _run_karr( $repo, 'materialize' )->{exit}, 0, 'setup: materialize' );

    my $cfg = path( $repo, 'config.yml' );
    ok( $cfg->is_file, 'setup: materialized config.yml' ) or return;
    my $yaml = $cfg->slurp_utf8;
    $yaml =~ s/^board:\n/board:\n  description: ''\n/m
        or do { fail 'setup: could not patch config.yml'; return };
    $cfg->spew_utf8($yaml);

    my $import = _run_karr( $repo, 'import', '--yes' );
    is( $import->{exit}, 0, 'setup: import --yes exits 0' ) or diag $import->{stderr};

    my $show = _run_karr( $repo, 'config', 'show' );
    ok( _has_row( $show->{stdout}, 'board.description' ),
        'config show has a board.description row for an empty value' )
        or diag $show->{stdout};
    is( _rows( $show->{stdout} )->{'board.description'}, '',
        'and its right-hand side is blank' );

    my $get = _run_karr( $repo, 'config', 'get', 'board.description' );
    is( $get->{exit},   0,    'config get board.description exits 0, not "Unknown key"' );
    is( $get->{stdout}, "\n", 'and prints an empty line -- the same nothing' );

    my $data = decode_json( _run_karr( $repo, 'config', 'show', '--json' )->{stdout} );
    ok( exists $data->{board}{description}, '--json carries the description member' );
    is( $data->{board}{description}, '', 'as the empty string' );
};

done_testing;
