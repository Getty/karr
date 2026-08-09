# ABSTRACT: Ref-backed board storage for karr

package App::karr::BoardStore;
our $VERSION = '0.403';
use Moo;
use Path::Tiny qw( path );
use YAML::XS qw( DumpFile LoadFile );
use Time::Piece;
use App::karr::Config;
use App::karr::Task;

has git => (
    is       => 'ro',
    required => 1,
);

=head1 SYNOPSIS

    my $store = App::karr::BoardStore->new( git => $git );
    my $config = $store->load_config;
    my $id = $store->allocate_next_id;
    my @tasks = $store->load_tasks;

=head1 DESCRIPTION

L<App::karr::BoardStore> treats C<refs/karr/*> as the canonical board state.
It can merge sparse config overrides with code defaults, allocate numeric task
ids through a dedicated metadata ref, and materialize or serialize temporary
board views for command handlers that still work with files internally.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Git>, L<App::karr::Task>,
L<App::karr::Config>

=cut

sub board_exists {
    my ($self) = @_;
    return $self->git->ref_exists('refs/karr/config');
}

=head2 board_exists

True when this repository holds an initialized board, which means exactly one
thing: C<refs/karr/config> is there. It used to accept C<refs/karr/meta/next-id>
on its own as well, and that is how a stray C<karr create> in the wrong
directory produced a board that C<karr init> then refused to touch for good --
the half-board counted as existing, so the name, the statuses and the
F<.gitignore> entries could never be written (#62).

    die "No karr board found. Run 'karr init' to create one.\n"
        unless $store->board_exists;

=cut

sub has_board_refs {
    my ($self) = @_;
    my @refs = $self->list_karr_refs;
    return @refs ? 1 : 0;
}

=head2 has_board_refs

True when anything at all lives under C<refs/karr/>, initialized board or not.
This is the question the commands that clean up or read raw refs
(C<backup>, C<destroy>, C<materialize>, C<repair>) actually have: refusing them
on a half-board would strand the refs a pre-fix karr already left behind, with
no way to remove them from inside karr.

    my $anything_here = $store->has_board_refs;

=cut

sub load_config_overrides {
    my ($self) = @_;
    my $data = $self->git->read_config_ref;
    return ref $data eq 'HASH' ? $data : {};
}

sub load_config {
    my ($self) = @_;
    return App::karr::Config->effective_config( $self->load_config_overrides );
}

sub effective_config {
    my ($self) = @_;
    return $self->{_effective_config} //= $self->load_config;
}

sub all_status_names {
    my ($self) = @_;
    my $ec = $self->effective_config;
    return map { ref $_ ? $_->{name} : $_ } @{$ec->{statuses} // []};
}

=head2 all_status_names

Returns a list of all status names from the effective config.

    my @statuses = $store->all_status_names;

=cut

sub status_requires_claim {
    my ($self, $status_name) = @_;
    return App::karr::Config->from_merged( $self->effective_config )
        ->status_requires_claim($status_name);
}

=head2 status_requires_claim

Returns true if the given status requires a claim.

    if ($store->status_requires_claim('in-progress')) {
        # must use --claim to move here
    }

=cut

sub is_terminal_status {
    my ($self, $status_name) = @_;
    return App::karr::Config->is_terminal_status($status_name);
}

=head2 is_terminal_status

Returns true if the status is terminal (done or archived).

    unless ($store->is_terminal_status($task->status)) {
        # task is still active
    }

=cut

sub foundation_enabled {
    my ($self) = @_;
    return App::karr::Config->from_merged( $self->effective_config )
        ->foundation_enabled;
}

=head2 foundation_enabled

Returns true when automated agent runs are allowed on this board
(C<foundation.enabled> in C<refs/karr/config>; boards default to enabled).

    unless ($store->foundation_enabled) {
        # karr-foundation skips this board entirely
    }

=cut

sub foundation_reason {
    my ($self) = @_;
    return App::karr::Config->from_merged( $self->effective_config )
        ->foundation_reason;
}

=head2 foundation_reason

Returns the reason recorded with the disable flag, or undef when none was
given.

    my $why = $store->foundation_reason;

=cut

sub set_foundation_enabled {
    my ( $self, $enabled, $reason ) = @_;
    my $effective = $self->effective_config;
    $effective->{foundation} = {} unless ref $effective->{foundation} eq 'HASH';
    $effective->{foundation}{enabled} = $enabled ? 1 : 0;
    if ( defined $reason && length $reason ) {
        $effective->{foundation}{reason} = $reason;
    } else {
        delete $effective->{foundation}{reason};
    }
    return $self->save_config($effective);
}

=head2 set_foundation_enabled

Writes the board-level agent switch and its optional reason back into
C<refs/karr/config>. Re-enabling drops the reason, and because C<enabled> then
matches the code default the whole C<foundation> key disappears from the sparse
overrides again.

    $store->set_foundation_enabled( 0, 'abandoned driver' );
    $store->set_foundation_enabled( 1 );

=cut

sub save_config {
    my ( $self, $effective ) = @_;
    my $defaults = App::karr::Config->default_config;
    my $overrides = _diff_hashes( $defaults, $effective );
    $overrides->{version} = $effective->{version} // 1;
    delete $self->{_effective_config};  # invalidate cache
    return $self->git->write_config_ref($overrides);
}

sub peek_next_id {
    my ($self) = @_;
    return $self->git->read_next_id_ref;
}

sub allocate_next_id {
    my ($self) = @_;
    return $self->git->allocate_next_id_ref;
}

=head2 allocate_next_id

Returns the next free task id and moves the counter past it, atomically. Two
agents running C<karr create> at the same time are guaranteed different ids;
before this was a compare-and-swap they could both be handed the same one and
the second task overwrote the first (#44).

    my $id = $store->allocate_next_id;

=cut

sub set_next_id {
    my ( $self, $next_id ) = @_;
    return $self->git->write_next_id_ref($next_id);
}

sub ensure_next_id {
    my ($self) = @_;
    my ($max) = sort { $b <=> $a } $self->git->list_task_refs;
    my $floor = defined $max ? $max + 1 : 1;

    # A board with no counter yet gets one; a board that already has one only
    # ever moves forward.
    return $self->set_next_id($floor)
        unless $self->git->ref_exists('refs/karr/meta/next-id');
    return 1 if $self->peek_next_id >= $floor;
    return $self->set_next_id($floor);
}

=head2 ensure_next_id

Seeds the id counter without ever handing out an id that is already taken. On a
fresh board that is C<1>; on a board C<init> is completing rather than creating
it is one past the highest task ref, and an existing counter that is already
further ahead is left alone. C<init> used to write C<1> unconditionally, which
on a half-board (see L</board_exists>) meant the next C<karr create> reused id 1
and overwrote the task that was already there.

    $store->ensure_next_id;

=cut

sub stamp_encoding_version {
    my ($self) = @_;
    return $self->git->write_encoding_version;
}

=head2 stamp_encoding_version

Records in C<refs/karr/meta/encoding> that this board's payloads follow the
current character-encoding contract, so nothing reading it applies the
legacy-mojibake repair (see L<App::karr::Encoding>). Written by C<karr init>,
C<karr repair --yes>, and the import path below.

    $store->stamp_encoding_version;

=cut

sub load_tasks {
    my ($self) = @_;
    my @ids = $self->git->list_task_refs;
    return map { $self->git->load_task_ref($_) } @ids;
}

sub find_task {
    my ( $self, $id ) = @_;
    return $self->git->load_task_ref($id);
}

sub save_task {
    my ( $self, $task ) = @_;
    # Bump `updated` centrally on every mutation of an existing task, so
    # move/edit/pick/handoff/archive get a fresh timestamp for free. A brand
    # new task keeps its own `updated` (== created); the restore/import path in
    # serialize_from bypasses this via git->save_task_ref to preserve stamps.
    my $ref = "refs/karr/tasks/" . $task->id . "/data";
    $task->updated( gmtime->datetime . 'Z' ) if $self->git->ref_exists($ref);
    return $self->git->save_task_ref($task);
}

sub delete_task {
    my ( $self, $id ) = @_;
    return $self->git->delete_ref("refs/karr/tasks/$id/data");
}

sub list_karr_refs {
    my ($self) = @_;
    return $self->git->list_refs('refs/karr/');
}

sub delete_all_karr_refs {
    my ($self) = @_;
    return $self->git->delete_refs('refs/karr/');
}

sub materialize_to {
    my ( $self, $board_dir ) = @_;
    $board_dir = path($board_dir);
    my $tasks_dir = $board_dir->child('tasks');
    $board_dir->mkpath;
    $tasks_dir->mkpath;

    DumpFile( $board_dir->child('config.yml')->stringify, $self->load_config );

    for my $old_file ( $tasks_dir->children(qr/\.md$/) ) {
        $old_file->remove;
    }

    for my $task ( $self->load_tasks ) {
        $task->save($tasks_dir);
    }

    return $board_dir;
}

sub file_view_gitignore_entries {
    # The disposable file view materialize_to writes: config.yml + tasks/*.md.
    # These must always be gitignored -- refs/karr/* is the canonical state and
    # the view is never committed. Mirror the exact names used by materialize_to.
    return ( 'tasks/', 'config.yml' );
}

sub ensure_gitignore {
    my ( $self, $board_dir ) = @_;
    $board_dir = path($board_dir);
    my $gitignore = $board_dir->child('.gitignore');

    my @entries  = $self->file_view_gitignore_entries;
    my $existing = $gitignore->exists ? $gitignore->slurp_utf8 : '';

    # Line-exact presence (whitespace-insensitive), so we never duplicate an
    # entry -- or our header -- that is already there.
    my %present;
    for my $line ( split /\n/, $existing ) {
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        $present{$line} = 1 if length $line;
    }

    my @missing = grep { !$present{$_} } @entries;
    return () unless @missing;

    my $header         = '# karr materialized task view -- never commit';
    my $header_present = $present{$header} ? 1 : 0;

    # Idempotent append that keeps the existing file intact: terminate a
    # dangling last line, separate a fresh karr block with a blank line, and
    # only emit the header when starting one.
    my $append = '';
    if ( length $existing ) {
        $append .= "\n" unless $existing =~ /\n\z/;
        $append .= "\n" unless $header_present;
    }
    $append .= "$header\n" unless $header_present;
    $append .= "$_\n" for @missing;

    $gitignore->append_utf8($append);
    return @missing;
}

sub serialize_from {
    my ( $self, $board_dir ) = @_;
    $board_dir = path($board_dir);
    my $config_file = $board_dir->child('config.yml');
    if ( $config_file->exists ) {
        my $config = LoadFile( $config_file->stringify );
        delete $config->{next_id};
        $self->save_config($config);
    } elsif ( !$self->board_exists ) {
        # Import is a bootstrap path (#30), so it has to leave a board karr
        # will actually write to. A kanban-md F<tasks/> view with no
        # F<config.yml> otherwise produced tasks and a counter but no
        # C<refs/karr/config> -- exactly the half-board every write command now
        # refuses (#62), which made `karr create` right after a successful
        # import impossible.
        $self->save_config( App::karr::Config->default_config );
    }

    my %seen;
    my $tasks_dir = $board_dir->child('tasks');
    if ( $tasks_dir->exists ) {
        for my $file ( $tasks_dir->children(qr/\.md$/) ) {
            my $task = App::karr::Task->from_file($file);
            # Restore/import path: persist verbatim so the original `updated`
            # timestamps survive, even when overwriting pre-existing refs.
            $self->git->save_task_ref($task);
            $seen{ $task->id } = 1;
        }
    }

    for my $id ( $self->git->list_task_refs ) {
        next if $seen{$id};
        $self->delete_task($id);
    }

    # Bootstrap fix (#30): import does not require a pre-existing board, so on a
    # fresh repo meta/next-id is missing and a following `karr create` would
    # re-allocate an already-imported id. Seed next-id past the highest imported
    # id when the stored next-id is missing or stale, but never lower a next-id
    # that is already ahead of the view (an existing healthy board is untouched).
    if (%seen) {
        my ($max_id) = sort { $b <=> $a } keys %seen;
        $self->set_next_id( $max_id + 1 ) if $self->peek_next_id <= $max_id;
    }

    # Everything just written came from character-level file reads (LoadFile,
    # Task->from_file), so the refs now satisfy the current encoding contract
    # even if the board did not before. Stamping here stops the legacy repair
    # from running over data that is already correct. Only when it is missing:
    # every ref write mints a fresh commit object, and re-stamping an already
    # current board would push a new one on every import for no reason.
    $self->stamp_encoding_version if $self->git->board_is_legacy_encoded;

    return 1;
}

sub snapshot {
    my ($self) = @_;
    my %snapshot;
    for my $ref ( $self->list_karr_refs ) {
        $snapshot{$ref} = $self->git->read_ref($ref);
    }
    return {
        version => 1,
        refs => \%snapshot,
    };
}

sub restore_snapshot {
    my ( $self, $snapshot ) = @_;
    return $self->git->replace_board_refs( $snapshot->{refs} || {} );
}

=head2 restore_snapshot

Makes the board consist of exactly the refs in the snapshot. Every ref name is
checked and every commit object built before the first ref moves, so a snapshot
karr cannot write is refused with the board untouched instead of destroying it
on the way through (#47). See L<App::karr::Git/replace_board_refs>.

    $store->restore_snapshot( $snapshot );

=cut

sub _diff_hashes {
    my ( $defaults, $effective ) = @_;
    my %diff;
    for my $key ( keys %{ $effective // {} } ) {
        next if $key eq 'next_id';
        my $have_default = exists $defaults->{$key};
        my $default = $defaults->{$key};
        my $value   = $effective->{$key};

        if ( ref($value) eq 'HASH' && ref($default) eq 'HASH' ) {
            my $nested = _diff_hashes( $default, $value );
            $diff{$key} = $nested if keys %$nested;
        } elsif ( !$have_default || !_same_value( $default, $value ) ) {
            $diff{$key} = $value;
        }
    }
    return \%diff;
}

sub _same_value {
    my ( $left, $right ) = @_;
    return 0 if ref($left) ne ref($right);
    if ( ref($left) eq 'HASH' ) {
        return 0 unless keys(%$left) == keys(%$right);
        for my $key ( keys %$left ) {
            return 0 unless exists $right->{$key};
            return 0 unless _same_value( $left->{$key}, $right->{$key} );
        }
        return 1;
    }
    if ( ref($left) eq 'ARRAY' ) {
        return 0 unless @$left == @$right;
        for my $i ( 0 .. $#$left ) {
            return 0 unless _same_value( $left->[$i], $right->[$i] );
        }
        return 1;
    }
    return ( defined $left ? $left : '' ) eq ( defined $right ? $right : '' );
}

1;
