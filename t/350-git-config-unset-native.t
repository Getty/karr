#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use App::karr::Git;

# Ticket k346: git_config_unset removes a key through Git::Native::Config->delete
# (which refreshes libgit2's cached config first), not through a private FFI
# call. The private call answered GIT_ENOTFOUND from a stale cache when another
# process had written the key, reported success and left the key on disk.

my $src_file = Cwd::abs_path('lib/App/karr/Git.pm');
my $dir      = tempdir( CLEANUP => 1 );

# Run git in the temporary repository, never anywhere else.
sub g { system( 'git', '--git-dir', "$dir/.git", @_ ) >> 8 }
system( 'git', 'init', '-q', $dir ) == 0 or BAIL_OUT('git init failed');

sub on_disk { g( 'config', '--local', '--get', $_[0] ) == 0 }

my $git = App::karr::Git->new( dir => $dir );

subtest 'key written by another process after the config was cached' => sub {
    is $git->git_config_get('karr.x'), undef, 'cache primed: key unset';
    is g( 'config', '--local', 'karr.x', '1' ), 0, 'other process sets it';
    is $git->git_config_unset('karr.x'), 1, 'unset reports success';
    ok !on_disk('karr.x'), 'key is really gone from disk';
};

subtest 'multivar key goes through the CLI fallback' => sub {
    g( 'config', '--local', '--add', 'karr.m', 'a' );
    g( 'config', '--local', '--add', 'karr.m', 'b' );
    is $git->git_config_unset('karr.m'), 1, 'unset reports success';
    ok !on_disk('karr.m'), 'both values gone';
};

subtest 'key that was never set' => sub {
    is $git->git_config_unset('karr.never'), 1, 'returns 1';
};

subtest 'set then unset through the object' => sub {
    ok $git->git_config_set( 'karr.y', 'v' ), 'set';
    is $git->git_config_unset('karr.y'), 1, 'unset';
    ok !on_disk('karr.y'), 'gone from disk';
};

subtest 'source no longer reaches into libgit2 privately' => sub {
    my $src = path($src_file)->slurp_utf8;
    my ($body) = $src =~ /^sub git_config_unset \{(.*?)^\}/ms;
    ok defined $body, 'found the sub';
    unlike $body, qr/_handle|Git::Libgit2::FFI|CONFIG_DELETE_FN/, 'no private path';
};

done_testing;
