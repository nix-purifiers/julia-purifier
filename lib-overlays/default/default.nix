# SPDX-License-Identifier: MIT
#
# The `julia-purifier` library namespace holds `readLock`, which reads the
# manifest and the lockfile of a project into the lock in memory of the
# purifier contract (lib-overlays/default/lock.nix). The builder needs a package set, so
# it is the package `buildJuliaProject` that the default package overlay
# adds.
{ ... }:
{

  overlay = final: prev: {
    julia-purifier = (prev.julia-purifier or { }) // {
      readLock = import ./lock.nix { lib = final; };
    };
  };

}
