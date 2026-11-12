# SPDX-License-Identifier: MIT
#
# The packages of the `julia-purifier` scope: the command, and the builder
# (pkgs/build-julia-project/default.nix), which is a package for callPackage.
# The scope is `pkgs.julia-purifier`, so a package written for callPackage
# takes the builder as `{ julia-purifier }: julia-purifier.buildJuliaProject`.
{ callPackage, lib, ... }:
{
  julia-purifier = callPackage ./julia-purifier { };
  buildJuliaProject = callPackage ./build-julia-project/default.nix {
    inherit (lib) purifier;
  };
}
