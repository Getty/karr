use strict;
use warnings;
use Test::More;
use B ();

use App::karr::Role::BoardAccess;
use App::karr::Role::BoardDiscovery;
use App::karr::Role::ClaimTimeout;
use App::karr::Role::CliArgs;
use App::karr::Role::ExitCodes;
use App::karr::Role::Output;
use App::karr::Role::SyncLifecycle;
use App::karr::Role::TaskMutation;

# Ticket #38: a Moo::Role composes *every* sub in its package into its
# consumers, imported ones included. App::karr::Role::BoardDiscovery said
# `use Path::Tiny;` and `use Carp qw( croak );`, and
# App::karr::Role::SyncLifecycle said the second one, so on the pre-fix tree:
#
#   $ perl -Ilib -e 'use App::karr::Cmd::List;
#       print App::karr::Cmd::List->can($_) ? "$_ YES\n" : "$_ no\n"
#         for qw( path croak )'
#   path YES
#   croak YES
#
# Nothing called either one -- the damage is latent, not broken. It is a
# collision hazard: the first command class that wants an attribute named
# `path` would silently fight an inherited Path::Tiny constructor, and
# `$cmd->croak(...)` is nonsense that type-checks fine. namespace::clean is not
# available as a cure (CLAUDE.md rules it out in this dist: it is incompatible
# with MooX::Options), so the rule is that a role loads its dependencies with an
# explicit empty import list and qualifies the call at the site, the way
# App::karr::Role::Output and App::karr::Role::TaskMutation already do.
#
# The tests below are written against the ROLE PACKAGES rather than against one
# command class, because the leak is a property of the role: whatever sits in
# its symbol table lands on all ~20 consumers.

# Sugar the object system installs into every role package. Not an import karr
# chose, not karr's to remove, and identifiable by where the sub actually lives
# rather than by name -- so a karr sub that happens to be called `has` would
# still be seen.
my $FRAMEWORK = qr{
    \A (?: Moo::Role
         | MooX::Options (?: ::\w+ )*
         | MooX::Locale::Passthrough
      ) \z
}x;

# Imports that leak today, are NOT part of this ticket, and are recorded here so
# that a NEW one fails this test instead of joining them unnoticed:
# App::karr::Role::ClaimTimeout and App::karr::Role::TaskMutation both say
# `use Time::Piece;`, which puts its localtime/gmtime replacements on every
# mutating command class. Delete the entry when a role stops leaking it.
my %KNOWN_LEAK = (
    'App::karr::Role::ClaimTimeout'  => { map { $_ => 'Time::Piece' } qw( gmtime localtime ) },
    'App::karr::Role::TaskMutation'  => { map { $_ => 'Time::Piece' } qw( gmtime localtime ) },
);

my @ROLES = map { "App::karr::Role::$_" } qw(
    BoardAccess BoardDiscovery ClaimTimeout CliArgs
    ExitCodes Output SyncLifecycle TaskMutation
);

# Every sub in $pkg's symbol table, paired with the package it was really
# defined in. That second half is what tells an import apart from a definition.
sub subs_with_origin {
    my ($pkg) = @_;
    no strict 'refs';
    my %origin;
    for my $name ( sort keys %{"${pkg}::"} ) {
        next unless defined &{"${pkg}::$name"};
        $origin{$name} = B::svref_2object( \&{"${pkg}::$name"} )->GV->STASH->NAME;
    }
    return %origin;
}

subtest 'the two imports named in the ticket are gone from the role packages' => sub {
    my %board = subs_with_origin('App::karr::Role::BoardDiscovery');
    my %sync  = subs_with_origin('App::karr::Role::SyncLifecycle');

    ok !exists $board{path},  'BoardDiscovery no longer holds Path::Tiny::path';
    ok !exists $board{croak}, 'BoardDiscovery no longer holds Carp::croak';
    ok !exists $sync{croak},  'SyncLifecycle no longer holds Carp::croak';

    # They went by losing the import, not the dependency: both roles still use
    # these modules, qualified at the call site.
    ok $INC{'Path/Tiny.pm'},      'Path::Tiny is still loaded';
    ok $INC{'App/karr/Error.pm'}, 'App::karr::Error is still loaded';

    # And the replacement must not have re-created the problem one name over:
    # App::karr::Error is imported by name in the Cmd/* classes, but a role has
    # to load it with `()` and call App::karr::Error::user_error.
    ok !exists $board{user_error}, 'BoardDiscovery did not swap croak for an imported user_error';
    ok !exists $sync{user_error},  'SyncLifecycle did not either';
};

# Deliberately not a real command class: MooX::Cmd::Role does `use Carp;`
# upstream and composes croak into every one of them, which karr cannot fix from
# here and which would mask a regression in karr's own roles.
{
    package RoleConsumer;
    use Moo;
    use MooX::Options;
    with 'App::karr::Role::BoardDiscovery', 'App::karr::Role::SyncLifecycle';
}

subtest 'a consumer of the board roles inherits none of it' => sub {
    for my $leak (qw( path croak user_error clean_error )) {
        ok( !RoleConsumer->can($leak),
            "a consumer of BoardDiscovery + SyncLifecycle has no ->$leak" );
    }

    # The roles are still doing their job, i.e. the cleanup did not empty them.
    ok( RoleConsumer->can($_), "...but still has ->$_" )
        for qw( git_root store config sync_before sync_after );
};

subtest 'no role imports anything new into its consumers' => sub {
    for my $pkg (@ROLES) {
        my %origin = subs_with_origin($pkg);
        my $known  = $KNOWN_LEAK{$pkg} || {};

        my @leaked;
        for my $name ( sort keys %origin ) {
            my $home = $origin{$name};
            next if $home eq $pkg;             # defined right here
            next if $home =~ /^App::karr::/;   # karr's own, composed on purpose
            next if $home =~ $FRAMEWORK;       # Moo / MooX sugar
            next if ( $known->{$name} || '' ) eq $home;
            push @leaked, "$name (imported from $home)";
        }

        is_deeply \@leaked, [], "$pkg composes no unaccounted import"
            or diag "leaked into $pkg: @leaked";

        # Keep the allow-list honest: an entry that no longer describes reality
        # has to be deleted, not left to excuse a future import of the same name.
        for my $name ( sort keys %$known ) {
            is $origin{$name}, $known->{$name},
                "$pkg still leaks $name from $known->{$name} (known, out of #38's scope)";
        }
    }
};

done_testing;
