#!/usr/bin/env perl
# Writes the demo chain into the fleet hub (ex/fleet-hub) — the sandbox
# counterpart of the Perl snippet in the article's chain section.
#
# Usage: perl -Ilib ex/scripts/write-chain.pl [HUB-DIR]
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use App::karr::Git;
use App::karr::Foundation::ChainStore;

my $hub = shift || "$FindBin::Bin/../fleet-hub";

my $store = App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => $hub ),
);

$store->write_chain(
    [
        { id => 'docs',  kind => 'shell', repo => "$FindBin::Bin/../docs-site",
          command => "$FindBin::Bin/build-docs.sh", precheck => 'board_actionable == yes' },
        { id => 'smoke', kind => 'shell', repo => "$FindBin::Bin/../webapp",
          command => "$FindBin::Bin/smoke-test.sh" },
        { id => 'registry', kind => 'question', needs => [ 'docs', 'smoke' ] },
        { id => 'publish', kind => 'shell', repo => "$FindBin::Bin/../webapp",
          needs => [ 'registry' ], command => "$FindBin::Bin/publish.sh" },
    ],
    limits => { concurrent => 2 },
    note   => 'demo release 0.6',
);

print "chain written into $hub\n";
