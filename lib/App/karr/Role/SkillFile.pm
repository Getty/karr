# ABSTRACT: The one way karr writes a bundled skill file to disk

package App::karr::Role::SkillFile;
our $VERSION = '0.500';
use Moo::Role;
# Loaded without importing, for the reason spelled out in
# App::karr::Role::Output: a Moo::Role composes every sub in its package into
# its consumers, so `use App::karr::Error qw( user_error )` here would quietly
# make user_error and clean_error methods on `karr skill` and `karr init`.
use App::karr::Error ();

# Nothing is required of the consumer. _write_skill is handed both the target
# and the content, and reaches for nothing else -- which is the point of the
# role: `karr skill` is board-less while `karr init` composes
# App::karr::Role::BoardDiscovery, and the only way one helper can serve both
# is by depending on neither (the rule is ticket #141's, read from the other
# side).

=head1 DESCRIPTION

Two commands put the bundled skill file on disk -- C<karr skill install> /
C<karr skill update>, and C<karr init --claude-skill>, which writes the same
F<.claude/skills/karr/SKILL.md> that C<karr skill install --agent claude-code>
does. This role is the single place that knows I<how> that write has to happen,
so the rule cannot be fixed in one command and left wrong in the other, which is
exactly what happened between tickets #142 and #145.

The rule: the target is written B<in place>, keeping its inode, so a F<SKILL.md>
that is one link of a hardlink chain shared across projects stays part of that
chain.

=head1 SEE ALSO

L<App::karr::Cmd::Skill>, L<App::karr::Cmd::Init>

=cut

# Written in place, on purpose. Path::Tiny's spew_utf8 writes a temp file and
# renames it over the target, so the path it wrote comes back on a *new* inode.
# For a SKILL.md that is the wrong move: skill files are kept as hardlink
# chains (manage-skills), one inode behind the same relative path in dozens of
# projects, so the rename silently breaks the updated path out of its chain --
# that one path gets the new text, every other project keeps the old inode with
# the old text, and the link count drops with nothing said (ticket #142, found
# in kubernetes-ocp, where the workaround was `karr skill show` into a shell
# redirect; ticket #145 for the same call left standing in `karr init
# --claude-skill`, which is why this lives in a role instead of in one command).
#
# append_utf8 with truncate is the in-place counterpart: Path::Tiny sysopens
# the existing inode for writing, locks it, truncates, and writes through it,
# so every link sees the new content. It is Path::Tiny's own UTF-8, i.e. still
# character-level, which is what the file edge is allowed to use -- encoding on
# top of it would be the double encode App::karr::Encoding forbids. A target
# that does not exist yet is created by the same call (">" with O_CREAT), so
# install, update and init share this one path.
sub _write_skill {
  my ($self, $file, $content) = @_;

  eval { $file->parent->mkpath; 1 }
    or App::karr::Error::user_error( "Could not write $file: ",
                                     App::karr::Error::clean_error($@) );

  return if eval { $file->append_utf8( { truncate => 1 }, $content ); 1 };
  my $in_place_error = $@;

  # Opening the file for writing is the one thing the rename never needed: it
  # only needs a writable *directory*, so it used to update a read-only
  # SKILL.md happily. Keep that working rather than turning a mode bit into a
  # failure -- but this is now the only way a chain can break, so when the
  # target really was hardlinked, say so instead of breaking it silently.
  my $links = ( stat "$file" )[3];
  eval { $file->spew_utf8($content); 1 }
    or App::karr::Error::user_error( "Could not write $file: ",
                                     App::karr::Error::clean_error($in_place_error) );

  if ( $links && $links > 1 ) {
    my $others = $links - 1;
    my $note = $others == 1
      ? 'one other hardlink to it still holds the previous content.'
      : "$others other hardlinks to it still hold the previous content.";
    warn "Warning: $file could not be written in place ("
      . App::karr::Error::clean_error($in_place_error)
      . ") and was replaced instead;\n$note\n";
  }

  return;
}

1;
