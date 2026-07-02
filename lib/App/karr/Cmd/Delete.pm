# ABSTRACT: Delete a task

package App::karr::Cmd::Delete;
our $VERSION = '0.304';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr delete ID[,ID,...] [--yes] [--json]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Task;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output';

=head1 SYNOPSIS

    karr delete 9
    karr delete 9,10,11 --yes
    karr delete 9 --json

=head1 DESCRIPTION

Deletes one or more task files from the board. This is the destructive
alternative to L<App::karr::Cmd::Archive>, which only changes the status to
C<archived>.

=head1 OPTIONS

=over 4

=item * C<--yes>

Skips the interactive confirmation prompt for each task.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Archive>,
L<App::karr::Cmd::Backup>, L<App::karr::Cmd::Destroy>

=cut

option yes => (
  is => 'ro',
  short => 'y',
  doc => 'Skip confirmation',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->check_positional_args($args_ref, 1);

  $self->sync_before;

  my $id_str = $args_ref->[0] or die "Usage: karr delete ID[,ID,...] [--yes] [--json]\n";
  my @ids = $self->parse_ids($id_str);

  my @results;
  for my $id (@ids) {
    my $task = $self->find_task($id);
    die "Task $id not found\n" unless $task;

    unless ($self->yes) {
      printf "Delete task %d: %s? [y/N] ", $task->id, $task->title;
      my $answer = <STDIN>;
      chomp $answer;
      unless ($answer =~ /^y/i) {
        push @results, { id => $task->id, title => $task->title, deleted => \0 };
        printf "Skipped task %d: %s\n", $task->id, $task->title unless $self->json;
        next;
      }
    }

    $task->file_path->remove;
    push @results, { id => $task->id, title => $task->title, deleted => \1 };
    printf "Deleted task %d: %s\n", $task->id, $task->title unless $self->json;
  }

  $self->sync_after;

  if ($self->json) {
    $self->print_json(@results == 1 ? $results[0] : \@results);
  }
}

1;
