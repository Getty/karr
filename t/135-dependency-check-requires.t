use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path );

use App::karr::Role::DependencyCheck;
use App::karr::Role::TaskMutation;

# Ticket #128. App::karr::Role::DependencyCheck called four methods it never
# declared -- store and find_task from check_dependencies, usage_error from the
# two set-time helpers, quiet from dependency_report -- and composed cleanly
# into anything at all:
#
#   $ perl -Ilib -e 'package Bare; use Moo;
#       with "App::karr::Role::DependencyCheck"; print "composed\n"'
#   composed
#
# It only worked because every consumer happened to bring the supplying roles
# along. App::karr::Role::TaskMutation composes this role, so the next command
# on the mutation path would have inherited the same four methods and found out
# at the moment a warning was due -- a "Can't locate object method" from inside
# a compare-and-swap callback, on the run where a dependency was unsatisfied and
# --json was off, rather than a composition error at compile time.
#
# The point of a `requires` is that it fails at composition, so that is what
# these tests reproduce: a consumer without the suppliers must not compose.

my @REQUIRED = qw( store find_task usage_error quiet );

# The one call dependency_report makes that is deliberately NOT required, and
# why: App::karr::Cmd::Create composes this role for parse_dependency_ids and
# assert_dependencies_exist alone, and has no --json of its own. See the last
# subtest, which is the tripwire for that ever changing.
my @UNDECLARED_BY_DESIGN = qw( json );

# A fresh package each time: Moo caches what it has applied to a class, and a
# second failed composition into the same name would not be the same experiment.
my $bare_seq = 0;

sub compose_bare {
    my ($role) = @_;
    my $pkg = 'BareConsumer' . ++$bare_seq;
    my $ok  = eval "package $pkg; use Moo; with '$role'; 1";
    return ( $ok, $@ );
}

subtest 'composing DependencyCheck without its suppliers is a composition error' => sub {
    my ( $ok, $err ) = compose_bare('App::karr::Role::DependencyCheck');

    ok !$ok, 'a class that supplies none of them refuses to compose the role';
    like $err, qr/\bmissing\b/, '...and says so as a missing-method error';
    like $err, qr/\b\Q$_\E\b/, "...naming $_" for @REQUIRED;
};

subtest 'the requirement reaches consumers of TaskMutation' => sub {
    # This is the case the ticket is actually about: nobody writes `with
    # DependencyCheck` by hand on a new mutation command, they write `with
    # TaskMutation` and get it. Role::Tiny hands an unmet requires of a composed
    # role up to whoever composes the composer, so the error has to arrive here
    # too even though TaskMutation declares nothing itself.
    my ( $ok, $err ) = compose_bare('App::karr::Role::TaskMutation');

    ok !$ok, 'a bare consumer of TaskMutation refuses to compose too';
    like $err, qr/\b\Q$_\E\b/, "...naming $_" for @REQUIRED;
};

subtest 'a consumer that supplies them still gets the role' => sub {
    # The negative tests above are only worth something if the requirement is
    # satisfiable by exactly these four names and nothing else -- otherwise they
    # would pass just as well against a role that cannot be composed at all.
    my $ok = eval q{
        package StubConsumer;
        use Moo;
        sub store       { }
        sub find_task   { }
        sub usage_error { }
        sub quiet       { }
        with 'App::karr::Role::TaskMutation';
        1;
    };
    ok $ok, 'the four stubs are enough to compose TaskMutation' or diag $@;

    ok( StubConsumer->can($_), "...and it has ->$_" )
        for qw( check_dependencies dependency_report parse_dependency_ids
                assert_dependencies_exist apply_status_change update_task_guarded );
};

subtest 'every command that composes the role today still composes it' => sub {
    # Moo reports a missing requires when the class is compiled, so loading each
    # consumer is the whole test: a name added to the list that one of them does
    # not have breaks `karr <cmd>` outright, not just this file.
    for my $cmd (qw( Create Move Edit Handoff Pick Delete Archive )) {
        my $pkg = "App::karr::Cmd::$cmd";
        ok eval("require $pkg; 1"), "App::karr::Cmd::$cmd composes" or diag $@;
    }
};

subtest 'the declared list still covers everything the role calls' => sub {
    # A requires list is only as good as its last edit: the next `$self->foo` in
    # this role would put the hole back without touching anything below. So read
    # the calls out of the source and hold the declaration against them.
    my $file = path( $INC{'App/karr/Role/DependencyCheck.pm'} );
    ok $file->exists, 'found the role source to read' or return;

    my $src = $file->slurp_utf8;
    # POD and comments carry example code -- `$self->parse_dependency_ids(
    # '--depends-on', $self->depends_on )` among them -- and prose that mentions
    # method names. The declaration is about what actually executes.
    $src =~ s/^=\w+.*?^=cut\b.*?$//msg;
    $src =~ s/^\s*#.*$//mg;

    my %called = map { $_ => 1 } $src =~ /\$self->(\w+)/g;
    my %own    = map { $_ => 1 } ( $src =~ /^sub (\w+)/mg, $src =~ /^has (\w+)/mg );

    my %declared =
      map { $_ => 1 } @{ $Role::Tiny::INFO{'App::karr::Role::DependencyCheck'}{requires} || [] };

    is_deeply [ sort keys %declared ], [ sort @REQUIRED ],
        'the role declares exactly the expected requires';

    my @undeclared =
      sort grep { !$own{$_} && !$declared{$_} } keys %called;

    # When this list shrinks, the name that left it can be required outright --
    # move it up into the requires line instead of loosening the test. When it
    # grows, the new call is a method nobody promised the role would have.
    is_deeply \@undeclared, [ sort @UNDECLARED_BY_DESIGN ],
        'the only call left undeclared is the documented exception';
};

subtest 'why json is the exception' => sub {
    # App::karr::Cmd::Create is the consumer that keeps json out of the list: it
    # composes the role for the two set-time helpers and never reaches
    # dependency_report, so requiring json would refuse a command that is using
    # the role correctly. Splitting the set-time helpers from the reporting half
    # -- or giving create a --json -- is what lets json be required, and this is
    # the test that will say so when either happens.
    require App::karr::Cmd::Create;

    ok( App::karr::Cmd::Create->can($_), "create supplies ->$_" ) for @REQUIRED;

    ok( !App::karr::Cmd::Create->can('json'),
        'create has no ->json, which is why json cannot be required yet' );

    ok( App::karr::Cmd::Create->can('parse_dependency_ids'),
        'and it does use the set-time half of the role' );
};

done_testing;
