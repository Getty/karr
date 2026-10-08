use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use App::karr::Foundation;
use App::karr::Error qw( is_usage_error );

# k325: karr-foundation's drain starts and supervises its agents with fork,
# setsid, alarm, a process-group kill and /bin/sh -c. On MSWin32 none of those
# exist, so it says so before it discovers a single board -- and leaves the
# mailbox commands, which only read and write refs, alone.

my $config = tempdir( CLEANUP => 1 ) . '/no-such-config.yml';

{
    local $^O = 'MSWin32';
    my $foundation = App::karr::Foundation->new( config => $config );
    my $exit = eval { $foundation->run };
    my $err  = $@;
    like $err, qr/cannot run agents on Windows/, 'a drain is refused on MSWin32';
    like $err, qr/\A[^\n]+\n?\z/, 'in one line';
    ok !is_usage_error($err), 'as a runtime failure, not a usage error';

    eval { $foundation->run('no-such-command') };
    like $@, qr/Unknown command/,
        'the command dispatch still comes first, so the mailbox is reachable';
}

{
    # Pinned, so that "elsewhere" is elsewhere when the suite runs on MSWin32.
    local $^O = 'linux';
    my $foundation = App::karr::Foundation->new( config => $config );
    eval { $foundation->run };
    unlike $@, qr/Windows/, 'and nothing is refused elsewhere';
}

done_testing;
