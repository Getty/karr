# ABSTRACT: Install, check, and update bundled agent skills

package App::karr::Cmd::Skill;
our $VERSION = '0.500';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr skill [install|check|update|show] [--agent NAME] [--global] [--force]',
);
use App::karr::Role::Output;
use App::karr::Role::CliArgs;
use App::karr::Role::ExitCodes;
use App::karr::Error qw( user_error clean_error );
use Path::Tiny;
use File::ShareDir ();

# ExitCodes: unknown option / bad option value exits 2, not 1 (ADR 0002). Skill
# is board-less, so it does not inherit ExitCodes via BoardDiscovery.
with 'App::karr::Role::Output', 'App::karr::Role::CliArgs', 'App::karr::Role::ExitCodes';

=head1 SYNOPSIS

    karr skill install
    karr skill install --agent codex,cursor
    karr skill check --global
    karr skill update --force
    karr skill show

=head1 DESCRIPTION

Installs and maintains the bundled C<karr> skill file for supported agent
clients. The command can target project-local directories or global skill
locations in the current user's home directory, which makes it useful both for
direct Perl installs and Docker-wrapped vendor usage.

Writes go into the target file B<in place>, keeping its inode, so a
F<SKILL.md> that is one link of a hardlink chain shared across projects stays
part of that chain instead of being silently broken out of it.

=head1 SUPPORTED AGENTS

The built-in agent targets are C<claude-code>, C<codex>, and C<cursor>. When
C<--agent> is omitted, the command auto-detects available client directories and
falls back to all known agents if nothing is detected.

=head1 ACTIONS

=over 4

=item * C<install>

Writes the current bundled skill file to the selected target locations.

=item * C<check>

Compares installed skill files with the bundled version and exits non-zero when
one or more targets are outdated.

=item * C<update>

Refreshes existing installed copies in place.

=item * C<show>

Prints the bundled skill content to standard output. With C<--json> the same
content is emitted as a JSON object under the C<content> key instead of raw
Markdown.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Init>,
L<App::karr::Cmd::Context>, L<App::karr::Cmd::Config>

=cut

option agent => (
  is => 'ro',
  format => 's',
  doc => 'Target agent (claude-code, codex, cursor)',
);

option global => (
  is => 'ro',
  doc => 'Install/check globally (~/) instead of project-level',
);

option force => (
  is => 'ro',
  doc => 'Force reinstall even if current',
);

my %AGENTS = (
  'claude-code' => { project => '.claude/skills', global => '.claude/skills' },
  'codex'       => { project => '.agents/skills', global => '.codex/skills' },
  'cursor'      => { project => '.cursor/skills', global => '.cursor/skills' },
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;
  my @pos    = $self->positional_args($args_ref);
  my $action = $pos[0] // 'install';
  $self->check_positional_args($args_ref, 1);   # only the action is a positional

  if ($action eq 'install') {
    $self->_install;
  } elsif ($action eq 'check') {
    $self->_check;
  } elsif ($action eq 'update') {
    $self->_update;
  } elsif ($action eq 'show') {
    $self->_show;
  } else {
    # Leading "Usage:" is what bin/karr's handler keys on to exit 2 rather than
    # 1 (ADR 0002: an invalid value is a usage error). Becomes a one-line swap
    # to Role::ExitCodes' usage_error once that lands (ticket #76).
    user_error( "Usage: karr skill [install|check|update|show]\n",
                "Unknown action: $action (use install, check, update, or show)" );
  }
}

sub _show {
  my ($self) = @_;
  my $content = $self->_skill_content;

  if ($self->json) {
    # Characters in, characters out, exactly like the plain branch below:
    # print_json goes through App::karr::Encoding::json_encode, which is the
    # character-level codec, and STDOUT's :encoding(UTF-8) layer does the one
    # and only encode. _skill_content is already decoded (slurp_utf8), so it
    # goes in untouched.
    return $self->print_json({ content => $content });
  }

  # Ticket #33 encoded here, because back then the rest of the CLI handed raw
  # octets to print and a layer on STDOUT would have double-encoded them.
  # Ticket #53 removed that premise: STDOUT now carries :encoding(UTF-8) and
  # every command prints characters, so _skill_content goes out as-is.
  # Encoding it again here would be the very double encode #33 was avoiding.
  print $content;
  return;
}

sub _install {
  my ($self) = @_;
  my @agents = $self->_target_agents;
  my $content = $self->_skill_content;
  my @results;

  for my $agent (@agents) {
    my $dir = $self->_skill_dir($agent);
    my $file = $dir->child('SKILL.md');

    if ($file->exists && !$self->force) {
      push @results, { agent => $agent, status => 'exists', path => "$file" };
      printf "%-12s already installed (use --force to reinstall)\n", $agent unless $self->json;
      next;
    }

    $self->_write_skill($file, $content);
    push @results, { agent => $agent, status => 'installed', path => "$file" };
    printf "%-12s installed to %s\n", $agent, $file unless $self->json;
  }

  if ($self->json) {
    $self->print_json(\@results);
  }
}

sub _check {
  my ($self) = @_;
  my @agents = $self->_target_agents;
  my $current = $self->_skill_content;
  my @results;
  my $outdated = 0;

  for my $agent (@agents) {
    my $file = $self->_skill_dir($agent)->child('SKILL.md');

    unless ($file->exists) {
      push @results, { agent => $agent, status => 'not installed' };
      printf "%-12s not installed\n", $agent unless $self->json;
      next;
    }

    my $installed = $self->_read_skill($file);
    if ($installed eq $current) {
      push @results, { agent => $agent, status => 'current' };
      printf "%-12s current\n", $agent unless $self->json;
    } else {
      push @results, { agent => $agent, status => 'outdated' };
      printf "%-12s outdated\n", $agent unless $self->json;
      $outdated++;
    }
  }

  if ($self->json) {
    $self->print_json(\@results);
  }

  exit(1) if $outdated;
}

