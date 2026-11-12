# SPDX-License-Identifier: MIT
#
# What `julia-purifier prefetch` realizes for a project: the depot of the
# project's dependencies (with the test dependencies and the registries),
# the Julia the lock was made with, and the language server's environment,
# as `depot`, `julia` and `editor` links in one store path. The depot depends
# only on the manifest and the lockfile, so editing the project's own
# sources does not rebuild it. The command evaluates this file with the
# path of the project root and keeps the result alive with a GC root in the
# project.
{
  pkgs,
  src,
  # The lockfile, when it is not in `src`.
  lockFile ? src + "/julia-purifier.lock.json",
  # The Manifest.toml, when it is kept outside `src`.
  manifest ? null,
  # This flake's flake.lock, which pins the shared purifier library.
  flakeLock,
}:
let
  purifier = import ./purifier.nix {
    inherit (pkgs) lib;
    inherit flakeLock;
  };
  buildJuliaProject = pkgs.callPackage ./default.nix { inherit purifier; };
  project = buildJuliaProject { inherit src lockFile manifest; };
in
pkgs.runCommand "julia-purifier-prefetch" { } ''
  mkdir -p "$out"
  ln -s ${project.depot} "$out/depot"
  ln -s ${project.julia} "$out/julia"
  ln -s ${project.editor} "$out/editor"
''
