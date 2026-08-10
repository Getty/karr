# ABSTRACT: Migrate a board written by 0.402 or earlier off double-encoded UTF-8

package App::karr::Cmd::Repair;
our $VERSION = '0.500';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr repair [--yes] [--json]',
);
use App::karr::Encoding qw(
  BOARD_ENCODING_VERSION repair_mojibake
  yaml_load yaml_dump json_decode json_encode
);
use App::karr::Task;
use App::karr::Role::BoardDiscovery;
use App::karr::Role::SyncLifecycle;
use App::karr::Role::CliArgs;
use App::karr::Role::Output;

with 'App::karr::Role::BoardDiscovery';
with 'App::karr::Role::SyncLifecycle';
with 'App::karr::Role::CliArgs';
with 'App::karr::Role::Output';

=head1 SYNOPSIS

    karr repair              # report what would change
    karr repair --yes        # rewrite the affected refs
    karr repair --json

=head1 DESCRIPTION

karr up to and including 0.402 handed C<YAML::XS::Dump> output — UTF-8 octets —
around as if it were characters, so every board written by those versions
carries UTF-8 encoded twice in its task frontmatter, its board config, and its
activity log. Task bodies are not affected: they were concatenated onto the
Markdown document verbatim and are correctly encoded.

Such a board is still read correctly, because C<refs/karr/meta/encoding> is
absent and everything that loads board state undoes the second encoding on the
way in (see L<App::karr::Encoding/repair_mojibake>). This command makes that
permanent: it rewrites the affected refs once and stamps the marker, after
which nothing guesses at the board's bytes again.

It is safe to run on any board:

=over 4

=item * a board already at the current version is left completely alone;

=item * a ref whose payload is pure ASCII is skipped, so an ASCII-only board
comes out bit-identical apart from the new marker ref;

=item * running it twice changes nothing the second time.

=back

=head1 OPTIONS

=over 4

=item * C<--yes>

Actually rewrite the refs. Without it the command only reports what it would
change.

=item * C<--json>

Emit the report as JSON instead of text.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Encoding>, L<App::karr::Cmd::Backup>,
L<App::karr::Cmd::Import>

=cut

option yes => (
  is => 'ro',
  doc => 'Rewrite the affected refs instead of only reporting them',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->check_positional_args($args_ref, 0);

  my $store = $self->store;
  my $git   = $self->git;

  # A dry run still pulls (a legacy board may only exist on the remote), but it
  # must not push, so its guard is closed immediately. --yes takes the full
  # lifecycle: pull, rewrite, push, with SyncGuard insurance on a crash.
  my $guard = $self->sync_before;
  $guard->done unless $self->yes;

  die "No karr board found. Run 'karr init' to create one.\n"
    unless $store->has_board_refs;

  if ( !$git->board_is_legacy_encoded ) {
    my $version = $git->board_encoding_version;
    return $self->print_json(
      { version => $version, up_to_date => \1, repaired => [] } )
      if $self->json;
    print "Board encoding is already at version $version; nothing to repair.\n";
    return;
  }

  my ( $repaired, $skipped ) = $self->_repair_refs($git);
  my @repaired = @$repaired;

  if ( $self->yes ) {
    $git->write_encoding_version;
    $self->sync_after;
  }

  if ( $self->json ) {
    return $self->print_json({
      version    => $self->yes ? BOARD_ENCODING_VERSION : 1,
      up_to_date => \0,
      applied    => $self->yes ? \1 : \0,
      repaired   => \@repaired,
      skipped    => $skipped,
    });
  }

  # Never quietly: a ref this could not handle is left as it was, and the marker
  # goes on regardless, so the user has to be told which ones to look at.
  if (@$skipped) {
    printf STDERR "Left %d ref(s) unchanged (could not parse, or not a known board payload):\n", scalar @$skipped;
    print STDERR "  $_\n" for @$skipped;
  }

  if ( !@repaired ) {
    print $self->yes
      ? "No double-encoded payloads found; marked the board as encoding version "
        . BOARD_ENCODING_VERSION . ".\n"
      : "No double-encoded payloads found. Run with --yes to mark the board as encoding version "
        . BOARD_ENCODING_VERSION . ".\n";
    return;
  }

  printf "%s %d ref(s):\n", ( $self->yes ? 'Repaired' : 'Would repair' ), scalar @repaired;
  print "  $_\n" for @repaired;
  print "Run 'karr repair --yes' to apply.\n" unless $self->yes;
}

# Returns ( \@changed, \@unparseable ). Anything whose stored text is pure ASCII
# is skipped outright rather than parsed and re-serialized: that is what makes
# "does not touch ASCII data" a property of the code rather than a property of
# the repair heuristic.
sub _repair_refs {
  my ( $self, $git ) = @_;
  my ( @repaired, @skipped );

  for my $ref ( sort $git->list_refs('refs/karr/') ) {
    my $content = $git->read_ref($ref);
    next unless defined $content && length $content;
    next unless $content =~ /[^\x00-\x7F]/;

    # A non-ASCII payload under refs/karr/ that is none of the three known
    # shapes is reported rather than passed over: it may well be legacy-encoded
    # too, and the marker is about to say the whole board is clean.
    my $known =
         $ref =~ m{\Arefs/karr/tasks/\d+/data\z}
      || $ref eq 'refs/karr/config'
      || $ref =~ m{\Arefs/karr/log/};
    if ( !$known ) {
      push @skipped, $ref;
      next;
    }

    my $fixed =
        $ref eq 'refs/karr/config'    ? $self->_repair_config($content)
      : $ref =~ m{\Arefs/karr/log/}   ? $self->_repair_log($content)
      :                                 $self->_repair_task($content);

    if ( !defined $fixed ) {
      push @skipped, $ref;
      next;
    }

    # read_ref chomps one trailing newline and the re-serialized document has
    # one, so compare with that difference normalized away. Without this every
    # task whose *body* has non-ASCII -- a body was never double-encoded and
    # needs no repair -- looked changed and got rewritten for nothing: 63 refs
    # instead of 17 on karr's own board.
    ( my $comparable = $fixed ) =~ s/\n\z//;
    next if $comparable eq $content;

    push @repaired, $ref;
    $git->write_ref( $ref, $fixed ) if $self->yes;
  }

  return ( \@repaired, \@skipped );
}

sub _repair_task {
  my ( $self, $content ) = @_;
  my $task = eval { App::karr::Task->from_string( $content, repair_frontmatter => 1 ) };
  return undef unless $task;
  return $task->to_markdown;
}

sub _repair_config {
  my ( $self, $content ) = @_;
  my $data = eval { yaml_load($content) };
  return undef unless ref $data eq 'HASH';
  return yaml_dump( repair_mojibake($data) );
}

sub _repair_log {
  my ( $self, $content ) = @_;
  my @lines;
  for my $line ( split /\n/, $content ) {
    next unless length $line;
    my $entry = eval { json_decode($line) };
    return undef unless $entry;
    push @lines, json_encode( repair_mojibake($entry) );
  }
  return join "\n", @lines;
}

1;
