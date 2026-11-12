# SPDX-License-Identifier: MIT
#
# Writes an environment whose packages are a manifest's dependencies,
# without the project's own packages.
#
# Usage: julia deps-env.jl <manifest> <environment directory>
#
# The project's own packages are the manifest entries with a `path`; they
# are left out, and every other entry becomes a direct dependency. The
# environment depends only on the manifest, so a depot built in it (with
# the dependencies' build scripts run and their caches precompiled) stays
# the same while the project's own sources change.
using Pkg, TOML

manifest_file, dir = ARGS
manifest = TOML.parsefile(manifest_file)

kept = Dict{String, Any}()
deps = Dict{String, String}()
for (name, entries) in manifest["deps"]
    others = [e for e in entries if !haskey(e, "path")]
    isempty(others) && continue
    kept[name] = others
    # A name with entries of several UUIDs can be a direct dependency once.
    deps[name] = others[1]["uuid"]
end
manifest["deps"] = kept

mkpath(dir)
open(io -> TOML.print(io, Dict("deps" => deps); sorted = true), joinpath(dir, "Project.toml"), "w")
open(io -> TOML.print(io, manifest; sorted = true), joinpath(dir, "Manifest.toml"), "w")

# The manifest's project hash is that of the original project; Pkg would
# warn that the project changed since the manifest was resolved.
env = Pkg.Types.EnvCache(joinpath(dir, "Project.toml"))
manifest["project_hash"] = string(Pkg.Types.workspace_resolve_hash(env))
open(io -> TOML.print(io, manifest; sorted = true), joinpath(dir, "Manifest.toml"), "w")
