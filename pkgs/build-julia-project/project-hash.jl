# SPDX-License-Identifier: MIT
#
# Sets the `project_hash` of a recorded test environment's manifest for the
# place the build put the environment in.
#
# Usage: julia project-hash.jl <environment directory>
#
# Pkg hashes the deps, compat and sources of a project, with a source path
# taken relative to the manifest after resolving links. The project root of
# a recorded environment lies in the Nix store in a build, so the lock run
# cannot know the hash and records the manifest without it. The lockfile
# itself records the hashes of the files it was made from, which is the
# check the project hash stands for.
using Pkg, TOML

dir = ARGS[1]
env = Pkg.Types.EnvCache(joinpath(dir, "Project.toml"))
manifest_file = joinpath(dir, "Manifest.toml")
manifest = TOML.parsefile(manifest_file)
manifest["project_hash"] = string(Pkg.Types.workspace_resolve_hash(env))
open(io -> TOML.print(io, manifest; sorted = true), manifest_file, "w")
