use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );
use Path::Tiny qw( path );

use App::karr::Config;
use App::karr::Git;

# Regression tests for karr board ticket #227.
#
# WHAT WAS WRONG: every board karr ever created carried
#
#     classes:
#       - name: expedite
#         wip_limit: 1
#         bypass_column_wip: 1
#
# from App::karr::Config::default_config, and Config->validate checked the
# value ("class NAME wip_limit must be >= 0"). Nothing else in the tree read
# either key -- no command, no role, no mutation path. The board therefore
# advertised a live-looking limit that could never take effect, and rejected a
# value for it. The maintainer chose removal over enforcement: karr has no WIP
# limits, per-status or per-class, and now says so instead of half-modelling
# one.
#
# THE PART THAT NEEDED CARE was the boards that already carry the key -- which
# is every board initialised before this change, including karr's own. What
# the change had to guarantee, and what this file pins:
#
#   (a) the defaults no longer carry it, at the CLI surface and in --json;
#   (b) a board that carries it keeps working -- validate ignores keys it does
#       not model, so nothing that used to save starts failing, and a value the
#       old check REJECTED (wip_limit: -1) is now simply passed through;
#   (c) the key is not scrubbed: it rides along in refs/karr/config through an
#       ordinary config write, because karr does not delete what it stopped
#       reading;
#   (d) but it cannot come BACK in through a kanban-md file view -- adopting
#       another tool's default as a per-board override is the #88 failure, and
#       the class keys now get the same pruning `wip_limits` and
#       `show_duration` already get. t/102 owns the whole-config round trip;
#       what is pinned here is the direction: stored keys survive, view keys
#       are not adopted.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

# Fresh throwaway board per subtest -- never the developer's own, which is one
# of the boards carrying the removed key.
sub _board_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or die 'git config';
    is( _run_karr( $repo, 'init', '--name', 'WIP Board' )->{exit},
        0, 'setup: karr init exits 0' );
    return $repo;
}

sub _overrides {
    my ($repo) = @_;
    return App::karr::Git->new( dir => $repo )->read_config_ref;
}

# A board as it looked before #227: the key sits in refs/karr/config, because
# its classes were customised (a bare default board never stored them -- they
# matched the defaults and were diffed away). `wip_limit: -1` is deliberate:
# that exact value is what the removed check refused, so a board carrying it
# proves the check is gone rather than merely relaxed.
sub _legacy_board {
    my ($repo) = @_;
    ok( App::karr::Git->new( dir => $repo )->write_ref(
            'refs/karr/config',
            join( "\n",
                '---',
                'version: 1',
                'board:',
                '  name: WIP Board',
                'tasks_dir: tasks',
                'classes:',
                '  - name: expedite',
                '    wip_limit: -1',
                '    bypass_column_wip: 1',
                '  - name: standard',
                '' )
        ),
        'setup: a board carrying the removed class keys'
    );
    return $repo;
}

subtest '(a) a new board advertises no class WIP limit' => sub {
    my $repo = _board_repo();

    my $rv = _run_karr( $repo, 'config', 'get', 'classes', '--json' );
    is( $rv->{exit}, 0, 'exit 0' ) or diag $rv->{stderr};
    is_deeply(
        eval { decode_json( $rv->{stdout} ) },
        {   classes => [
                { name => 'expedite' },
                { name => 'fixed-date' },
                { name => 'standard' },
                { name => 'intangible' },
            ]
        },
        'not one default class carries wip_limit or bypass_column_wip'
    ) or diag $rv->{stdout};

    my $show = _run_karr( $repo, 'config', 'show' );
    unlike( $show->{stdout}, qr/wip_limit|bypass_column/i,
        'and nothing in config show mentions a WIP limit' );

    # The in-process half of the same claim: whatever a caller reaches for --
    # the CLI above or the class method -- there is no WIP key left to find.
    my $defaults = App::karr::Config->default_config;
    ok( !exists $defaults->{wip_limits}, 'no per-status wip_limits either' );
    is_deeply(
        [ grep { ref $_ eq 'HASH' && ( exists $_->{wip_limit} || exists $_->{bypass_column_wip} ) }
                @{ $defaults->{classes} } ],
        [], 'default_config classes are names and nothing else' );
};

