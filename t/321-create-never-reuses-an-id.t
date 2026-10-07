use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use App::karr::Git;
use App::karr::Task;

# k321: `karr create` trusted the id counter blindly. With
# refs/karr/meta/next-id behind the highest task id -- a remote whose counter
# an older push wrote back while a newer card stayed, a hand-repaired ref --
# the next create was handed an id a card already held and wrote over it, at
# exit 0, with "Created task N".
#
# Three guarantees are pinned, each of which would have been enough alone:
#
#   * the allocator never hands out an id at or below the highest task ref;
#   * create writes its ref create-only, so an id that turns out to be taken
#     costs a second allocation and not a card;
#   * a pull that leaves the counter at or below the highest task id moves it
#     past it.
#
# Never the developer's own board: every repository below is a tempdir.

sub repo {
    my $dir = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $dir );
    system( 'git', '-C', $dir, 'config', 'user.email', 'k321@karr.test' );
    system( 'git', '-C', $dir, 'config', 'user.name',  'k321' );
    system( 'git', '-C', $dir, 'commit', '-q', '--allow-empty', '-m', 'init' );
    return $dir;
}

sub karr_ok {
    my ( $dir, $what, @argv ) = @_;
    my $r = run_karr( $dir, @argv );
    is( $r->{exit}, 0, $what )
        or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";
    return $r;
}

sub rev {
    my ( $dir, $ref ) = @_;
    my $oid = `git -C '$dir' rev-parse '$ref'`;
    chomp $oid;
    return $oid;
}

# ---------------------------------------------------------------------
subtest 'a counter set back under an existing card' => sub {
    my $dir = repo();
    karr_ok( $dir, 'init', 'init', '--name', 'k321' );
    karr_ok( $dir, 'create first',  'create', 'first' );
    karr_ok( $dir, 'create second', 'create', 'second' );
    my $old = rev( $dir, 'refs/karr/meta/next-id' );
    karr_ok( $dir, 'create third', 'create', 'third original', '--body',
        'precious' );
    system( 'git', '-C', $dir, 'update-ref', 'refs/karr/meta/next-id', $old );

    my $git = App::karr::Git->new( dir => $dir );
    is $git->read_next_id_ref, 3, 'the counter says 3, and card 3 exists';

    my $r = karr_ok( $dir, 'create newcomer', 'create', 'newcomer' );
    like $r->{stdout}, qr/Created task 4: newcomer/,
        'the newcomer gets a fresh id';

    my $third = $git->load_task_ref(3);
    is $third->title, 'third original', 'card 3 is still the original';
    is $third->body,  'precious',       'body and all';
    is $git->load_task_ref(4)->title, 'newcomer', 'and the newcomer is card 4';
    is $git->read_next_id_ref, 5, 'the counter is past both';
};

# ---------------------------------------------------------------------
subtest 'an id that turns out to be taken is not written over' => sub {
    my $dir = repo();
    karr_ok( $dir, 'init', 'init', '--name', 'k321' );
    karr_ok( $dir, 'create first', 'create', 'first', '--body', 'precious' );

    # An allocator that is wrong once: what any future door around the
    # counter would look like to create.
    my $r;
    {
        no warnings 'redefine';
        my $real  = \&App::karr::Git::allocate_next_id_ref;
        my $calls = 0;
        local *App::karr::Git::allocate_next_id_ref = sub {
            return 1 unless $calls++;
            return $real->(@_);
        };
        $r = karr_ok( $dir, 'create second', 'create', 'second' );
    }
    like $r->{stdout}, qr/Created task 2: second/, 'create allocated again';

    my $git = App::karr::Git->new( dir => $dir );
    is $git->load_task_ref(1)->title, 'first',    'card 1 is untouched';
    is $git->load_task_ref(1)->body,  'precious', 'body and all';
    is $git->load_task_ref(2)->title, 'second',   'and the new card is card 2';

    my $log = run_karr( $dir, 'log' );
    my @creates = $log->{stdout} =~ /create/g;
    is scalar(@creates), 2, 'one log entry per card, none for the lost write'
        or diag $log->{stdout};
};

# ---------------------------------------------------------------------
subtest 'a pull that brings in a counter behind the cards repairs it' => sub {
    my $work = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', '--bare', "$work/origin.git" );
    my %git;
    for my $name (qw( a b )) {
        system("git clone -q '$work/origin.git' '$work/$name' 2>/dev/null");
        system( 'git', '-C', "$work/$name", 'config', 'user.email',
            "$name\@karr.test" );
        system( 'git', '-C', "$work/$name", 'config', 'user.name', $name );
        $git{$name} = App::karr::Git->new( dir => "$work/$name" );
    }
    my ( $a, $b ) = @git{qw( a b )};

    $a->write_ref( 'refs/karr/config', "board:\n  name: demo\n" );
    $a->save_task_ref(
        App::karr::Task->new(
            id => $_, title => "card $_", status => 'todo',
            priority => 'medium', class => 'standard',
        )
    ) for 1 .. 3;
    # The remote the comment over _adopt_next_id_ref describes: three cards,
    # and a counter an older push left at 2.
    $a->write_ref( 'refs/karr/meta/next-id', "2\n" );
    ok $a->push, 'A publishes three cards and a counter of 2';

    ok $b->pull, 'B pulls';
    is_deeply [ $b->list_task_refs ], [ 1, 2, 3 ], 'B has the three cards';
    is $b->read_next_id_ref, 4, 'and a counter past them';
    is $b->allocate_next_id_ref, 4, 'so the next id is free';
};

done_testing;
