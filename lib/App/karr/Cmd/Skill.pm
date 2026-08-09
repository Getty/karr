# ABSTRACT: Install, check, and update bundled agent skills

package App::karr::Cmd::Skill;
our $VERSION = '0.403';
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
use Encode qw( encode_utf8 );

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
    die "Unknown action: $action (use install, check, update, or show)\n";
  }
}

sub _show {
  my ($self) = @_;
  my $content = $self->_skill_content;

  if ($self->json) {
    # Role::Output::print_json is the octet boundary for JSON output
    # (encode_json emits UTF-8 bytes), so the decoded characters from
    # _skill_content go in as-is. Encoding here as well would double-encode.
    return $self->print_json({ content => $content });
  }

  # _skill_content is decoded (slurp_utf8), so it must be encoded back to
  # bytes here or perl warns "Wide character in print". Encode at this one
  # call site rather than putting a UTF-8 layer on STDOUT: the rest of the
  # CLI already hands raw UTF-8 bytes to print (task text from the refs,
  # encode_json in Role::Output), and a global layer would double-encode
  # all of it.
  print encode_utf8($content);
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
# appended ("... Permission denied at .../Skill.pm line 135."), so an
# unwritable skill directory used to report a karr source location at the user.
# App::karr::Error reduces it to the one line that is actually about them.
sub _read_skill {
  my ($self, $file) = @_;
  my $content = eval { $file->slurp_utf8 };
  defined $content
    or user_error( "Could not read $file: ", clean_error($@) );
  return $content;
}

sub _write_skill {
  my ($self, $file, $content) = @_;
  eval { $file->parent->mkpath; $file->spew_utf8($content); 1 }
    or user_error( "Could not write $file: ", clean_error($@) );
  return;
}

sub _target_agents {
  my ($self) = @_;
  if ($self->agent) {
    my @names = split /,/, $self->agent;
    for my $name (@names) {
      die "Unknown agent: $name (known: " . join(', ', sort keys %AGENTS) . ")\n"
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