subtest '(b) validate no longer rejects a class WIP limit it cannot enforce' => sub {
    # Straight at validate, because save_config is where it bites: the old
    # check ran on the *effective* config, so a stored -1 made every later
    # config write die on a setting the board could not act on anyway.
    my $data = App::karr::Config->effective_config(
        {   board   => { name => 'Legacy' },
            classes => [
                { name => 'expedite', wip_limit => -1, bypass_column_wip => 1 },
                { name => 'standard' },
            ],
        }
    );
    ok( eval { App::karr::Config->validate($data) },
        'a class carrying wip_limit: -1 validates' )
        or diag $@;

    # The removal must loosen, never tighten: an entry that is not a mapping,
    # and a class list karr does model wrongly, are still refused.
    ok( !eval {
            App::karr::Config->validate(
                App::karr::Config->effective_config(
                    { board => { name => 'X' }, classes => [ { wip_limit => 1 } ] } ) );
        },
        'a class entry with no name is still invalid'
    );
    like( $@, qr/every class needs a name/, 'and says which check failed' );
};

subtest '(b+c) a board that carries the key keeps working, and keeps the key' => sub {
    my $repo = _legacy_board( _board_repo() );

    my $show = _run_karr( $repo, 'config', 'show' );
    is( $show->{exit}, 0, 'config show exits 0' ) or diag $show->{stderr};
    like( $show->{stdout}, qr/^classes\s+expedite \(bypass_column_wip: 1, wip_limit: -1\), standard$/m,
        'the stored keys are shown as configured, not hidden' );

    is( _run_karr( $repo, 'create', '--title', 'Legacy card', '--class', 'expedite' )->{exit},
        0, 'a card can still be created on such a board' );
    is( _run_karr( $repo, 'list' )->{exit}, 0, 'list still works' );
    is( _run_karr( $repo, 'move', '1', 'todo' )->{exit}, 0, 'a status change still works' );

    # The config write path is the one that runs validate.
    my $set = _run_karr( $repo, 'config', 'set', 'claim_timeout', '2h' );
    is( $set->{exit}, 0, 'a config write on such a board still succeeds' )
        or diag $set->{stderr};
    unlike( $set->{stderr}, qr/wip_limit/, 'no complaint about the leftover key' );

    my $after = _overrides($repo);
    is( $after->{claim_timeout}, '2h', 'the write landed' );
    is_deeply(
        $after->{classes},
        [   { name => 'expedite', wip_limit => -1, bypass_column_wip => 1 },
            { name => 'standard' },
        ],
        'and the leftover keys ride along untouched -- karr does not scrub what it stopped reading'
    ) or diag explain $after;

    # And it is still typed correctly on the way out: bypass_column_wip stays in
    # the boolean list even though karr no longer writes it, because a board that
    # carries it materializes it -- and go-yaml refuses to unmarshal `1` into a
    # Go bool, which would make the whole view unreadable to kanban-md (#60).
    is( _run_karr( $repo, 'materialize' )->{exit}, 0, 'materialize exits 0' );
    my $raw = path($repo)->child('config.yml')->slurp_utf8;
    like( $raw, qr/^\s*(?:-\s*)?bypass_column_wip:\s*true\s*$/m,
        'the leftover boolean is written as a YAML boolean, not as 1' );
    like( $raw, qr/^\s*(?:-\s*)?wip_limit:\s*-1\s*$/m,
        'and the leftover number goes out as it went in' );
};

subtest '(d) a file view cannot put the key back in' => sub {
    my $repo = _board_repo();
    # Import refuses an empty file view outright, so the board needs a card
    # before the round trip can say anything about its config.
    is( _run_karr( $repo, 'create', '--title', 'A card' )->{exit}, 0, 'setup: one card' );
    my $before = _overrides($repo);

    is( _run_karr( $repo, 'materialize' )->{exit}, 0, 'materialize exits 0' );
    my $config = path($repo)->child('config.yml');
    my $yaml   = $config->slurp_utf8;
    unlike( $yaml, qr/wip/, 'the view karr writes carries no WIP key of its own' );

    # What kanban-md leaves behind: it regenerates the class list from its own
    # defaults on every load, so the two keys reappear in the view even though
    # karr never wrote them.
    $yaml =~ s/^- name: expedite$/- name: expedite\n  wip_limit: 1\n  bypass_column_wip: true/m
        or die 'fixture no longer carries a bare expedite class';
    $config->spew_utf8($yaml);

    is( _run_karr( $repo, 'import', '--yes' )->{exit}, 0, 'import --yes exits 0' );
    is_deeply( _overrides($repo), $before,
        "kanban-md's class WIP defaults are not adopted as a board override" )
        or diag explain _overrides($repo);
};

done_testing;
