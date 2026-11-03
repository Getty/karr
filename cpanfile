# Not used directly -- Git::Libgit2 loads the C library through it. Pinned so
# an install cannot land on libgit2 < 1.9.3, where the ssh transport loops
# forever against a peer that accepts the connection and then stays silent:
# libssh2 does its own reads and no libgit2 timeout option reaches that loop,
# so KARR_TRANSPORT_TIMEOUT cannot bound it either (#174, fixed upstream by
# libgit2 PR #7165). 0.002 raises the pkg-config floor to 1.9.3, so a
# distribution lib below the fix falls through to the bundled source build.
requires 'Alien::Libgit2', '0.002';
requires 'Carp';
requires 'Digest::MD5';
requires 'Encode';
requires 'Errno';
requires 'Exporter';
requires 'Fcntl';
requires 'File::ShareDir';
requires 'Git::Libgit2', '0.007';
requires 'Git::Native', '0.006';
requires 'IO::Handle';
requires 'IO::Select';
requires 'IPC::Open3';
requires 'JSON::MaybeXS';
# bin/karr resolves the command class from argv before MooX::Cmd dispatches
# (ticket #256), which is the runtime-plugin case use_module exists for.
requires 'Module::Runtime';
requires 'Moo';
requires 'MooX::Cmd';
requires 'MooX::Options';
requires 'Path::Tiny';
requires 'POSIX';
requires 'Scalar::Util';
requires 'Symbol';
requires 'Sys::Hostname';
requires 'Term::ANSIColor';
requires 'Time::HiRes';
requires 'Time::Piece';
requires 'Try::Tiny';
requires 'YAML::XS';

on test => sub {
    requires 'File::Temp';
    # t/124-source-ascii-only.t classifies every token in lib/ and bin/ so that
    # POD and comments stay exempt; a regex over lines cannot tell a `#` opening
    # a comment from one inside a string.
    requires 'PPI';
    requires 'Test::More';
};
