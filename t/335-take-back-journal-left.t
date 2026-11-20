#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use App::karr::Git;
use App::karr::Task;

# Ticket k333 (review finding R1): take_back_journal used to return only the
# refs it put back, so a ref it could NOT put back -- another process wrote it
# since, the reset threw, the repository would not open -- vanished from the
# answer, and a denied command said "Nothing was changed" over a card that was
# still in the clone. It now answers { back => [...], left => [...] }, both
# sorted: `left` is what this object changed and did not put back.

sub scene {
    my $d = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', "$d/a" );
    system( 'git', '-C', "$d/a", 'config', 'user.email', 'a@karr.test' );
    system( 'git', '-C', "$d/a", 'config', 'user.name',  'agent-a' );
    my $git = App::karr::Git->new( dir => "$d/a" );
    $git->write_ref( 'refs/karr/config', "board:\n  name: demo\n" );
    return $git;
}

sub task {
    return App::karr::Task->new(
        id => $_[0], title => "t$_[0]", status => 'todo',
        priority => 'high', class => 'standard', body => '',
    );
}

my $NEXT = 'refs/karr/meta/next-id';
sub card { return "refs/karr/tasks/$_[0]/data" }

subtest 'no journal open: both lists empty' => sub {
    my $git = scene();
    is_deeply $git->take_back_journal, { back => [], left => [] }, 'a hash with two empty lists';
    is_deeply $git->take_back_journal( next_id => 1 ), { back => [], left => [] }, 'also with next_id';
};

subtest 'a clean take-back: put back, nothing left' => sub {
    my $git = scene();
    $git->start_journal;
    $git->save_task_ref( task(1) );
    is_deeply $git->take_back_journal, { back => [ card(1) ], left => [] }, 'the card is back, nothing left';
    ok !$git->ref_exists( card(1) ), 'and it is gone from the clone';
};

subtest 'next_id off: the kept counter is in neither list' => sub {
    my $git = scene();
    $git->start_journal;
    $git->save_task_ref( task(1) );
    $git->write_ref( $NEXT, "2\n" );
    is_deeply $git->take_back_journal, { back => [ card(1) ], left => [] },
        'the counter is neither back nor left: keeping it is the intent';
    ok $git->ref_exists($NEXT), 'and it is still there';
};

subtest 'next_id on: the counter is put back' => sub {
    my $git = scene();
    $git->start_journal;
    $git->save_task_ref( task(1) );
    $git->write_ref( $NEXT, "2\n" );
    is_deeply $git->take_back_journal( next_id => 1 ), { back => [ sort { $a cmp $b } $NEXT, card(1) ], left => [] },
        'card and counter back, sorted';
    ok !$git->ref_exists($NEXT), 'the counter is gone';
};

subtest 'a repository that cannot be opened: every changed ref is left' => sub {
    my $git = scene();
    $git->start_journal;
    $git->save_task_ref( task(1) );
    $git->write_ref( $NEXT, "2\n" );
    my $took;
    {
        no warnings 'redefine';
        local *App::karr::Git::_repo = sub { undef };
        $took = $git->take_back_journal( next_id => 1 );
    }
    is_deeply $took, { back => [], left => [ sort { $a cmp $b } $NEXT, card(1) ] },
        'nothing put back, the counter in left (next_id was asked for)';
    ok $git->ref_exists( card(1) ), 'the card is still there';
};

subtest 'a repository that cannot be opened, next_id off: the counter stays in neither list' => sub {
    my $git = scene();
    $git->start_journal;
    $git->save_task_ref( task(1) );
    $git->write_ref( $NEXT, "2\n" );
    my $took;
    {
        no warnings 'redefine';
        local *App::karr::Git::_repo = sub { undef };
        $took = $git->take_back_journal;
    }
    is_deeply $took, { back => [], left => [ card(1) ] }, 'only the card is left';
};

subtest 'a second writer on the ref: it is left, and its write stands' => sub {
    my $git = scene();
    $git->start_journal;
    $git->save_task_ref( task(1) );
    $git->save_task_ref( task(2) );
    {
        local $git->{_journal_paused} = 1;
        $git->write_ref( card(1), "---\nid: 1\ntitle: second writer\n---\n" );
    }
    is_deeply $git->take_back_journal, { back => [ card(2) ], left => [ card(1) ] },
        'one back, the overwritten one left';
    like $git->read_ref( card(1) ), qr/second writer/, 'the other writer\'s version stands';
    ok !$git->ref_exists( card(2) ), 'the untouched one is gone';
};

subtest 'a second writer that deleted the ref: left as well, still deleted' => sub {
    my $git = scene();
    $git->start_journal;
    $git->save_task_ref( task(1) );
    {
        local $git->{_journal_paused} = 1;
        $git->delete_ref( card(1) );
    }
    is_deeply $git->take_back_journal, { back => [], left => [ card(1) ] },
        'what is no longer this object\'s write is not put back, and is reported';
    ok !$git->ref_exists( card(1) ), 'and stays gone';
};

subtest 'a reset that throws: left' => sub {
    my $git = scene();
    $git->save_task_ref( task(1) );    # an older version, so the take-back is a reset
    $git->start_journal;
    $git->write_ref( card(1), $git->read_ref( card(1) ) . "\nchanged\n" );
    my $new  = $git->read_ref( card(1) );
    my $repo = $git->_repo;
    my $took;
    {
        no strict 'refs';
        no warnings 'redefine';
        my $rclass   = ref $repo;
        my $o_create = $rclass->can('reference_create');
        local *{"${rclass}::reference_create"} = sub {
            die "simulated reset failure\n" if $_[1] eq card(1);
            goto &$o_create;
        };
        $took = $git->take_back_journal;
    }
    is_deeply $took, { back => [], left => [ card(1) ] }, 'the ref whose reset failed is in left';
    is $git->read_ref( card(1) ), $new, 'and still carries the change';
};

subtest 'a delete that throws: left' => sub {
    my $git = scene();
    $git->start_journal;
    $git->save_task_ref( task(1) );
    my $repo = $git->_repo;
    my $took;
    {
        no strict 'refs';
        no warnings 'redefine';
        my $refclass = ref $repo->reference( card(1) );
        my $o_delete = $refclass->can('delete');
        local *{"${refclass}::delete"} = sub {
            die "simulated delete failure\n" if $_[0]->name eq card(1);
            goto &$o_delete;
        };
        $took = $git->take_back_journal;
    }
    is_deeply $took, { back => [], left => [ card(1) ] }, 'in left, not silently dropped';
    ok $git->ref_exists( card(1) ), 'and still here';
};

done_testing;
