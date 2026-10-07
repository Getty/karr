use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use App::karr::Git;
use App::karr::Task;

# k324: a pull that did not finish used to leave the tracking mirror at the
# remote's new state while the board still held the old one.
#
# The fetch wrote straight into refs/karr-remote/<remote>/*, and the
# reconciliation that follows is what brings the board in line with it. A pull
# that stopped in between -- the fetch reported a failure after its refs had
# landed (a CLI fallback killed at the transport timeout), or the process died
# -- left a mirror claiming a remote state this clone never reconciled against.
# The next pull then read every stale local ref as L != T, R == T -- "unpushed
# local work: keep it" -- and the push behind it wrote the old card over the
# remote's newer one, in every clone, at exit 0. In a fresh clone the same
# state made the whole board come out as locally deleted.
#
# What is pinned here is the invariant, from the outside: whatever a pull that
# stopped left behind, the next complete pull adopts the remote's version and
# the push after it does not take it back.

sub clones {
    my (@names) = @_;
    my $work = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', '--bare', "$work/origin.git" );
    my @git;
    for my $name (@names) {
        system("git clone -q '$work/origin.git' '$work/$name' 2>/dev/null");
        system( 'git', '-C', "$work/$name", 'config', 'user.email',
            "$name\@karr.test" );
        system( 'git', '-C', "$work/$name", 'config', 'user.name',
            "agent-$name" );
        push @git, App::karr::Git->new( dir => "$work/$name" );
    }
    return ( $work, @git );
}

sub task {
    my ( $id, $title ) = @_;
    return App::karr::Task->new(
        id       => $id,
        title    => $title,
        status   => 'todo',
        priority => 'high',
        class    => 'standard',
        body     => '',
    );
}

# A publishes a board with $count cards; every other clone pulls it; A then
# retitles every card and publishes that.
sub board_then_edit {
    my ( $count, $a, @others ) = @_;
    $a->write_ref( 'refs/karr/config',       "board:\n  name: demo\n" );
    $a->write_ref( 'refs/karr/meta/next-id', ( $count + 1 ) . "\n" );
    $a->save_task_ref( task( $_, "Original $_" ) ) for 1 .. $count;
    $a->ensure_board_id_ref;
    ok $a->push, 'A publishes the board';
    ok $_->pull, 'the other clone syncs it in' for @others;

    for my $id ( 1 .. $count ) {
        my $card = $a->load_task_ref($id);
        $card->title("Edited $id");
        $a->save_task_ref($card);
    }
    ok $a->push, 'A publishes its edits';
    return;
}

sub titles {
    my ( $git, $count ) = @_;
    return [ map { my $card = $git->load_task_ref($_); $card ? $card->title : undef }
            1 .. $count ];
}

# The remote as a third party sees it, not as either clone remembers it.
sub remote_titles {
    my ( $work, $count ) = @_;
    my ( undef, $fresh ) = ( undef, undef );
    my $dir = tempdir( CLEANUP => 1 );
    system("git clone -q '$work/origin.git' '$dir/fresh' 2>/dev/null");
    $fresh = App::karr::Git->new( dir => "$dir/fresh" );
    $fresh->pull or return [];
    return titles( $fresh, $count );
}

# ---------------------------------------------------------------------
subtest 'a fetch that reports failure after its refs landed' => sub {
    my ( $work, $a, $b ) = clones(qw( a b ));
    board_then_edit( 2, $a, $b );

    {
        # The transport did its work and is then reported as failed -- what a
        # CLI fallback killed at the timeout looks like from inside pull.
        no warnings 'redefine';
        my $real = \&App::karr::Git::_fetch_refspecs;
        local *App::karr::Git::_fetch_refspecs = sub {
            $real->(@_);
            $_[0]{_last_error} = 'git fetch (CLI fallback) timed out';
            return 0;
        };
        ok !$b->pull, 'the pull reports the failure';
    }
    is_deeply titles( $b, 2 ), [ 'Original 1', 'Original 2' ],
        'and the board is untouched by it';

    ok $b->pull, 'the next pull goes through';
    is_deeply titles( $b, 2 ), [ 'Edited 1', 'Edited 2' ],
        'and adopts the remote cards rather than keeping the stale ones';

    ok $b->push, 'B pushes';
    is_deeply remote_titles( $work, 2 ), [ 'Edited 1', 'Edited 2' ],
        'and the remote still holds what A published';
};

# ---------------------------------------------------------------------
subtest 'a pull that died between the fetch and the reconciliation' => sub {
    my ( $work, $a, $b ) = clones(qw( a b ));
    board_then_edit( 2, $a, $b );

    # The fetch half of pull, and nothing after it.
    ok $b->_fetch_refspecs( 'origin', [ $b->_fetch_refspec('origin') ],
        prune => 1 ), 'the fetch lands';
    is_deeply titles( $b, 2 ), [ 'Original 1', 'Original 2' ],
        'the board has not been reconciled';

    ok $b->pull, 'the next pull goes through';
    is_deeply titles( $b, 2 ), [ 'Edited 1', 'Edited 2' ],
        'and adopts the remote cards';

    ok $b->push, 'B pushes';
    is_deeply remote_titles( $work, 2 ), [ 'Edited 1', 'Edited 2' ],
        'and the remote still holds what A published';
};

# ---------------------------------------------------------------------
subtest 'a pull that died halfway through the reconciliation' => sub {
    my ( $work, $a, $b ) = clones(qw( a b ));
    board_then_edit( 3, $a, $b );

    {
        no warnings 'redefine';
        my $real  = \&App::karr::Git::_adopt_remote_ref;
        my $calls = 0;
        local *App::karr::Git::_adopt_remote_ref = sub {
            die "killed\n" if ++$calls > 1;
            return $real->(@_);
        };
        ok !eval { $b->pull; 1 }, 'the pull dies after its first ref';
    }
    my $half = titles( $b, 3 );
    is scalar( grep { /^Edited/ } @$half ), 1, 'one card made it across'
        or diag explain $half;

    ok $b->pull, 'the next pull goes through';
    is_deeply titles( $b, 3 ), [ 'Edited 1', 'Edited 2', 'Edited 3' ],
        'and finishes the job';

    ok $b->push, 'B pushes';
    is_deeply remote_titles( $work, 3 ), [ 'Edited 1', 'Edited 2', 'Edited 3' ],
        'and the remote still holds what A published';
};

# ---------------------------------------------------------------------
subtest 'a fresh clone whose first pull died after the fetch' => sub {
    my ( $work, $a, $c ) = clones(qw( a c ));
    board_then_edit( 2, $a );

    ok $c->_fetch_refspecs( 'origin', [ $c->_fetch_refspec('origin') ],
        prune => 1 ), 'the fetch lands';
    is_deeply [ $c->list_refs('refs/karr/') ], [],
        'and no board ref exists yet';

    ok $c->pull, 'the next pull goes through';
    is_deeply titles( $c, 2 ), [ 'Edited 1', 'Edited 2' ],
        'and the board is there, not read as deleted here';

    ok $c->push, 'C pushes';
    is_deeply remote_titles( $work, 2 ), [ 'Edited 1', 'Edited 2' ],
        'and the remote board is intact';
};

done_testing;
