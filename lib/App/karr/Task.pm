# ABSTRACT: Task object representing a single kanban card

package App::karr::Task;
our $VERSION = '0.403';
use Moo;
use Path::Tiny;
use Time::Piece;
use Carp qw( croak );
use App::karr::Encoding qw( yaml_dump yaml_load repair_mojibake );

=head1 SYNOPSIS

    my $task = App::karr::Task->new(
      id    => 1,
      title => 'Fix login bug',
    );

    $task->save('/tmp/karr-materialized/tasks');
    my $same = App::karr::Task->from_file('/tmp/karr-materialized/tasks/001-fix-login-bug.md');

=head1 DESCRIPTION

L<App::karr::Task> models a single task card and knows how to translate between
the in-memory object and the Markdown plus YAML frontmatter format used on
disk and in Git refs. The same Markdown document is stored in
C<refs/karr/tasks/*/data> and in temporary task files that commands materialize
while they run.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::BoardStore>, L<App::karr::Git>,
L<App::karr::Config>

=cut

has id         => ( is => 'ro', required => 1 );
has title      => ( is => 'rw', required => 1 );
has status     => ( is => 'rw', default => sub { 'backlog' } );
has priority   => ( is => 'rw', default => sub { 'medium' } );
has assignee   => ( is => 'rw', predicate => 1, clearer => 1 );
has tags       => ( is => 'rw', default => sub { [] } );
has due        => ( is => 'rw', predicate => 1, clearer => 1 );
has estimate   => ( is => 'rw', predicate => 1, clearer => 1 );
has class      => ( is => 'rw', default => sub { 'standard' } );
has parent     => ( is => 'rw', predicate => 1, clearer => 1 );
has depends_on => ( is => 'rw', default => sub { [] } );
has body       => ( is => 'rw', default => sub { '' } );
has created    => ( is => 'ro', default => sub { gmtime->datetime . 'Z' } );
has updated    => ( is => 'rw', default => sub { gmtime->datetime . 'Z' } );
has claimed_by => ( is => 'rw', predicate => 1, clearer => 1 );
has claimed_at => ( is => 'rw', predicate => 1, clearer => 1 );
has blocked    => ( is => 'rw', predicate => 1, clearer => 1 );
has started    => ( is => 'rw', predicate => 1, clearer => 1 );
has completed  => ( is => 'rw', predicate => 1, clearer => 1 );
has file_path  => ( is => 'rw', predicate => 1 );

# Optional fields are addressed through their predicate everywhere (pick,
# board, list, show, handoff all treat has_X as "is this set"). Clearing one
# by assigning undef would leave the predicate true, so callers must use the
# generated clear_X. This guards the load path: a file that carries an
# explicit null (our own older writes, or an external kanban-md edit) is
# normalized back to "unset" instead of lingering as has_X-true-but-undef.
sub BUILD {
  my ($self) = @_;
  for my $attr (qw( assignee due estimate parent claimed_by claimed_at blocked started completed )) {
    my $clearer = "clear_$attr";
    my $has     = "has_$attr";
    $self->$clearer if $self->$has && !defined $self->$attr;
  }
}

sub slug {
  my ($self) = @_;
  my $slug = lc($self->title);
  $slug =~ s/[^a-z0-9]+/-/g;
  $slug =~ s/^-|-$//g;
  $slug = substr($slug, 0, 50);
  return $slug;
}

sub filename {
  my ($self) = @_;
  return sprintf('%03d-%s.md', $self->id, $self->slug);
}

sub to_frontmatter {
  my ($self) = @_;
  my %fm = (
    id       => $self->id,
    title    => $self->title,
    status   => $self->status,
    priority => $self->priority,
    created  => $self->created,
    updated  => $self->updated,
    class    => $self->class,
  );
  $fm{assignee}   = $self->assignee   if $self->has_assignee;
  $fm{tags}       = $self->tags       if @{$self->tags};
  $fm{due}        = $self->due        if $self->has_due;
  $fm{estimate}   = $self->estimate   if $self->has_estimate;
  $fm{parent}     = $self->parent     if $self->has_parent;
  $fm{depends_on} = $self->depends_on if @{$self->depends_on};
  $fm{claimed_by} = $self->claimed_by if $self->has_claimed_by;
  $fm{claimed_at} = $self->claimed_at if $self->has_claimed_at;
  $fm{blocked}    = $self->blocked    if $self->has_blocked;
  $fm{started}    = $self->started    if $self->has_started;
  $fm{completed}  = $self->completed  if $self->has_completed;
  return \%fm;
}

=method to_json_hash

  my $data = $task->to_json_hash;

Returns the task as a plain hash reference ready for JSON encoding: the
frontmatter fields from L</to_frontmatter> plus a C<body> key when the task has
a non-empty body. Used by the C<show>, C<pick>, and C<handoff> commands to
build their C<--json> payload.

=cut

sub to_json_hash {
  my ($self) = @_;
  my $data = $self->to_frontmatter;
  $data->{body} = $self->body if $self->body;
  return $data;
}

sub to_markdown {
  my ($self) = @_;
  my $yaml = yaml_dump($self->to_frontmatter);
  $yaml =~ s/\A---\n//;
  my $md = "---\n${yaml}---\n";
  $md .= "\n" . $self->body . "\n" if $self->body;
  return $md;
}

sub _parse_content {
  my ($class, $content) = @_;
  # The closing delimiter is anchored to the start of a line (/m), the way
  # kanban-md's splitFrontmatter scans for a literal "\n---\n". Without the
  # anchor a frontmatter value that merely *ends* in "---" -- `blocked:
  # waiting ---`, which YAML::XS dumps unquoted -- terminated the frontmatter
  # mid-line, and the truncated document then failed Task->new with "Missing
  # required arguments: id, title". Every command that loads the board hit it,
  # `delete` included, so the board could not be repaired with karr at all
  # (ticket #52).
  my ($yaml, $body) = $content =~ m{\A---\n(.+?)^---[ \t]*(?:\n(.*))?\z}ms
    or die "Invalid task format\n";
  $body //= '';
  $body =~ s/^\n//;
  $body =~ s/\n$//;
  return (yaml_load($yaml), $body);
}

sub from_string {
  my ($class, $content, %opt) = @_;
  my ($fm, $body) = $class->_parse_content($content);
  # repair_frontmatter is set by App::karr::Git::load_task_ref for a board
  # written before refs/karr/meta/encoding existed. Only the frontmatter is
  # repaired: it went through YAML::XS::Dump, which encoded the already-encoded
  # octets a second time. The body was concatenated onto the document verbatim
  # and is single-encoded, so touching it would corrupt it (ticket #53).
  $fm = repair_mojibake($fm) if $opt{repair_frontmatter};
  return $class->new(%$fm, body => $body);
}

sub from_file {
  my ($class, $file) = @_;
  $file = path($file);
  my ($fm, $body) = $class->_parse_content($file->slurp_utf8);
  return $class->new(%$fm, body => $body, file_path => $file);
}

sub save {
  my ($self, $dir) = @_;
  croak "Task has no file_path; ref-backed tasks must be persisted via BoardStore/save_task"
    if !$dir && !$self->has_file_path;
  my $file = $dir ? path($dir)->child($self->filename) : path($self->file_path);
  $file->spew_utf8($self->to_markdown);
  $self->file_path($file);
  return $file;
}

1;
