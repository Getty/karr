# ABSTRACT: Fetch helper payloads from a Git ref

package App::karr::Cmd::GetRefs;
our $VERSION = '0.304';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr get-refs REF',
);
use App::karr::Git;

=head1 SYNOPSIS

    karr get-refs superpowers/spec/1234.md
    karr get-refs refs/superpowers/spec/1234.md

=head1 DESCRIPTION

Fetches a single helper ref from the remote and prints only its payload to
standard output. Informational messages go to standard error so the command can
be composed into scripts or agent pipelines.

This is especially useful for AI-oriented workflows that want shared spec or
planning blobs without coupling them to the task board itself.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::SetRefs>,
L<App::karr::Cmd::Backup>, L<App::karr::Git>

=cut

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;
  my $ref_input = $args_ref->[0];
  die "Usage: karr get-refs REF\n" unless defined $ref_input;

  my $repo_dir = '.';
  if ($chain_ref && @$chain_ref) {
    my $root = $chain_ref->[0];
    if ($root && $root->can('has_dir') && $root->has_dir) {
      $repo_dir = $root->dir;
    }
  }

  my $git = App::karr::Git->new(dir => $repo_dir);
  die "Not a git repository.\n" unless $git->is_repo;

  my $ref = $git->validate_helper_ref($ref_input);
  $git->pull_ref($ref) or die "Failed to fetch $ref\n";

  my $content = $git->read_ref($ref);
  print STDERR "Fetched $ref\n";
  print $content;
  print "\n" unless $content =~ /\n\z/;
}

1;
