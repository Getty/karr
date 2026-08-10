# ABSTRACT: Role providing minimal board discovery and config access

package App::karr::Role::BoardDiscovery;
our $VERSION = '0.500';
use Moo::Role;
use MooX::Options;
# Both loaded without importing, and every call below is qualified. A Moo::Role
# composes every sub in its package into its consumers, imported ones included,
# so `use Path::Tiny;` here made Path::Tiny's path() a method on ~20 command
# classes -- a silent collision waiting for the first command that wants an
# attribute called `path` (#38). App::karr::Role::Output states the same rule.
use Path::Tiny ();
use App::karr::Error ();
use App::karr::Role::ExitCodes;
use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Config;

# Every command that composes this role (directly or via BoardAccess) inherits
# the exit-code contract's option-parse half: an unknown option / bad option
# value exits 2, not 1. See App::karr::Role::ExitCodes and ADR 0002. The four
# board-less commands (agent-name, get-refs, set-refs, skill) compose ExitCodes
# on their own.
with 'App::karr::Role::ExitCodes';

=head1 DESCRIPTION

This role provides the minimal interface for discovering the board's Git
repository and BoardStore. It provides:

=over 4

=item * C<dir> — CLI option overriding the directory discovery starts from

=item * C<git_root> — path to the Git repository (walks up from C<dir> or CWD)

=item * C<store> — L<App::karr::BoardStore> instance backed by the Git repo

=item * C<git> — shortcut to C<< $self->store->git >> (lazy)

=item * C<config> — shortcut to C<< $self->store->effective_config >> (lazy)

=back

Commands that need the sync lifecycle should also compose
L<App::karr::Role::SyncLifecycle>.

=cut

# The board-discovery seed. Available on every command that composes this role
# (directly or via BoardAccess), so both `karr CMD --dir PATH` and, via the
# MooX::Cmd command_chain, the root form `karr --dir PATH CMD` resolve the same
# board. format=s also registers dir in _options_data, so positional_args never
# mistakes `--dir PATH` (or its value) for a positional argument.
option dir => (
  is        => 'ro',
  format    => 's',
  doc       => 'Path used as the starting point for Git repository discovery',
  predicate => 1,
);

has git_root => (
    is  => 'lazy',
    isa => sub {
        die "git_root must be a Path::Tiny object" unless eval { $_[0]->isa('Path::Tiny') };
    },
);

has store => (
    is => 'lazy',
);

has git => (
    is => 'lazy',
);

has config => (
    is => 'lazy',
);

# Actor role for the activity log identity: 'user' (default) or 'agent'.
# Carried to nested karr calls via the KARR_ROLE env var (foundation sets
# 'agent'); a --role option on a command overrides this attribute.
has role => (
    is      => 'lazy',
    builder => sub { $ENV{KARR_ROLE} || 'user' },
);

# The effective --dir for this command. A command's own --dir (the
# `karr CMD --dir PATH` form) always wins. Otherwise, when MooX::Cmd dispatched
# us as a subcommand, the root form `karr --dir PATH CMD` leaves --dir on an
# ancestor in the command_chain rather than on this Cmd instance, so adopt it
# from there. Consulted from the lazy _build_git_root builder, so the value is
# picked up before git_root/store are ever built -- including from
# SyncLifecycle's sync_before, which triggers store.
sub _effective_dir {
    my ($self) = @_;
    return $self->dir if $self->has_dir;

    if ( $self->can('command_chain') && ( my $chain = $self->command_chain ) ) {
        for my $cmd (@$chain) {
            next if $cmd == $self;
            return $cmd->dir if $cmd->can('has_dir') && $cmd->has_dir;
        }
    }
    return undef;
}

sub _build_git_root {
    my ($self) = @_;

    my $dir = $self->_effective_dir;
    my $start = defined $dir
        ? Path::Tiny::path($dir)->absolute
        : Path::Tiny::path('.')->absolute;

    while (1) {
        my $git = App::karr::Git->new( dir => $start->stringify );
        my $root = $git->repo_root;
        return $root if $root;
        last if $start->is_rootdir;
        $start = $start->parent;
    }
    # Not croak: this is the first thing anyone who runs karr outside a
    # repository sees, and Carp would append this builder's own file and line
    # to it (#77). Where karr keeps its source is not the reader's problem.
    App::karr::Error::user_error("Not a git repository. karr requires Git.");
}

sub _build_store {
    my ($self) = @_;
    my $git = App::karr::Git->new( dir => $self->git_root->stringify );
    return App::karr::BoardStore->new( git => $git );
}

sub _build_git {
    my ($self) = @_;
    return $self->store->git;
}

sub _build_config {
    my ($self) = @_;
    my $merged = $self->store->effective_config;
    return App::karr::Config->from_merged($merged);
}

=head2 require_board

    $self->sync_before;
    $self->require_board;

Refuses to go on when this repository has no initialized board. Every command
that writes to C<refs/karr/*> calls it, because without the check a C<karr
create> typed in the wrong directory silently seeded a partial board in an
unrelated repository -- and that partial board then locked C<karr init> out of
it permanently (#62).

Call it B<after> C<sync_before>, never before: on a fresh clone the board only
exists on the remote until the pull has run, and checking first would report a
board that is merely not fetched yet as missing. The four commands that read or
clean up raw refs (C<backup>, C<destroy>, C<materialize>, C<repair>) ask
L<App::karr::BoardStore/has_board_refs> instead, so they can still deal with a
half-board left behind by an older karr.

=cut

sub require_board {
    my ($self) = @_;
    die "No karr board found. Run 'karr init' to create one.\n"
        unless $self->store->board_exists;
    return 1;
}

1;