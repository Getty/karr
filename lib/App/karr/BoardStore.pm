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
    return $self->git->ref_exists('refs/karr/config')
        || $self->git->ref_exists('refs/karr/meta/next-id');
}

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
    my ( $self, $board_dir, %args ) = @_;
    $board_dir = path($board_dir);
    my $tasks_dir   = $board_dir->child('tasks');
    my $config_file = $board_dir->child('config.yml');

    my @stale = $self->_materialized_cards($tasks_dir);

    # Ticket #48: the view is written into the working tree, and `tasks/` and
    # `config.yml` at a repository root are perfectly ordinary names for a
    # project to already use. Overwriting or deleting a file Git tracks is data
    # loss from a command that only reads the board, so check before writing
    # anything at all -- not even the directories are created on this path.
    unless ( $args{force} ) {
        my @tracked = grep { $self->git->is_tracked($_) } $config_file, @stale;
        die "Refusing to materialize into $board_dir: "
            . scalar(@tracked)
            . " file(s) there are tracked by git and would be overwritten or deleted:\n"
            . join( '', map { '  ' . $_->relative($board_dir) . "\n" } @tracked )
            . "The file view is disposable board state, not project content. Move those files\n"
            . "aside, or re-run with --force to replace them.\n"
            if @tracked;
    }

    $board_dir->mkpath;
    $tasks_dir->mkpath;

    {
        # kanban-md's schema types several config keys as Go bools and rejects
        # the integers Perl uses for them; JSON::PP is YAML::XS's mode name for
        # "dump JSON::PP::Boolean as a real YAML boolean" (ticket #60).
        local $YAML::XS::Boolean = 'JSON::PP';
        DumpFile(
            $config_file->stringify,
            App::karr::Config->file_view_config(
                $self->load_config,
                next_id => $self->peek_next_id,
            ),
        );
    }

    $_->remove for @stale;

    for my $task ( $self->load_tasks ) {
        $task->save($tasks_dir);
    }

    return $board_dir;
}

=head2 materialize_to

Writes the board out to C<$board_dir> as a kanban-md file view: a F<config.yml>
plus a F<tasks/> directory of cards. Stale cards from an earlier run are swept
first, but only files named the way karr and kanban-md name them
(C<NNN-slug.md>) -- anything else in F<tasks/> belongs to the project.

Dies without writing anything when the view would overwrite or delete a file
Git tracks, naming each one; C<< force => 1 >> proceeds anyway (ticket #48).

    $store->materialize_to( $git_root );
    $store->materialize_to( $git_root, force => 1 );

=cut

# The files in tasks/ that a previous materialization could have written, i.e.
# everything shaped like App::karr::Task::filename -- which is also kanban-md's
# own task-filename prefix (`^(\d+)-` in internal/task/find.go). Anything else
# in the directory belongs to the project, not to karr, and is never swept
# (ticket #48).
sub _materialized_cards {
    my ( $self, $tasks_dir ) = @_;
    return () unless $tasks_dir->exists;
    return sort { $a->basename cmp $b->basename }
        $tasks_dir->children(qr/\A\d+-.*\.md\z/);
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

    # Ticket #70: parse the entire view before a single ref is touched, so one
    # malformed card leaves the board exactly as it was instead of half
    # imported with the prune never reached. Reading the config here rather
    # than writing it keeps that promise for the config too.
    my $tasks_dir = $board_dir->child('tasks');
    my @files     = $tasks_dir->exists
        ? sort { $a->basename cmp $b->basename } $tasks_dir->children(qr/\.md$/)
        : ();

    my ( @tasks, @rejected );
    for my $file (@files) {
        my $task = eval { App::karr::Task->from_file($file) };
        if   ($task) { push @tasks, $task }
        else         { push @rejected, ( $@ || "unknown error\n" ) }
    }
    # kanban-md skips malformed files and carries on, but import cannot: a
    # skipped card's ref would be pruned below, turning an unreadable file into
    # a deleted task. All or nothing -- and every rejected file is named, which
    # a bare "Invalid task format" never was.
    if (@rejected) {
        die "Refusing to import from $board_dir: "
            . scalar(@rejected)
            . " of " . scalar(@files) . " task file(s) could not be parsed:\n"
            . join( '', map { my $why = $_; chomp $why; "  $why\n" } @rejected )
            . "No refs were changed. Fix or remove those files and import again.\n";
    }

    my $config_file = $board_dir->child('config.yml');
    my $config = $config_file->exists
        ? ( LoadFile( $config_file->stringify ) // {} )
        : undef;
    if ( defined $config ) {
        # next_id belongs to refs/karr/meta/next-id, not to the config; the
        # seeding below owns it. materialize writes it into the view purely
        # because kanban-md refuses a config without it (ticket #60).
        delete $config->{next_id};
    }

    # Nothing above this line wrote anything.
    $self->save_config($config) if defined $config;

    my %seen;
    for my $task (@tasks) {
        # Restore/import path: persist verbatim so the original `updated`
        # timestamps survive, even when overwriting pre-existing refs.
        $self->git->save_task_ref($task);
        $seen{ $task->id } = 1;
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

=head2 serialize_from

Reads a file view at C<$board_dir> back into C<refs/karr/*>: task refs are
replaced by the cards, refs the view does not mention are pruned, and
C<next_id> is seeded past the highest imported id when the stored counter is
missing or stale.

All or nothing. Every card is parsed before the first ref is written, so a
malformed file aborts the whole import -- listing each rejected file and its
reason -- with the board left exactly as it was (ticket #70). Refusing an empty
view is the caller's job; see L<App::karr::Cmd::Import>.

    $store->serialize_from( $git_root );

=cut

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
    my $refs = $snapshot->{refs} || {};
    $self->delete_all_karr_refs;
    for my $ref ( sort keys %$refs ) {
        $self->git->write_ref( $ref, $refs->{$ref} );
    }
    return 1;
}

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
