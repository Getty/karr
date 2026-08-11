use strict;
use warnings;
use Test::More;

my $dockerfile = 'Dockerfile';
ok( -f $dockerfile, 'Dockerfile exists' ) or BAIL_OUT('Dockerfile missing');

open my $fh, '<', $dockerfile or BAIL_OUT("Could not open $dockerfile: $!");
my $content = do { local $/; <$fh> };
close $fh;

like( $content, qr/AS runtime-root\b/, 'Dockerfile defines a runtime-root target' );
like( $content, qr/AS runtime-user\b/, 'Dockerfile defines a runtime-user target' );
like(
    $content,
    qr/COPY docker\/karr-entrypoint\.sh \/usr\/local\/bin\/karr-entrypoint\.sh/,
    'runtime image copies the ownership-adjusting entrypoint',
);
like(
    $content,
    qr/ENTRYPOINT \["karr-entrypoint\.sh"\]/,
    'root runtime uses the dynamic karr entrypoint',
);
like(
    $content,
    qr/\bUSER karr\b/,
    'user runtime ends as the fixed non-root karr user',
);
like(
    $content,
    qr/\bARG KARR_UID="?1000"?/,
    'Dockerfile exposes a default build-time KARR_UID argument',
);
like(
    $content,
    qr/\bARG KARR_GID="?1000"?/,
    'Dockerfile exposes a default build-time KARR_GID argument',
);

# runtime-user's `useradd -m -d /home/karr ...` creates that home directory
# itself. If runtime-base's mkdir also creates it first, useradd finds it
# already there and, instead of making it, prints:
#   useradd: warning: the home directory /home/karr already exists.
#   useradd: Not copying any file from skel directory into it.
# and silently skips the /etc/skel copy on every image build. Isolate each
# stage's body (a plain `/home/karr` grep would false-positive on the
# `ENV HOME=/home/karr` and `-d /home/karr` lines that legitimately live
# elsewhere in the file) so the checks below can't be fooled by those, and
# strip comment lines out of each stage body too — the invariant is about
# what the stage *does*, not about prose that happens to mention mkdir or
# /home/karr while explaining why it doesn't.
my ($runtime_base_stage) = $content =~ /^FROM\s+\S+\s+AS\s+runtime-base\b(.*?)(?=^FROM\s|\z)/ms;
ok( $runtime_base_stage, 'found the runtime-base stage body' )
    or BAIL_OUT('could not isolate the runtime-base stage to check its mkdir');
$runtime_base_stage = join "\n", grep { !/^\s*#/ } split /\n/, $runtime_base_stage;

like(
    $runtime_base_stage,
    qr/^RUN mkdir -p .*\/work/m,
    'runtime-base still creates /work',
);
unlike(
    $runtime_base_stage,
    qr/mkdir[^\n]*\/home\/karr/,
    'runtime-base must not pre-create /home/karr (would make useradd -m warn and skip /etc/skel)',
);

my ($runtime_user_stage) = $content =~ /^FROM\s+\S+\s+AS\s+runtime-user\b(.*?)(?=^FROM\s|\z)/ms;
ok( $runtime_user_stage, 'found the runtime-user stage body' )
    or BAIL_OUT('could not isolate the runtime-user stage to check its useradd');
$runtime_user_stage = join "\n", grep { !/^\s*#/ } split /\n/, $runtime_user_stage;

like(
    $runtime_user_stage,
    qr/useradd\s+-m\b/,
    'runtime-user keeps useradd -m so it actually creates and populates /home/karr',
);

done_testing;
