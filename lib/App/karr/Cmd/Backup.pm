# ABSTRACT: Export the ref-backed karr board as YAML

package App::karr::Cmd::Backup;
our $VERSION = '0.304';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr backup [--output PATH]',
);
use Path::Tiny;
use YAML::XS qw( Dump );
use App::karr::Role::BoardDiscovery;

with 'App::karr::Role::BoardDiscovery';

=head1 SYNOPSIS

    karr backup > karr-backup.yml
    karr backup --output karr-backup.yml

=head1 DESCRIPTION

Exports the complete C<refs/karr/*> namespace as a YAML snapshot. The default
mode writes the snapshot to standard output so it can be redirected or piped.
Use C<--output> when you want C<karr> to write the file directly.

=head1 OPTIONS

=over 4

=item * C<--output>

Write the YAML snapshot to the given file instead of standard output.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Restore>,
L<App::karr::Cmd::Destroy>, L<App::karr::Cmd::Sync>

=cut

option output => (
  is => 'ro',
  format => 's',
  doc => 'Write YAML snapshot to a file instead of stdout',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  # store/git honour --dir (both call forms) and die loudly if the target is
  # not a Git repository, instead of hardcoding the current directory.
  my $store = $self->store;
  my $git   = $self->git;
  $git->pull if $git->has_remote;

  die "No karr board found. Run 'karr init' to create one.\n"
    unless $store->board_exists;

  my $yaml = Dump( $store->snapshot );

  if ( $self->output ) {
    my $file = path( $self->output );
    $file->parent->mkpath;
    $file->spew_utf8($yaml);
    print STDERR "Wrote backup to $file\n";
    return;
  }

  print $yaml;
}

1;
