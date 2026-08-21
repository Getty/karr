# ABSTRACT: Install, check, and update bundled agent skills

package App::karr::Cmd::Skill;
our $VERSION = '0.501';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr skill [install|check|update|show] [--agent NAME] [--global] [--force]',
);
use App::karr::Role::Output;
use App::karr::Role::CliArgs;
use App::karr::Role::ExitCodes;
use App::karr::Role::SkillFile;
use App::karr::Error qw( user_error clean_error );
use Path::Tiny;

# ExitCodes: unknown option / bad option value exits 2, not 1 (ADR 0002). Skill
# is board-less, so it does not inherit ExitCodes via BoardDiscovery -- and for
# the same reason it declares no --dir and refuses the root form of it in
# _reject_root_dir below (#226).
# SkillFile: _skill_content and _write_skill, shared with `karr init
# --claude-skill`, which writes the same file this command writes for the
# claude-code agent (tickets #145, #146).
with 'App::karr::Role::Output', 'App::karr::Role::CliArgs',
     'App::karr::Role::ExitCodes', 'App::karr::Role::SkillFile';

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

C<--global> selects the home-directory location instead of the project-local
one; the two coincide for C<claude-code> and C<cursor> but differ for
C<codex> (see L</SUPPORTED AGENTS>).

=head1 TARGET DIRECTORY

The project-local target is the B<current working directory>: the skill file
is written straight underneath it, at
F<.claude/skills/kanban-issues-karr-cli/SKILL.md> for C<claude-code> and at
the equivalent path for the other agents. Nothing is discovered on the way
there and no repository is involved -- this command has no board, and
installing into a directory that is not a Git repository at all is a
supported use. C<--global> is the same idea one level up: the target is the
current user's home directory instead. When C<--agent> is omitted, even the
auto-detection reads the current directory, so both which agents are touched
and where their files land follow from where the command was run.

The root option C<--dir> is therefore B<refused>, in both placements, and
both exit C<2>: C<karr skill install --dir PATH> is an unknown option (this
command declares none), and C<karr --dir PATH skill install> is a usage error
that names the current directory as the target. C<--dir> is the starting
point of a search B<upward> for one repository's root -- which is why it may
name any directory inside that repository -- and that is not what this
command's target is; handed the same path, the two would answer about
different directories. To install into another tree, C<cd> there. Before
ticket #226 the root placement was accepted and then discarded without a
word, so the file was written into the tree the caller happened to be
standing in while the message read as if the named one had been used.

C<karr init --claude-skill> writes the very same F<SKILL.md> and does honour
C<--dir>: it installs into the root of the repository it is initializing, and
it needs a repository in the first place.

=head1 SUPPORTED AGENTS

The built-in agent targets are C<claude-code>, C<codex>, and C<cursor>. When
C<--agent> is omitted, the command auto-detects available client directories and
falls back to all known agents if nothing is detected.

=head1 ACTIONS

=over 4

=item * C<install>

Writes the current bundled skill file to the selected target locations. A
target that already has a F<SKILL.md> is left alone and reported C<exists>
unless C<--force> is given, which overwrites it unconditionally. Every target
is reported with its absolute path, in the plain output as well as under the
C<path> key of C<--json>, so the message says which tree the file went into.

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
  $self->_reject_root_dir($chain_ref);
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

# _write_skill -- the in-place write, and why it has to be one -- lives in
# App::karr::Role::SkillFile, composed above: `karr init --claude-skill` writes
# the very same .claude/skills/kanban-issues-karr-cli/SKILL.md, and kept its own spew_utf8 copy of
# this rule until ticket #145 because the rule lived here (#142). _skill_content,
# which finds the bundled file in the first place, followed it there in #146 --
# it was duplicated in Cmd::Init down to the last line but one.

# `karr skill install --dir PATH` was always rejected by MooX::Options -- this
# command declares no such option -- but `karr --dir PATH skill install` was
# not: --dir is declared on App::karr::Role::BoardDiscovery, the root command
# composes it via App::karr::Role::BoardAccess, and MooX::Cmd leaves the parsed
# value on the root instance in the command chain, where nothing here ever
# looked. So the option went in without a word and the install ran on the
# current directory instead -- putting a file into a tree the caller had not
# named, under a message that read like the named one (#226). `dashboard` had
# the same leak (#225) and only ever read; this one writes.
#
# Refused rather than adopted as a synonym, because --dir is not what this
# command's target is. --dir seeds a walk UPWARD to one repository's root
# (App::karr::Role::BoardDiscovery/_build_git_root, which is why it may name
# any directory inside that repository), while the project-local target here is
# the current directory itself, repository or not: `karr skill` is board-less
# and installing into a plain directory is a supported use, pinned by t/226.
# Honouring --dir would have meant either refusing those installs or giving one
# option two meanings that answer about different directories. `cd` is how you
# install into another tree, and `karr init --claude-skill` is the command that
# writes this same file through git_root.
#
# The root is read from $chain_ref the way App::karr::Cmd::Dashboard reads it
# for its own refusal and App::karr::Cmd::GetRefs reads it to honour the
# option; a directly constructed instance (no MooX::Cmd dispatch, hence an
# empty chain) has no root option to reject.
sub _reject_root_dir {
  my ($self, $chain_ref) = @_;
  return unless $chain_ref && @$chain_ref;
  my $root = $chain_ref->[0];
  return unless $root && $root->can('has_dir') && $root->has_dir;
  # Wrapped to stay inside 80 columns with usage_error's own "Usage error: "
  # prefix on the first line: what to type comes first, the reason after it.
  $self->usage_error(
      "skill does not take --dir; its target is the current directory:\n"
    . "cd PATH && karr skill install\n"
    . "(--dir seeds a search upward for one repository's root, while skill is\n"
    . "board-less and works where it is run -- or under \$HOME with --global.)"
  );
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
  # Absolute, because this path is printed back at the caller and handed to
  # --json consumers: `installed to .claude/skills/...` named no tree in
  # particular and was as true of the directory the file went into as of the
  # one the caller meant (#226, point 3). ->absolute prepends the current
  # directory without resolving symlinks, so what comes back is the path the
  # caller would have typed rather than a realpath they may not recognize. The
  # global branch is absolute already: $HOME is.
  my $base = $self->global
    ? path($ENV{HOME})->child($spec->{global})
    : path('.')->absolute->child($spec->{project});
  return $base->child('kanban-issues-karr-cli');
}

1;
