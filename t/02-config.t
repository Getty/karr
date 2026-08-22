use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use Path::Tiny;
use YAML::XS qw( DumpFile );

use App::karr::Config;

subtest 'default config' => sub {
  my $config = App::karr::Config->default_config(name => 'Test Board');
  is $config->{board}{name}, 'Test Board';
  ok !exists $config->{next_id}, 'default config no longer persists next_id';
  ok scalar @{$config->{statuses}}, 'has statuses';
  ok scalar @{$config->{priorities}}, 'has priorities';
};

subtest 'statuses parsing' => sub {
  my $dir = tempdir(CLEANUP => 1);
  my $file = path($dir)->child('config.yml');
  DumpFile($file->stringify, App::karr::Config->default_config);

  my $config = App::karr::Config->new(file => $file);
  my @statuses = $config->statuses;
  ok scalar @statuses >= 5, 'at least 5 statuses';
  is $statuses[0], 'backlog';
  is $statuses[2], 'in-progress';
};

subtest 'effective config merges sparse overrides with defaults' => sub {
  my $effective = App::karr::Config->effective_config({
    version => 1,
    board => { name => 'Sparse Board' },
    defaults => { priority => 'high' },
  });

  is $effective->{board}{name}, 'Sparse Board', 'board name override applied';
  is $effective->{defaults}{priority}, 'high', 'nested override applied';
  is $effective->{defaults}{status}, 'backlog', 'missing nested value supplied by defaults';
  is $effective->{claim_timeout}, '1h', 'missing scalar supplied by defaults';
};

subtest 'default config has no wip limits' => sub {
  my $config = App::karr::Config->default_config;
  ok !exists $config->{wip_limits}, 'default config no longer defines wip limits';
  # The class level was the other half (#227): karr shipped wip_limit and
  # bypass_column_wip on the expedite class, validated them, and enforced them
  # nowhere. t/227 owns what that means for a board that still carries them.
  my @with_wip = grep { ref $_ eq 'HASH' && ( exists $_->{wip_limit} || exists $_->{bypass_column_wip} ) }
    @{ $config->{classes} };
  is scalar @with_wip, 0, 'no default class carries a wip limit either';
};

done_testing;
