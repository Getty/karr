package RaceBeforePush;
use strict;
use warnings;

# Loaded with -MRaceBeforePush into one karr process to make a two-clone race
# deterministic: the first board push this process makes runs the shell
# command in KARR_TEST_RACE first -- typically a karr command in a second
# clone -- and only then goes ahead. That is exactly the window between a
# command's pull and its push in which another clone's push lands (k322).

use App::karr::Git;

my $orig = \&App::karr::Git::push;
my $fired;

{
    no warnings 'redefine';
    *App::karr::Git::push = sub {
        if ( !$fired++ && defined $ENV{KARR_TEST_RACE} ) {
            system( 'sh', '-c', $ENV{KARR_TEST_RACE} ) == 0
                or die "RaceBeforePush: the racing command failed\n";
        }
        goto &$orig;
    };
}

1;
