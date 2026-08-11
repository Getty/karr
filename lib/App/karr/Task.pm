# ABSTRACT: Task object representing a single kanban card

package App::karr::Task;
our $VERSION = '0.500';
use Moo;
use Path::Tiny;
use Time::Piece;
use Carp qw( croak );
use App::karr::Config;
use App::karr::Encoding qw( yaml_dump yaml_load repair_mojibake );
# Imported empty on purpose: App::karr::Encoding owns every JSON crossing, so
# the encode_json/decode_json this module would otherwise pull in must not be
# reachable here. Only the boolean singletons are wanted -- see L</to_json_hash>.
use JSON::MaybeXS ();

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

has id           => ( is => 'ro', required => 1 );
has title        => ( is => 'rw', required => 1 );
has status       => ( is => 'rw', default => sub { 'backlog' } );
has priority     => ( is => 'rw', default => sub { 'medium' } );
has assignee     => ( is => 'rw', predicate => 1, clearer => 1 );
has tags         => ( is => 'rw', default => sub { [] } );
has due          => ( is => 'rw', predicate => 1, clearer => 1 );
has estimate     => ( is => 'rw', predicate => 1, clearer => 1 );
has class        => ( is => 'rw', default => sub { 'standard' } );
has parent       => ( is => 'rw', predicate => 1, clearer => 1 );
has depends_on   => ( is => 'rw', default => sub { [] } );
has body         => ( is => 'rw', default => sub { '' } );
has created      => ( is => 'ro', default => sub { gmtime->datetime . 'Z' } );
has updated      => ( is => 'rw', default => sub { gmtime->datetime . 'Z' } );
has claimed_by   => ( is => 'rw', predicate => 1, clearer => 1 );
has claimed_at   => ( is => 'rw', predicate => 1, clearer => 1 );
has blocked      => ( is => 'rw', predicate => 1, clearer => 1 );
has block_reason => ( is => 'rw', predicate => 1, clearer => 1 );
has started      => ( is => 'rw', predicate => 1, clearer => 1 );
has completed    => ( is => 'rw', predicate => 1, clearer => 1 );
has extra        => ( is => 'rw', default => sub { {} } );
has file_path    => ( is => 'rw', predicate => 1 );

=attr extra

