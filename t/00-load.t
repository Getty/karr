use strict;
use warnings;
use Test::More;

# App::karr::Foundation pulls its own submodules in, so they compile with it.
# App::karr::Foundation::ChainStore and ::Questions stay listed separately: the
# foundation loads both, but they are the two submodules with a life outside the
# foundation object -- a planner uses the chain store on its own, and anything
# that answers a question (a chat bridge, the coordination agent) uses the
# mailbox on its own -- so they are compiled on their own here.
my @modules = qw(
  App::karr
  App::karr::Task
  App::karr::Config
  App::karr::Error
  App::karr::BoardStore
  App::karr::CrossBoard
  App::karr::Role::BoardAccess
  App::karr::Role::Output
  App::karr::Role::CompactOutput
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
  App::karr::Cmd::Needs
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
  App::karr::Foundation::Questions
);

for my $mod (@modules) {
  use_ok($mod);
}

done_testing;
