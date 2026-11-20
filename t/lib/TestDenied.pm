package TestDenied;
use strict;
use warnings;

# Scenes for the read-only-clone tests (k333, parts B, C and E): a bare
# origin, one clone with an initialised and published board, and the knobs to
# make the origin refuse writes (chmod) or the push URL unreachable (a closed
# local port), plus a `git` shim that logs every invocation so "no push was
# attempted" is a count, not a guess.
#
# Everything lives in temporary directories, HOME included; nothing here
# touches the developer's board or configuration.
#
# The karr runs are subprocesses (KARR_TEST_SUBPROC): the git child whose
# stderr karr classifies a denial from needs a real STDERR, which the
# in-process runner's capture does not have.

BEGIN { $ENV{KARR_TEST_SUBPROC} = 1 }

use Exporter 'import';
use Cwd ();
use File::Temp qw( tempdir );
use JSON::PP ();
use Path::Tiny qw( path );
use TestKarr qw( run_karr );

our @EXPORT_OK = qw(
    new_scene run deny allow pushes reset_log refs_dump karr_config
    add_mirror origin_has_refs can_deny closed_port_url lines_matching
);

my @SCENES;

# Permissions must come back before File::Temp removes the directories; this
# END block is compiled after File::Temp's, so it runs first.
END { allow($_) for @SCENES }

# Whether a bare repository can be made unwritable for this user: not as root,
# which ignores the mode bits.
sub can_deny { return $> != 0 }

# new_scene( seed => N ): origin.git (bare), clone a/ with a board that is on
# the origin, N seed cards (default 0) published too. The shim is first on PATH
# from here on, for this process and every karr child.
sub new_scene {
    my (%opt) = @_;
    my $work = tempdir( CLEANUP => 1 );
    my $s    = { work => $work, origin => "$work/origin.git", clone => "$work/a" };

    my ($real_git) = grep { -x $_ } map { "$_/git" } split /:/, $ENV{PATH};
    die 'no git binary on PATH' unless $real_git;
    my $bin = path("$work/bin");
    $bin->mkpath;
    $s->{log} = path("$work/git-calls.log");
    $bin->child('git')->spew(
        "#!/bin/sh\necho \"\$*\" >> '$s->{log}'\nexec '$real_git' \"\$@\"\n");
    chmod 0755, $bin->child('git')->stringify;

    # No HOME config of the developer, no prompt a credential helper could open.
    mkdir "$work/home";
    $ENV{HOME}                = "$work/home";
    $ENV{GIT_TERMINAL_PROMPT} = 0;
    $ENV{PATH}                = "$bin:$ENV{PATH}";

    system( 'git', 'init', '-q', '--bare', $s->{origin} ) == 0 or die 'git init --bare';
    system("git clone -q '$s->{origin}' '$s->{clone}' 2>/dev/null");
    system( 'git', '-C', $s->{clone}, 'config', 'user.email', 'a@karr.test' );
    system( 'git', '-C', $s->{clone}, 'config', 'user.name',  'agent-a' );

    run( $s, 'init' )->{exit} == 0 or die 'karr init failed';
    for my $n ( 1 .. ( $opt{seed} // 0 ) ) {
        run( $s, 'create', "seed $n" )->{exit} == 0 or die 'seed create failed';
    }
    # init pushes nothing; put the board on the origin so that what follows is
    # a change against a published board, not against an empty remote.
    run( $s, 'sync' )->{exit} == 0 or die 'karr sync failed';

    push @SCENES, $s;
    return $s;
}

sub run {
    my ( $s, @argv ) = @_;
    return run_karr( $s->{clone}, @argv );
}

sub deny  { my ($s) = @_; system( 'chmod', '-R', 'a-w', $s->{origin} ); return }
sub allow {
    my ($s) = @_;
    for my $dir ( grep { defined && -d } $s->{origin}, $s->{mirror} ) {
        system( 'chmod', '-R', 'u+w', $dir );
    }
    return;
}

# A writable second bare repository holding exactly what the origin holds now:
# the "writable remote" a denied clone is pointed at with set-url --push. Make
# it BEFORE the clone changes anything, so both stand at the same board state.
sub add_mirror {
    my ($s) = @_;
    $s->{mirror} = "$s->{work}/mirror.git";
    system( 'git', 'clone', '-q', '--mirror', $s->{origin}, $s->{mirror} ) == 0
        or die 'git clone --mirror';
    return $s->{mirror};
}

# A push URL nothing listens on: the board pulls fine from `url`, and a push
# is refused with a connection error.
sub closed_port_url { return 'http://127.0.0.1:1/x.git' }

# Number of `git push` invocations since reset_log.
sub pushes {
    my ($s) = @_;
    return 0 unless $s->{log}->exists;
    return scalar grep { /(?:^|\s)push(?:\s|$)/ } $s->{log}->lines;
}
sub reset_log { $_[0]{log}->remove; return }

# The board's refs and their values, byte for byte. $repo is a directory;
# @patterns default to the board and the foundation namespace.
sub refs_dump {
    my ( $repo, @patterns ) = @_;
    @patterns = ( 'refs/karr', 'refs/karr-foundation' ) unless @patterns;
    my $out = `git -C '$repo' for-each-ref --format='%(refname) %(objectname)' @patterns`;
    return $out;
}

# The karr.* keys of the clone's git config, as a hash (keys lower-cased by git).
sub karr_config {
    my ($s) = @_;
    my %c;
    for my $line ( `git -C '$s->{clone}' config --local --get-regexp '^karr\\.'` ) {
        chomp $line;
        my ( $k, $v ) = split / /, $line, 2;
        $c{$k} = $v;
    }
    return \%c;
}

# Whether the origin (or any bare repository) has refs under a prefix.
sub origin_has_refs {
    my ( $repo, $prefix ) = @_;
    my $out = `git -C '$repo' for-each-ref $prefix`;
    return length $out ? 1 : 0;
}

sub lines_matching {
    my ( $text, $re ) = @_;
    return scalar grep { $_ =~ $re } split /\n/, $text;
}

1;