sub _update {
  my ($self) = @_;
  my @agents = $self->_target_agents;
  my $content = $self->_skill_content;
  my @results;

  for my $agent (@agents) {
    my $file = $self->_skill_dir($agent)->child('SKILL.md');

    unless ($file->exists) {
      push @results, { agent => $agent, status => 'not installed' };
      printf "%-12s not installed (run 'karr skill install' first)\n", $agent unless $self->json;
      next;
    }

    my $installed = $self->_read_skill($file);
    if ($installed eq $content) {
      push @results, { agent => $agent, status => 'current' };
      printf "%-12s already current\n", $agent unless $self->json;
    } else {
      $self->_write_skill($file, $content);
      push @results, { agent => $agent, status => 'updated' };
      printf "%-12s updated\n", $agent unless $self->json;
    }
  }

  if ($self->json) {
    $self->print_json(\@results);
  }
}

# Path::Tiny raises Path::Tiny::Error objects that stringify with the call site
# appended ("mkpath failed for ...: Permission denied at .../Cmd/Skill.pm line
# NNN."), so an unwritable skill directory used to report a karr source
# location at the user. App::karr::Error reduces it to the one line that is
# actually about them (ticket #77).
sub _read_skill {
  my ($self, $file) = @_;
  my $content = eval { $file->slurp_utf8 };
  defined $content
    or user_error( "Could not read $file: ", clean_error($@) );
  return $content;
}

# Written in place, on purpose. Path::Tiny's spew_utf8 writes a temp file and
# renames it over the target, so the path it wrote comes back on a *new* inode.
# For a SKILL.md that is the wrong move: skill files are kept as hardlink
# chains (manage-skills), one inode behind the same relative path in dozens of
# projects, so the rename silently breaks the updated path out of its chain --
# that one path gets the new text, every other project keeps the old inode with
# the old text, and the link count drops with nothing said (ticket #142, found
# in kubernetes-ocp, where the workaround was `karr skill show` into a shell
# redirect).
#
# append_utf8 with truncate is the in-place counterpart: Path::Tiny sysopens
# the existing inode for writing, locks it, truncates, and writes through it,
# so every link sees the new content. It is Path::Tiny's own UTF-8, i.e. still
# character-level, which is what the file edge is allowed to use -- encoding on
# top of it would be the double encode App::karr::Encoding forbids. A target
# that does not exist yet is created by the same call (">" with O_CREAT), so
# install and update share this one path.
sub _write_skill {
  my ($self, $file, $content) = @_;

  eval { $file->parent->mkpath; 1 }
    or user_error( "Could not write $file: ", clean_error($@) );

  return if eval { $file->append_utf8( { truncate => 1 }, $content ); 1 };
  my $in_place_error = $@;

  # Opening the file for writing is the one thing the rename never needed: it
  # only needs a writable *directory*, so it used to update a read-only
  # SKILL.md happily. Keep that working rather than turning a mode bit into a
  # failure -- but this is now the only way a chain can break, so when the
  # target really was hardlinked, say so instead of breaking it silently.
  my $links = ( stat "$file" )[3];
  eval { $file->spew_utf8($content); 1 }
    or user_error( "Could not write $file: ", clean_error($in_place_error) );

  if ( $links && $links > 1 ) {
    my $others = $links - 1;
    my $note = $others == 1
      ? 'one other hardlink to it still holds the previous content.'
      : "$others other hardlinks to it still hold the previous content.";
    warn "Warning: $file could not be written in place ("
      . clean_error($in_place_error)
      . ") and was replaced instead;\n$note\n";
  }

  return;
}

sub _target_agents {
  my ($self) = @_;
  if ($self->agent) {
    my @names = split /,/, $self->agent;
    for my $name (@names) {
      # --agent is a value MooX::Options cannot validate, so the usage error is
      # raised here; see the note on the unknown-action branch in execute.
      user_error( "Usage: karr skill --agent NAME[,NAME,...]\n",
                  "Unknown agent: $name (known: ", join( ', ', sort keys %AGENTS ), ")" )
        unless $AGENTS{$name};
    }
    return @names;
  }
  # Auto-detect: return agents whose directories exist, or all if none found
  my @detected;
  for my $name (sort keys %AGENTS) {
    my $dir = $self->_skill_dir($name)->parent;
    push @detected, $name if $dir->exists;
  }
  return @detected ? @detected : sort keys %AGENTS;
}

sub _skill_dir {
  my ($self, $agent) = @_;
  my $spec = $AGENTS{$agent} or die "Unknown agent: $agent\n";
  my $base = $self->global
    ? path($ENV{HOME})->child($spec->{global})
    : path('.')->child($spec->{project});
  return $base->child('karr');
}

sub _skill_content {
  my ($self) = @_;

  # Try File::ShareDir (installed dist)
  my $installed = eval {
    my $dir = File::ShareDir::dist_dir('App-karr');
    my $file = path($dir)->child('claude-skill.md');
    $file->slurp_utf8 if $file->exists;
  };
  return $installed if defined $installed && length $installed;

  # Fallback: relative to module location (development)
  my $module_path = $INC{'App/karr/Cmd/Skill.pm'};
  if ($module_path) {
    my $share = path($module_path)->parent(5)->child('share/claude-skill.md');
    return $share->slurp_utf8 if $share->exists;
  }

  die "Could not find claude-skill.md. Is App::karr properly installed?\n";
}

1;
