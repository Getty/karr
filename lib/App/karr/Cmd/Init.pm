# ABSTRACT: Initialize a new karr board

package App::karr::Cmd::Init;
our $VERSION = '0.500';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr init [--name TEXT] [--statuses LIST] [--claude-skill]',
);
use Path::Tiny;
use File::ShareDir ();
use App::karr::Error qw( user_error clean_error );
use App::karr::Config;
use App::karr::Role::BoardDiscovery;

with 'App::karr::Role::BoardDiscovery';

=head1 SYNOPSIS

    karr init --name "My Project"
    karr init --statuses backlog,todo,in-progress,review,done
    karr init --name "Client Work" --claude-skill

=head1 DESCRIPTION

Creates a new board inside C<refs/karr/*> in the current Git repository. The
command writes the initial config and metadata refs and can optionally install
the bundled Claude Code skill into the repository.

=head1 OPTIONS

=over 4

=item * C<--name>

Sets the board name stored in C<board.name>.

=item * C<--statuses>

Replaces the default status list with the comma-separated statuses you supply.

=item * C<--claude-skill>

Copies the bundled skill file to F<.claude/skills/karr/SKILL.md>.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Config>,
L<App::karr::Cmd::Create>, L<App::karr::Cmd::Skill>

=cut

option name => (
  is => 'ro',
  format => 's',
  doc => 'Board name',
);

option statuses => (
  is => 'ro',
  format => 's',
  doc => 'Comma-separated status list',
);

option claude_skill => (
  is => 'ro',
  doc => 'Install Claude Code skill for karr',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  # git_root honours --dir (both call forms) and dies loudly if the target is
  # not a Git repository, instead of hardcoding the current directory.
  my $root  = $self->git_root;
  my $store = $self->store;
  die "Board already exists in refs/karr/\n" if $store->board_exists;

  my $overrides = { version => 1 };
  $overrides->{board} = { name => $self->name } if defined $self->name;

  if ($self->statuses) {
    my @statuses = split /,/, $self->statuses;
    $overrides->{statuses} = \@statuses;
  }

  my $effective = App::karr::Config->effective_config($overrides);
  $store->save_config($effective);
  # Not set_next_id(1): init now also completes a board that a stray write
  # command left half-built (#62), and resetting the counter under tasks that
  # are already there would hand the next `karr create` an id it would then
  # overwrite.
  $store->ensure_next_id;
  # A board born here is written under the current encoding contract, so mark
  # it and spare it the legacy-mojibake repair (ticket #53).
  $store->stamp_encoding_version;
  # And stamp its identity, the thing a pull compares against the remote's to
  # recognise a swapped board (#95). ensure_, not set_: init also completes
  # half-boards (#62), and re-keying one that already carries an id would
  # make every other clone read this board as a foreign one.
  $store->ensure_board_id;

  print "Initialized karr board in refs/karr/\n";

  # The materialized file view (config.yml + tasks/) is a disposable view of the
  # canonical refs and must never be committed. Ensure the board-root .gitignore
  # covers it, appending idempotently -- kanban-md does the same at init time.
  #
  # Unless the project got there first: `tasks/` and `config.yml` at a
  # repository root are perfectly ordinary names for a project to already use,
  # and git applies no ignore rule to a file it already tracks. The entry would
  # therefore change nothing at all while telling every later reader that karr
  # owns a path the project owns -- and it would say so right where `karr
  # materialize` refuses to write, for that very reason (tickets #48, #89). Say
  # nothing rather than something untrue.
  my @owned = $store->project_owned_view_paths($root);
  if (@owned) {
    print "Left .gitignore alone: git already tracks content at "
      . join( ', ', @owned ) . ".\n"
      . "Those paths belong to the project, not to karr's file view, so karr is "
      . "not\nclaiming them here.\n";
  }
  else {
    my @ignored = $store->ensure_gitignore( $root->stringify );
    print "Added .gitignore entries for the file view: " . join( ', ', @ignored ) . "\n"
      if @ignored;
  }

  if ($self->claude_skill) {
    $self->_install_claude_skill($root);
  }
}

sub _install_claude_skill {
  my ($self, $root) = @_;
  my $skill_dir = $root->child('.claude/skills/karr');
  # An unwritable .claude is the project's layout, not a karr bug: Path::Tiny
  # would otherwise report this file and line at the user (#77).
  eval { $skill_dir->mkpath; 1 }
    or user_error( "Could not create $skill_dir: ", clean_error($@) );

  my $skill_content = $self->_find_skill_source;
  my $target = $skill_dir->child('SKILL.md');
  eval { $target->spew_utf8($skill_content); 1 }
    or user_error( "Could not write $target: ", clean_error($@) );
  print "Installed Claude Code skill to .claude/skills/karr/SKILL.md\n";
}

sub _find_skill_source {
  my ($self) = @_;

  # Try File::ShareDir (installed dist)
  my $installed = eval {
    my $dir = File::ShareDir::dist_dir('App-karr');
    my $file = path($dir)->child('claude-skill.md');
    $file->slurp_utf8 if $file->exists;
  };
  return $installed if defined $installed && length $installed;

  # Fallback: relative to module location (development)
  my $module_path = $INC{'App/karr/Cmd/Init.pm'};
  if ($module_path) {
    my $share = path($module_path)->parent(5)->child('share/claude-skill.md');
    return $share->slurp_utf8 if $share->exists;
  }

  die "Could not find claude-skill.md. Is App::karr properly installed?\n";
}

1;
