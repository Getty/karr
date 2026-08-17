use strict;
use warnings;
use Test::More;

# App::karr::Foundation pulls its own submodules in, so they compile with it.
# App::karr::Foundation::ChainStore stays listed separately: the runner loads it
# now (#186), but it is the one submodule with a life outside the foundation
# object -- a planner uses it on its own -- so it is compiled on its own here.
my @modules = qw(
  App::karr
  App::karr::Task
  App::karr::Config
  App::karr::Error
  App::karr::BoardStore
  App::karr::Role::BoardAccess
  App::karr::Role::Output
  App::karr::Role::DependencyArgs
  App::karr::Role::DependencyCheck
  App::karr::Cmd::Init
  App::karr::Cmd::Create
  App::karr::Cmd::List
  App::karr::Cmd::Show
  App::karr::Cmd::Move
  App::karr::Cmd::Edit
  App::karr::Cmd::Delete
  App::karr::Cmd::Board
  App::karr::Cmd::Pick
  App::karr::Cmd::Unlock
  App::karr::Cmd::Archive
  App::karr::Cmd::Handoff
  App::karr::Cmd::Destroy
  App::karr::Cmd::AgentName
  App::karr::Cmd::Config
  App::karr::Cmd::Context
  App::karr::Cmd::Backup
  App::karr::Cmd::Restore
  App::karr::Cmd::Skill
  App::karr::Cmd::Log
  App::karr::Cmd::SetRefs
  App::karr::Cmd::GetRefs
  App::karr::Foundation
  App::karr::Foundation::ChainStore
);

for my $mod (@modules) {
  use_ok($mod);
}

done_testing;
