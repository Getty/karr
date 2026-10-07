use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use Path::Tiny;

use App::karr::Home qw( home_dir );
use App::karr::Git;
use App::karr::CrossBoard;
use App::karr::Foundation;

# k326: four places built a path from $ENV{HOME} directly. PowerShell and cmd
# set USERPROFILE and no HOME, so on Windows the ssh key was looked for under
# "/.ssh/", `karr skill --global` died inside Path::Tiny, and the two
# karr-foundation config lookups died the same way. One helper answers the
# question now, and every site is run here with HOME unset.

subtest 'home_dir' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    {
        local $ENV{HOME} = $dir;
        is home_dir(), $dir, 'HOME answers';
    }
    {
        local $ENV{HOME};
        delete $ENV{HOME};
        local $ENV{USERPROFILE} = $dir;
        local $^O = 'MSWin32';
        is home_dir(), $dir, 'USERPROFILE answers on MSWin32 when HOME is unset';
    }
    {
        local $ENV{HOME} = '';
        local $ENV{USERPROFILE} = $dir;
        local $^O = 'MSWin32';
        is home_dir(), $dir, 'an empty HOME is an unset one';
    }
    {
        local $ENV{HOME} = "$dir/home";
        local $ENV{USERPROFILE} = "$dir/profile";
        local $^O = 'MSWin32';
        is home_dir(), "$dir/home", 'HOME wins where both are set (Git Bash)';
    }
    {
        local $ENV{HOME};
        delete $ENV{HOME};
        local $ENV{USERPROFILE} = $dir;
        local $^O = 'linux';
        is home_dir(), undef, 'USERPROFILE is not consulted elsewhere';
    }
};

# From here on: no HOME, as under PowerShell.
delete $ENV{HOME};
delete $ENV{USERPROFILE};

sub warnings_from {
    my ($code) = @_;
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, $_[0] };
    $code->();
    return \@warned;
}

subtest 'the ssh key lookup' => sub {
    my $cb = App::karr::Git::_default_credentials_cb();
    my $answer;
    my $warned = warnings_from( sub {
        # allowed_types 2 = ssh key. The first call offers the agent; the
        # second is the one that walks ~/.ssh.
        $cb->( username_from_url => 'git', allowed_types => 2 );
        $answer = $cb->( username_from_url => 'git', allowed_types => 2 );
    } );
    is_deeply $warned, [], 'no uninitialized-value warning without a home';
    is $answer, undef, 'and no key is offered from a path that was never asked for';

    my $home = tempdir( CLEANUP => 1 );
    path($home)->child('.ssh')->mkpath;
    path($home)->child( '.ssh', 'id_ed25519' )->spew('not a key');
    local $ENV{USERPROFILE} = $home;
    local $^O = 'MSWin32';
    my $with = App::karr::Git::_default_credentials_cb();
    $with->( username_from_url => 'git', allowed_types => 2 );
    my $cred = $with->( username_from_url => 'git', allowed_types => 2 );
    ok $cred, 'with USERPROFILE on MSWin32 the key under it is offered';
};

subtest 'karr skill --global' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $dir );
    my $r = run_karr( $dir, 'skill', 'check', '--global', '--agent',
        'claude-code' );
    is $r->{exit}, 1, 'fails as a runtime error';
    like $r->{stderr}, qr/HOME/, 'and names the variable that is missing';
    unlike $r->{stderr}, qr/Path::Tiny| line \d+/,
        'in one clean line, not from inside Path::Tiny';
};

subtest 'the fleet config lookups' => sub {
    my $cross = App::karr::CrossBoard->new;
    my $data  = eval { $cross->_config_data };
    is $@, '', 'CrossBoard: no default config file is no error';
    is_deeply $data, {}, 'and reads as an empty config';

    my $foundation = eval { App::karr::Foundation->new };
    my $path = eval { $foundation->_config_path };
    like $@, qr/HOME/, 'Foundation: the default config path names what is missing';
    unlike $@, qr/Path::Tiny/, 'rather than dying inside Path::Tiny';

    my $given = tempdir( CLEANUP => 1 ) . '/config.yml';
    is eval { App::karr::Foundation->new( config => $given )->_config_path },
        $given, 'an explicit --config needs no home at all';
};

done_testing;