Frontmatter keys karr does not model, kept verbatim so they survive a write.
kanban-md unmarshals into a struct and drops anything unknown; karr does not,
because the field it would delete is just as likely to be a hand-written note
or a newer kanban-md field as it is to be junk (ticket #69).

Keys are B<not> order-preserved: karr's YAML output is key-sorted, so a
passthrough field lands in alphabetical position rather than where the author
put it.

    my $kept = $task->extra->{custom_field};

=cut

# Every frontmatter key karr models itself. Anything else read from a document
# goes to L</extra> instead of being silently dropped.
my @FRONTMATTER_FIELDS = qw(
  id title status priority created updated started completed
  assignee tags due estimate parent depends_on
  blocked block_reason claimed_by claimed_at class
);
my %IS_FRONTMATTER_FIELD = map { $_ => 1 } @FRONTMATTER_FIELDS;

use constant MAX_SLUG_LENGTH => 50;

# Optional fields are addressed through their predicate everywhere (pick,
# board, list, show, handoff all treat has_X as "is this set"). Clearing one
# by assigning undef would leave the predicate true, so callers must use the
# generated clear_X. This guards the load path: a document that carries an
# explicit null, or a value with no length at all, is normalized back to
# "unset" instead of lingering as has_X-true-but-empty.
#
# The empty case is the interop one. Every optional field here is `omitempty`
# in kanban-md's Go struct, so "absent" and "present but empty" are the same
# state on that side of the boundary -- while on this side Moo's predicate
# calls the second one set. A hand-written or third-party card carrying
# `claimed_by: ""` therefore looked claimed to `board`, blocked a
# require_claim move in `move`/`edit`, printed "Claimed:" with nothing after
# it in `show`, and counted as an engaged card toward karr-foundation's
# auto-block. #59 patched three of those readers one at a time; normalizing
# once here is the same fix for all of them, including the ones nobody has
# written yet (ticket #98).
#
# Emptiness is length, never truth: `0` and `"0"` are one character long and
# have to survive, which is the trap that gave ticket #78 its "body 0" row.
sub BUILD {
  my ($self) = @_;
  for my $attr (qw( assignee due estimate parent claimed_by claimed_at blocked block_reason started completed )) {
    my $clearer = "clear_$attr";
    my $has     = "has_$attr";
    next unless $self->$has;
    my $value = $self->$attr;
    $self->$clearer if !defined $value || !length $value;
  }
  $self->_normalize_lists;
  $self->_normalize_blocked;
}

# The two list-valued fields, guarded here for the same reason the optional
# scalars are cleared above: the parse gate is the only gate. A scalar where
# the list belongs -- `tags: urgent`, `depends_on: 1`, both only writable by
# hand or by a third tool, since every karr write goes through to_frontmatter
# -- used to pass construction and die mid-write at the dereference in
# to_frontmatter, as a raw Perl error carrying a source location (the #77
# class), and on the import path after refs had already started moving, which
# broke serialize_from's all-or-nothing promise (#70). A field whose whole
# meaning is "a list" refuses a single value as a usage error at parse time,
# where from_file can still name the file (ticket #125).
#
# An empty or null value is not a scalar value. Every list field is `omitempty`
# in kanban-md's Go struct, so "present but empty" is the same state as
# "absent" (the #98 rule) and loads as the empty list.
sub _normalize_lists {
  my ($self) = @_;
  for my $attr (qw( tags depends_on )) {
    my $value = $self->$attr;
    next if ref $value eq 'ARRAY';
    if ( !defined $value || ( !ref $value && !length $value ) ) {
      $self->$attr([]);
      next;
    }
    die "Frontmatter field '$attr' must be a list"
      . ( ref $value ? '' : ', not a single value' ) . "\n";
  }
}

# karr up to 0.402 stored the blocking *reason* in `blocked` as free text;
# kanban-md has always had `blocked: bool` plus `block_reason: string`, and its
# YAML decoder refuses a string there outright ("cannot unmarshal !!str into
# bool" -- the task then vanishes from its board). This pulls a legacy document
# into the kanban-md shape on read, which is why no migration command is needed:
# the next write of that task emits the new shape (ticket #58).
#
# The invariant everything downstream relies on: has_blocked is true if and only
# if the task is blocked. "Blocked but false" is not representable, matching the
# `omitempty` on kanban-md's Blocked field.
sub _normalize_blocked {
  my ($self) = @_;
  return unless $self->has_blocked;
  my $raw = $self->blocked;

  # A boolean object from some other YAML loader.
  return $self->_set_blocked_flag($raw) if ref $raw;

  # YAML::XS loads `blocked: false` as the empty string, so this covers the
  # honest boolean false as well as an explicitly empty value.
  return $self->_set_blocked_flag(0) if !length $raw;

  my $bool = eval { App::karr::Config->parse_bool($raw) };
  return $self->_set_blocked_flag($bool) if defined $bool;

  # Not a boolean spelling, so it is a legacy reason string.
  $self->_set_blocked_flag(1);
  $self->block_reason($raw) unless $self->has_block_reason;
  return;
}

# Note the asymmetry with L</unblock>: a document that says `blocked: false`
# while still carrying a `block_reason` keeps that reason, because dropping it
# would be exactly the silent frontmatter deletion of ticket #69. Only an
# explicit unblock throws the reason away.
sub _set_blocked_flag {
  my ( $self, $value ) = @_;
  return $value ? $self->blocked(!!1) : $self->clear_blocked;
}

sub block {
  my ( $self, $reason ) = @_;
  $self->blocked(!!1);
  if ( defined $reason && length $reason ) {
    $self->block_reason($reason);
  } else {
    $self->clear_block_reason;
  }
  return $self;
}

=method block

  $task->block('waiting on the upstream API');
  $task->block;   # blocked, no reason recorded

Marks the task blocked and records the optional reason, keeping C<blocked> and
C<block_reason> consistent. This is the only supported way to set them: writing
C<< $task->blocked($reason) >> is what ticket #58 was about.

=cut

sub unblock {
  my ($self) = @_;
  $self->clear_blocked;
  $self->clear_block_reason;
  return $self;
}

=method unblock

  $task->unblock;

Clears the blocked flag and any reason with it.

=cut

sub update_timestamps {
  my ( $self, $old_status, $new_status, $first_status, $config ) = @_;
  my $now = gmtime->datetime . 'Z';

  # Called on the class, is_terminal_status answers for the default board --
  # the literal `done` and `archived`. That is all this method could ever ask
  # before the last #67 leftover fell, so a board whose final column is named
  # anything else recorded no completion at all: `karr move 1 shipped` stamped
  # `started` and left `completed` unset for ever, and every reader built on
  # it (metrics, context's recently-completed) saw an empty set. Hand the
  # board's own App::karr::Config in and its statuses decide instead.
  $config //= 'App::karr::Config';

  # First move out of the board's first status starts the clock, and never
  # restarts it.
  if ( !$self->has_started
    && defined $first_status
    && defined $old_status
    && $old_status eq $first_status
    && $new_status ne $first_status )
  {
    $self->started($now);
  }

  if ( $config->is_terminal_status($new_status) ) {
    $self->completed($now) unless $self->has_completed;
    # A task dragged straight to done never passed through in-progress, so it
    # has no start; without this its cycle time would be unmeasurable.
    $self->started($now) unless $self->has_started;
  } elsif ( defined $old_status
    && $config->is_terminal_status($old_status) )
  {
    # Reopening. `started` is deliberately kept: the work did begin then.
    $self->clear_completed;
  }

  return $self;
}

=method update_timestamps

  $task->update_timestamps( $old_status, $new_status, $first_status, $config );

Maintains C<started> and C<completed> across a status transition, the single
place that logic lives (kanban-md keeps it in F<internal/task/lifecycle.go>).
C<$first_status> is the board's first configured status; pass C<undef> when the
caller has no config to hand and only the terminal-status rules should apply.

C<$config> is the board's L<App::karr::Config>, and it decides which statuses
are terminal. Omit it and the default board's C<done>/C<archived> pair decides,
which is wrong for any board that names its final column something else -- on
such a board nothing is ever stamped C<completed> (a leftover from ticket #67).
Every caller that has a config in hand should pass it.

Both stamps are full C<YYYY-MM-DDTHH:MM:SSZ> timestamps like C<created> and
C<updated>. Before ticket #68 C<started> was a bare date, which is useless for
the cycle-time arithmetic C<karr metrics> is meant to do.

One deliberate difference from kanban-md: it re-stamps C<completed> on B<every>
move into a terminal status, so C<done> -> C<archived> overwrites the real
completion time. karr sets C<completed> only when it is not already set, so
archiving a finished task keeps the date it was actually finished.

=cut

sub slug {
  my ($self) = @_;
  my $slug = lc($self->title);
  $slug =~ s/[^a-z0-9]+/-/g;
  $slug =~ s/^-|-$//g;
  return $slug if length($slug) <= MAX_SLUG_LENGTH;

  # Truncate on a word boundary the way kanban-md's GenerateSlug does
  # (internal/task/slug.go): cutting mid-word backs up to the last dash, and a
  # cut that already landed on one keeps the whole final word. A hard cut at 50
  # gave the same task two different filenames in a shared tasks/ directory.
  my $truncated = substr( $slug, 0, MAX_SLUG_LENGTH );
  if ( substr( $slug, MAX_SLUG_LENGTH, 1 ) ne '-' ) {
    my $idx = rindex( $truncated, '-' );
    $truncated = substr( $truncated, 0, $idx ) if $idx > 0;
  }
  $truncated =~ s/-+\z//;
  return $truncated;
}

=method slug

  my $slug = $task->slug;

Lowercases the title, collapses everything that is not C<[a-z0-9]> to a
single dash, and trims leading/trailing dashes, truncating on a word
boundary at 50 characters the way kanban-md's C<GenerateSlug> does. Used by
L</filename> to build the on-disk name; not stored anywhere itself, so a
title edit changes the slug -- and so the filename -- on the next L</save>.

=cut

sub filename {
  my ($self) = @_;
  return sprintf('%03d-%s.md', $self->id, $self->slug);
}

=method filename

  my $name = $task->filename;   # '007-fix-login-bug.md'

Returns the on-disk filename this task would use in a materialized file
view: the id zero-padded to three digits, a dash, and L</slug>, matching
kanban-md's own C<^(\d+)-> naming convention. Used by L</save> when writing
into a directory rather than to an already-known C<file_path>.

=cut

sub to_frontmatter {
  my ($self) = @_;
  # Passthrough keys form the base so a modelled field always wins the slot it
  # owns, and so a field that has since been cleared cannot be resurrected by a
  # stale copy in extra.
  my %fm = %{ $self->extra };
  delete @fm{@FRONTMATTER_FIELDS};

  %fm = (
    %fm,
    id       => $self->id,
    title    => $self->title,
    status   => $self->status,
    priority => $self->priority,
    created  => $self->created,
    updated  => $self->updated,
    class    => $self->class,
  );
  $fm{assignee}     = $self->assignee     if $self->has_assignee;
  $fm{tags}         = $self->tags         if @{$self->tags};
  $fm{due}          = $self->due          if $self->has_due;
  $fm{estimate}     = $self->estimate     if $self->has_estimate;
  $fm{parent}       = $self->parent       if $self->has_parent;
  $fm{depends_on}   = $self->depends_on   if @{$self->depends_on};
  $fm{claimed_by}   = $self->claimed_by   if $self->has_claimed_by;
  $fm{claimed_at}   = $self->claimed_at   if $self->has_claimed_at;
  $fm{blocked}      = $self->blocked      if $self->has_blocked;
  $fm{block_reason} = $self->block_reason if $self->has_block_reason;
  $fm{started}      = $self->started      if $self->has_started;
  $fm{completed}    = $self->completed    if $self->has_completed;
  return \%fm;
}

=method to_frontmatter

  my $fm = $task->to_frontmatter;

Returns the task as a plain hash reference in kanban-md's frontmatter shape:
C<id>, C<title>, C<status>, C<priority>, C<created>, C<updated>, and C<class>
are always present, every other modelled field (C<assignee>, C<due>,
C<claimed_by>, and so on) only when its predicate is true, and whatever is
left in L</extra> fills in the rest verbatim.

This is the one place karr and kanban-md agree on what a frontmatter document
looks like. C<to_markdown> feeds the result straight to L<YAML::XS> for the
on-disk and ref form; L</to_json_hash> layers a C<body> key and a real JSON
boolean for C<blocked> on top of it for C<--json> output; C<karr board
--json> and C<karr list --json> use it the same way.

A modelled field always wins the slot it owns, and a field that has since
been cleared cannot be resurrected by a stale copy in C<extra> either --
every key karr models is stripped out of C<extra> before the modelled values
are laid on top of what remains.

=cut

=method to_json_hash

  my $data = $task->to_json_hash;

Returns the task as a plain hash reference ready for JSON encoding: the
frontmatter fields from L</to_frontmatter> plus a C<body> key when the task has
a non-empty body. Used by the C<show>, C<pick>, and C<handoff> commands to
build their C<--json> payload.

C<blocked> comes back as a JSON boolean, so an agent parsing C<--json> sees the
same C<true> kanban-md emits and never the free-text reason it used to get
there (ticket #58). A body of C<"0"> is included, because emptiness is tested by
length and not by truth (ticket #78).

=cut

sub to_json_hash {
  my ($self) = @_;
  my $data = $self->to_frontmatter;
  # to_frontmatter only ever puts a true value here, and it has to become a
  # real JSON boolean rather than a Perl one: an older JSON backend would
  # encode Perl's !!1 as the number 1.
  $data->{blocked} = JSON::MaybeXS::true() if exists $data->{blocked};
  $data->{body} = $self->body if defined $self->body && length $self->body;
  return $data;
}

sub to_markdown {
  my ($self) = @_;
  my $yaml = yaml_dump($self->to_frontmatter);
  $yaml =~ s/\A---\n//;
  my $md = "---\n${yaml}---\n";
  my $body = $self->body;
  if ( defined $body && length $body ) {
    $md .= "\n" . $body;
    # kanban-md's Write terminates the body only when it is not already
    # terminated (internal/task/file.go); matching it keeps a document karr
    # rewrites byte-identical to the one kanban-md would have written.
    $md .= "\n" unless $body =~ /\n\z/;
  }
  return $md;
}

=method to_markdown

  my $text = $task->to_markdown;

Renders the task as the Markdown-plus-YAML-frontmatter document stored in
C<refs/karr/tasks/*/data> and written by L</save>: L</to_frontmatter> dumped
as YAML between C<---> delimiters, followed by the body. The body is
terminated with a single trailing newline, added only when it does not
already end in one, to match kanban-md's own writer byte-for-byte.

=cut

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
  # Every trailing newline, not one. The file path and the ref path disagreed
  # otherwise: App::karr::Git::read_ref_with_oid chomps the blob before the
  # document reaches us, so a single strip here left the ref round trip one
  # newline shorter than the file round trip, and a body ending in blank lines
  # lost one of them per save (ticket #78). Stripping greedily makes both paths
  # agree on the same normal form -- a karr body never ends in a newline.
  $body =~ s/\n+\z//;
  return (yaml_load($yaml), $body);
}

# Split a parsed frontmatter hash into constructor arguments and passthrough
# keys. Moo drops unknown constructor arguments without a word, so anything not
# separated out here is deleted from the board on the next write (ticket #69).
sub _split_frontmatter {
  my ($class, $fm) = @_;
  my ( %args, %extra );
  for my $key ( keys %$fm ) {
    if ( $IS_FRONTMATTER_FIELD{$key} ) {
      $args{$key} = $fm->{$key};
    } else {
      $extra{$key} = $fm->{$key};
    }
  }
  return ( \%args, \%extra );
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
  my ( $args, $extra ) = $class->_split_frontmatter($fm);
  return $class->new(%$args, extra => $extra, body => $body);
}

=method from_string

  my $task = App::karr::Task->from_string($markdown_content);
  my $task = App::karr::Task->from_string($markdown_content, repair_frontmatter => 1);

Parses a Markdown-plus-YAML-frontmatter document (the same shape
L</to_markdown> writes) into a new task object. Dies with C<Invalid task
format> when the document has no frontmatter block. Frontmatter keys the
class does not model are kept on L</extra> rather than dropped (ticket #69).

C<repair_frontmatter> is for a board written before C<refs/karr/meta/encoding>
existed: only the frontmatter -- not the body -- went through L<YAML::XS>
twice and needs L<App::karr::Encoding/repair_mojibake> run over it once to
undo the double encoding. Set by
L<App::karr::Git/load_task_ref_with_oid> from the board's own
encoding-version check; nothing else should need to pass it (ticket #53).

=cut

sub from_file {
  my ($class, $file) = @_;
  $file = path($file);
  # Every failure names the file. `karr import` parses a whole directory in one
  # go, and a bare "Invalid task format" -- which is also what a CRLF card gets,
  # since _parse_content requires a literal "\A---\n" for kanban-md parity --
  # left the user to guess which card it came from (ticket #70).
  my $task = eval {
    my ($fm, $body) = $class->_parse_content($file->slurp_utf8);
    my ( $args, $extra ) = $class->_split_frontmatter($fm);
    $class->new(%$args, extra => $extra, body => $body, file_path => $file);
  };
  return $task if $task;
  my $why = $@ || 'unknown error';
  chomp $why;
  # Moo's "Missing required arguments: id, title" carries an "at <file> line N"
  # pointing into generated constructor code, which only buries the filename
  # that matters.
  $why =~ s/ at .+ line \d+\.?\z//s;
  die "$why ($file)\n";
}

=method from_file

  my $task = App::karr::Task->from_file('/path/to/007-fix-login-bug.md');

Reads C<$file>, parses it the same way L</from_string> does, and sets
C<file_path> to it so a later L</save> with no directory argument rewrites
the same file. Every failure -- an unparseable document, a missing required
field -- dies with the file path appended, stripping Moo's own "at ... line
N" suffix first so the message names the file that is wrong instead of a
line in generated constructor code (ticket #70). Used by C<karr import> to
read a whole kanban-md-style F<tasks/> directory, one file at a time.

=cut

sub save {
  my ($self, $dir) = @_;
  croak "Task has no file_path; ref-backed tasks must be persisted via BoardStore/save_task"
    if !$dir && !$self->has_file_path;
  my $file = $dir ? path($dir)->child($self->filename) : path($self->file_path);
  $file->spew_utf8($self->to_markdown);
  $self->file_path($file);
  return $file;
}

=method save

  $task->save($dir);   # write as $dir/NNN-slug.md, using the current slug
  $task->save;          # rewrite the file this task was loaded from

Writes L</to_markdown> to disk and records the file written as
C<file_path>. Given C<$dir>, the filename is derived fresh from the current
L</slug> (so a renamed task moves to a new filename, and can leave the old
one behind -- callers that materialize a whole board sweep stale files
separately; see L<App::karr::BoardStore/materialize_to>). With no C<$dir>,
rewrites C<file_path> as it stands, so a task loaded via L</from_file> saves
back to the same name it was read from even after a rename.

Dies -- C<Task has no file_path; ref-backed tasks must be persisted via
BoardStore/save_task> -- when called with no C<$dir> on a task that has never
had a C<file_path>, i.e. every task that lives only in C<refs/karr/*> and was
never materialized to a file. This is deliberate: the canonical write path
for such a task is L<App::karr::BoardStore/save_task>, and a silent no-op or
an implicit directory guess here would let a card go unwritten instead of
failing loudly (ticket #77).

=cut

1;
