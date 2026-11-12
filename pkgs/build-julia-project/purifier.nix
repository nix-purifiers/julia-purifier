# SPDX-License-Identifier: MIT
#
# The `purifier` namespace of the shared purifier library, at the revision
# that this flake's flake.lock pins. The julia-purifier command builds
# through its own evaluations (prefetch and publish), which do not have the
# flake's inputs; they fetch the library from the lock entry, so they use
# the same revision as the flake, and import its root default.nix.
{ lib, flakeLock }:
let
  locked = (builtins.fromJSON (builtins.readFile flakeLock)).nodes.purifier.locked;
in
import (builtins.fetchTree locked) { inherit lib; }
