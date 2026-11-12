# SPDX-License-Identifier: MIT
#
# `julia-purifier lock`: records every file Pkg downloads for a project, so
# that Nix can build the project offline in its sandbox.
#
# Usage: julia lock.jl [<project directory>] [--lockfile <path>]
#                      [--tool-lockfile <path>] [--update [<package>...]]
#
# With --tool-lockfile, the Manifest.toml is kept at that path, outside the
# project: the script reads and writes it there and leaves the manifest in
# the project as it is. When the file does not exist yet, the script starts
# from the manifest in the project.
#
# With --update, Pkg updates the named packages (or every package) first,
# as `julia-purifier update` asks; without it, the lock keeps the
# manifest's resolution as it is. The script runs with the network, in the fresh depot that DEPOT_PATH[1]
# names. It instantiates the project there, resolves each test environment
# Pkg would create for `Pkg.test`, and writes julia-purifier.lock.json beside
# the manifest. The manifest names each package by its UUID and git tree
# hash, and Nix reads it directly; the lockfile holds only what Nix needs
# beyond the manifest:
#
#   server      the package server the tarballs come from
#   packages    per tree hash of a package from the package server, the Nix
#               hash of its tarball
#   git         per tree hash of a package from a repository, the HTTPS URL,
#               the commit, the subdirectory and the Nix hash of the checkout
#   artifacts   per Nix system, per artifact tree hash, the URL, mirrors and
#               Nix hash of the artifact's tarball
#   registries  per registry UUID, the name, tree hash and Nix hash of the
#               registry tarball, which offline Pkg operations read
#   tests       per project with a test target, the Project.toml and
#               Manifest.toml of the environment Pkg.test runs in, which
#               Pkg resolves apart from the project's manifest
#   editor      the Project.toml and Manifest.toml of the language server's
#               environment
#   inputs      the SHA-256 of the manifest and each Project.toml, the files
#               the test and editor environments were resolved against, so
#               that a build notices a stale lockfile
module JuliaPurifierLock

using Pkg, TOML, SHA, Downloads, Base64
using Base: UUID, SHA1
using Base.BinaryPlatforms

# The package server Pkg downloads from: JULIA_PKG_SERVER when it is set, as
# Pkg itself reads it, and the public server otherwise. The public servers
# redirect to one storage server, which serves the same bytes, so that is a
# mirror of every public download.
const PUBLIC_SERVER = "https://pkg.julialang.org"
const SERVER = let s = get(ENV, "JULIA_PKG_SERVER", "")
    isempty(s) ? PUBLIC_SERVER : rstrip(occursin("://", s) ? s : "https://" * s, '/')
end
const STORAGE = "https://storage.julialang.net"
server_mirrors(path) = SERVER == PUBLIC_SERVER ? ["$STORAGE/$path"] : String[]

# The Nix systems the lock covers, as (arch, os, libc).
const SYSTEMS = [
    "x86_64-linux" => ("x86_64", "linux", "glibc"),
    "aarch64-linux" => ("aarch64", "linux", "glibc"),
    "aarch64-darwin" => ("aarch64", "macos", nothing),
]

# A recorded test environment names the project root by this path,
# relative to the environment's own directory. A build places the
# environment in a directory `env` and links `root` beside it to the
# project's source.
const ROOT = "../root"

sri(hex) = "sha256-" * base64encode(hex2bytes(hex))

function sha256_url(url)
    file = Downloads.download(url)
    try
        return bytes2hex(open(sha256, file))
    finally
        rm(file; force = true)
    end
end

# The platform of a Nix system, with the host's remaining tags (the Julia
# version, the libgfortran version and the C++ string ABI), which are the
# same for one Julia version on every system.
function platform_of(arch, os, libc)
    extra = Dict{Symbol, String}()
    for (k, v) in tags(HostPlatform())
        k in ("arch", "os", "libc", "call_abi", "os_version") && continue
        extra[Symbol(k)] = v
    end
    libc === nothing || (extra[:libc] = libc)
    return Platform(arch, os; extra...)
end

run_out(cmd) = strip(read(cmd, String))

# A git URL the sandbox can fetch: it has no SSH keys, so an SSH URL becomes
# the HTTPS URL of the same host and path, which is what most hosts serve.
function fetchable_url(url)
    m = match(r"^(?:ssh://)?git@([^:/]+)[:/](.+)$", url)
    m !== nothing && return "https://$(m[1])/$(m[2])"
    m = match(r"^ssh://(?:[^@/]+@)?([^/]+)/(.+)$", url)
    m !== nothing && return "https://$(m[1])/$(m[2])"
    if !occursin(r"^(https?|git)://", url)
        error("julia-purifier: the package repository $(repr(url)) is not a URL a Nix build can fetch")
    end
    return url
end

# The NAR hash of a directory, as nix-prefetch-git reports it for a
# checkout without .git.
nar_hash(dir) = run_out(`nix-hash --type sha256 --sri $dir`)

struct GitSource
    url::String
    commit::String
    hash::String
end

const CLONES = Dict{String, String}()

function clone(url, work)
    get!(CLONES, url) do
        dir = joinpath(work, "clones", bytes2hex(sha256(url)))
        if !isdir(dir)
            run(`git clone --quiet --no-checkout $url $dir`)
        end
        dir
    end
end

# The tree of a commit, or of a subdirectory in it.
function tree_of(dir, commit, subdir)
    spec = subdir === nothing ? "$commit^{tree}" : "$commit:$subdir"
    return try
        run_out(pipeline(`git -C $dir rev-parse --verify --quiet $spec`; stderr = devnull))
    catch
        ""
    end
end

# The commit whose tree (or whose `subdir`) is the package's tree. The
# manifest's revision is tried first; otherwise every commit is.
function find_commit(dir, tree, rev, subdir)
    candidates = String[]
    if rev !== nothing
        spec = "$rev^{commit}"
        c = try
            run_out(pipeline(`git -C $dir rev-parse --verify --quiet $spec`; stderr = devnull))
        catch
            ""
        end
        isempty(c) || push!(candidates, c)
    end
    for c in candidates
        tree_of(dir, c, subdir) == tree && return c
    end
    if subdir === nothing
        for line in eachline(`git -C $dir log --all --format=%H\ %T`)
            c, t = split(line)
            t == tree && return String(c)
        end
    else
        for c in eachline(`git -C $dir rev-list --all`)
            tree_of(dir, c, subdir) == tree && return c
        end
    end
    error("julia-purifier: no commit of $(dir) has the tree $(tree)$(subdir === nothing ? "" : " in $subdir")")
end

const CHECKOUTS = Dict{Tuple{String, String}, GitSource}()

function git_source(url, tree, rev, subdir, work)
    fetch_url = fetchable_url(url)
    dir = clone(url, work)
    commit = find_commit(dir, tree, rev, subdir)
    get!(CHECKOUTS, (fetch_url, commit)) do
        checkout = joinpath(work, "checkouts", commit)
        if !isdir(checkout)
            run(`git -C $dir worktree add --quiet --detach $checkout $commit`)
        end
        # The hash is that of the checkout without .git, which is what
        # nixpkgs' fetchgit produces with leaveDotGit off.
        copy = joinpath(work, "hashed", commit)
        rm(copy; recursive = true, force = true)
        mkpath(dirname(copy))
        cp(checkout, copy)
        rm(joinpath(copy, ".git"); recursive = true, force = true)
        GitSource(fetch_url, commit, nar_hash(copy))
    end
end

# The repository and subdirectory a registry names for a package, for
# packages the package server does not serve (those of other registries).
function registry_repo(uuid)
    for reg in Pkg.Registry.reachable_registries()
        haskey(reg, uuid) || continue
        info = Pkg.Registry.registry_info(reg[uuid])
        info.repo === nothing && continue
        return (info.repo, info.subdir)
    end
    return nothing
end

server_has(url) = try
    Downloads.request(url; method = "HEAD", throw = false).status == 200
catch
    false
end

# One package of a manifest: its name, UUID, tree hash and git origin.
struct Package
    name::String
    uuid::UUID
    tree::String
    repo::Union{Nothing, String}
    rev::Union{Nothing, String}
    subdir::Union{Nothing, String}
end

# The packages of a parsed manifest (format 2) that come from elsewhere:
# those with a tree hash. Packages with a path are part of the source, and
# standard libraries come with Julia.
function packages_of(manifest::Dict)
    out = Package[]
    for (name, entries) in get(manifest, "deps", Dict())
        for e in entries
            haskey(e, "git-tree-sha1") || continue
            haskey(e, "path") && continue
            push!(
                out, Package(
                    name, UUID(e["uuid"]), e["git-tree-sha1"],
                    get(e, "repo-url", nothing), get(e, "repo-rev", nothing),
                    get(e, "repo-subdir", nothing),
                )
            )
        end
    end
    return out
end

struct Captured <: Exception end

# The environment Pkg.test runs a project's tests in. Pkg calls `test_fn`
# inside its sandbox, with the sandbox's project active; the function copies
# the project and manifest and stops before the tests run.
function test_environment(project_dir)
    captured = Dict{String, String}()
    capture = function ()
        proj = Base.active_project()
        captured["Project.toml"] = read(proj, String)
        captured["Manifest.toml"] = read(Base.project_file_manifest_path(proj), String)
        throw(Captured())
    end
    Pkg.activate(project_dir; io = devnull)
    try
        Pkg.test(; test_fn = capture)
    catch e
        isempty(captured) && rethrow()
    end
    return captured
end

has_test_target(project) =
    haskey(get(project, "targets", Dict()), "test") ||
    isfile(joinpath(project["__dir"], "test", "Project.toml"))

function read_project(dir)
    p = TOML.parsefile(joinpath(dir, "Project.toml"))
    p["__dir"] = dir
    return p
end

relpath_or_dot(path, root) = (r = relpath(path, root); r == "." ? "." : r)

const LOCKFILE = "julia-purifier.lock.json"
const FORMAT = 2

# JSON, written with sorted keys and two-space indentation. Julia's
# standard library has no JSON module, and the lockfile needs only
# strings, integers, booleans, null, arrays and objects.
function json_string(io, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\r'
            print(io, "\\r")
        elseif c < ' '
            print(io, "\\u", string(UInt16(c); base = 16, pad = 4))
        else
            print(io, c)
        end
    end
    print(io, '"')
end

function json(io, x, indent, keyorder = nothing)
    pad = "  "^indent
    if x === nothing
        print(io, "null")
    elseif x isa Bool
        print(io, x ? "true" : "false")
    elseif x isa Integer
        print(io, x)
    elseif x isa AbstractString
        json_string(io, x)
    elseif x isa AbstractVector
        if isempty(x)
            print(io, "[]")
        else
            println(io, "[")
            for (i, v) in enumerate(x)
                print(io, pad, "  ")
                json(io, v, indent + 1)
                println(io, i < length(x) ? "," : "")
            end
            print(io, pad, "]")
        end
    elseif x isa AbstractDict
        if isempty(x)
            print(io, "{}")
        else
            keys_ = keyorder === nothing ? sort(collect(keys(x))) : keyorder
            println(io, "{")
            for (i, k) in enumerate(keys_)
                print(io, pad, "  ")
                json_string(io, k)
                print(io, ": ")
                json(io, x[k], indent + 1)
                println(io, i < length(keys_) ? "," : "")
            end
            print(io, pad, "}")
        end
    else
        error("julia-purifier: cannot write $(typeof(x)) as JSON")
    end
end

# The lockfile's text. It starts with the format `version` and the `hash`
# of its own content: the SHA-256 of the text with the hash's value empty.
# lib-overlays/default/lock.nix checks that hash before it parses the file, so an edited,
# truncated or malformed lockfile fails with a message to relock.
function lock_text(lock)
    order = vcat(["version", "hash"], sort([k for k in keys(lock) if k ∉ ("version", "hash")]))
    io = IOBuffer()
    json(io, merge(lock, Dict("hash" => "")), 0, order)
    println(io)
    blank = String(take!(io))
    hash = sri(bytes2hex(sha256(blank)))
    return replace(blank, "\"hash\": \"\"" => "\"hash\": \"$hash\""; count = 1)
end

# The content of a lockfile whose content hash holds, or nothing.
function read_lock(path)
    isfile(path) || return nothing
    text = read(path, String)
    m = match(r"\"hash\": \"(sha256-[A-Za-z0-9+/=]+)\"", text)
    m === nothing && return nothing
    blank = replace(text, "\"hash\": \"$(m[1])\"" => "\"hash\": \"\""; count = 1)
    sri(bytes2hex(sha256(blank))) == m[1] || return nothing
    lock = parse_json(text)
    get(lock, "version", nothing) == FORMAT || return nothing
    return lock
end

# A reader for the JSON that `json` writes.
function parse_json(text::String)
    pos = Ref(1)
    skip() = (while pos[] <= ncodeunits(text) && text[pos[]] in (' ', '\n', '\r', '\t'); pos[] = nextind(text, pos[]); end)
    function value()
        skip()
        c = text[pos[]]
        if c == '{'
            pos[] += 1
            d = Dict{String, Any}()
            skip()
            if text[pos[]] == '}'
                pos[] += 1
                return d
            end
            while true
                skip()
                k = value()
                skip()
                text[pos[]] == ':' || error("julia-purifier: malformed JSON at byte $(pos[])")
                pos[] += 1
                d[k] = value()
                skip()
                if text[pos[]] == ','
                    pos[] += 1
                elseif text[pos[]] == '}'
                    pos[] += 1
                    return d
                else
                    error("julia-purifier: malformed JSON at byte $(pos[])")
                end
            end
        elseif c == '['
            pos[] += 1
            a = Any[]
            skip()
            if text[pos[]] == ']'
                pos[] += 1
                return a
            end
            while true
                push!(a, value())
                skip()
                if text[pos[]] == ','
                    pos[] += 1
                elseif text[pos[]] == ']'
                    pos[] += 1
                    return a
                else
                    error("julia-purifier: malformed JSON at byte $(pos[])")
                end
            end
        elseif c == '"'
            io = IOBuffer()
            i = pos[] + 1
            while true
                ch = text[i]
                if ch == '"'
                    pos[] = i + 1
                    return String(take!(io))
                elseif ch == '\\'
                    e = text[i + 1]
                    if e == 'u'
                        write(io, Char(parse(UInt16, text[(i + 2):(i + 5)]; base = 16)))
                        i += 6
                    else
                        write(io, Dict('n' => '\n', 't' => '\t', 'r' => '\r', '"' => '"', '\\' => '\\', '/' => '/', 'b' => '\b', 'f' => '\f')[e])
                        i += 2
                    end
                else
                    write(io, ch)
                    i = nextind(text, i)
                end
            end
        elseif startswith(SubString(text, pos[]), "true")
            pos[] += 4
            return true
        elseif startswith(SubString(text, pos[]), "false")
            pos[] += 5
            return false
        elseif startswith(SubString(text, pos[]), "null")
            pos[] += 4
            return nothing
        else
            m = match(r"-?[0-9]+", text, pos[])
            (m === nothing || m.offset != pos[]) && error("julia-purifier: malformed JSON at byte $(pos[])")
            pos[] += length(m.match)
            return parse(Int, m.match)
        end
    end
    return value()
end

# Installs a recorded environment (a test environment or the editor
# environment) in the lock's depot, so that its packages can be hashed and
# their artifacts selected. A recorded test environment names the project
# as ../root, beside its own directory.
function instantiate_recorded(env, root)
    dir = mktempdir()
    symlink(root, joinpath(dir, "root"))
    envdir = joinpath(dir, "env")
    mkpath(envdir)
    write(joinpath(envdir, "Project.toml"), env["Project.toml"])
    write(joinpath(envdir, "Manifest.toml"), env["Manifest.toml"])
    Pkg.activate(envdir; io = devnull)
    Pkg.instantiate()
    return
end

# The environment of LanguageServer.jl, the language server that the Julia
# editor plugins start.
function editor_environment()
    dir = mktempdir()
    Pkg.activate(dir; io = devnull)
    Pkg.add("LanguageServer")
    manifest = read(joinpath(dir, "Manifest.toml"), String)
    return Dict(
        "Project.toml" => read(joinpath(dir, "Project.toml"), String),
        "Manifest.toml" => replace(manifest, r"^project_hash = .*\n"m => ""),
    )
end

# The registries in the lock's depot, by UUID: the name of each, its tree
# hash and the hash of its tarball from the package server. The lock's
# depot is fresh, so Pkg installs only the registries the package server
# serves.
function registry_entries()
    dir = joinpath(DEPOT_PATH[1], "registries")
    entries = Dict{String, Any}()
    for f in sort(readdir(dir))
        full = joinpath(dir, f)
        if endswith(f, ".toml")
            pointer = TOML.parsefile(full)
            haskey(pointer, "path") || continue
            # The package server sends a registry compressed as the client
            # asks: zstd to Pkg, gzip to a plain request such as the one Nix
            # makes. The lock records the hash of the gzip tarball, which
            # Pkg reads by its extension.
            url = "$SERVER/registry/$(pointer["uuid"])/$(pointer["git-tree-sha1"])"
            file = Downloads.download(url)
            magic = open(io -> read(io, 2), file)
            magic == UInt8[0x1f, 0x8b] || error("julia-purifier: $(url) did not come gzip-compressed to a plain request")
            entries[pointer["uuid"]] = Dict(
                "name" => f[1:(end - 5)],
                "tree" => pointer["git-tree-sha1"],
                "hash" => sri(bytes2hex(open(sha256, file))),
            )
            rm(file)
        elseif isdir(full)
            error("julia-purifier: Pkg installed the registry $(f) as a git clone; the lock takes registries from a package server only")
        end
    end
    return entries
end

function main(project_arg, lockfile_arg = nothing, update = nothing)
    root = abspath(project_arg)
    work = mktempdir()
    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"

    Pkg.activate(root; io = devnull)
    ctx = Pkg.Types.Context()
    manifest_file = ctx.env.manifest_file
    # Julia packages often keep no manifest in version control. The lock
    # needs one, so it resolves the project and writes it.
    if !isfile(manifest_file)
        @info "julia-purifier: $(root) has no manifest; resolving the project to write $(basename(manifest_file))"
        # The lock's depot is fresh, and Pkg.resolve, unlike
        # Pkg.instantiate, does not install the default registries.
        Pkg.Registry.add()
        Pkg.resolve()
        ctx = Pkg.Types.Context()
        manifest_file = ctx.env.manifest_file
    end
    # `julia-purifier update` resolves the project again, for every package
    # or for the named ones, before the lock records the result.
    if update !== nothing
        @info "julia-purifier: updating $(isempty(update) ? "every package" : join(update, ", "))"
        Pkg.Registry.add()
        isempty(update) ? Pkg.update() : Pkg.update(update)
    end
    root = dirname(manifest_file)
    manifest = TOML.parsefile(manifest_file)

    jv = VersionNumber(get(manifest, "julia_version", string(VERSION)))
    if (jv.major, jv.minor) != (VERSION.major, VERSION.minor)
        error("julia-purifier: the manifest is for Julia $(jv); run the lock with Julia $(jv.major).$(jv.minor)")
    end

    # The projects of the environment: the root and, in a workspace, its
    # members.
    project_dirs = [root]
    for p in get(get(TOML.parsefile(joinpath(root, "Project.toml")), "workspace", Dict()), "projects", String[])
        push!(project_dirs, normpath(joinpath(root, p)))
    end
    workspace_dirs = Set(project_dirs)

    out = lockfile_arg === nothing ? joinpath(root, LOCKFILE) : abspath(lockfile_arg)

    inputs = Dict{String, String}()
    for f in [manifest_file; [joinpath(d, "Project.toml") for d in project_dirs]]
        isfile(f) && (inputs[relpath(f, root)] = bytes2hex(open(sha256, f)))
    end

    # A relock of an unchanged project keeps what was resolved against the
    # registry: the test environments, the editor environment and the
    # registry snapshot. Resolving them again would pick up versions
    # released since, so the lockfile would change although the project
    # did not.
    previous = read_lock(out)
    reuse = previous !== nothing && get(previous, "inputs", nothing) == inputs
    reuse && @info "julia-purifier: the project is unchanged since $(out); keeping its resolved environments"

    # Pkg instantiates what the active project reaches, so each project of
    # a workspace is instantiated on its own.
    for dir in project_dirs
        @info "julia-purifier: instantiating $(dir)"
        Pkg.activate(dir; io = devnull)
        Pkg.instantiate()
    end

    # Each package with a test target whose tests run in a sandbox, rather
    # than in a test project of the workspace.
    tests = Dict{String, Any}()
    packages = packages_of(manifest)
    for dir in project_dirs
        project = read_project(dir)
        haskey(project, "uuid") || continue
        has_test_target(project) || continue
        normpath(joinpath(dir, "test")) in workspace_dirs && continue
        key = relpath_or_dot(dir, root)
        if reuse && haskey(previous["tests"], key)
            env = previous["tests"][key]
            instantiate_recorded(env, root)
        else
            @info "julia-purifier: resolving the test environment of $(project["name"])"
            env = test_environment(dir)
            for (k, v) in env
                env[k] = replace(v, root => ROOT)
            end
            # The manifest's project hash depends on where the project lies,
            # so the build computes it (pkgs/build-julia-project/project-hash.jl) and the
            # lock leaves it out.
            env["Manifest.toml"] = replace(env["Manifest.toml"], r"^project_hash = .*\n"m => "")
        end
        tests[key] = env
        append!(packages, packages_of(TOML.parse(env["Manifest.toml"])))
    end

    # The environment of the language server that editors start, so that
    # `julia-purifier prefetch` can provide it offline.
    editor = if reuse && haskey(previous, "editor")
        instantiate_recorded(previous["editor"], root)
        previous["editor"]
    else
        @info "julia-purifier: resolving the editor environment (LanguageServer.jl)"
        editor_environment()
    end
    append!(packages, packages_of(TOML.parse(editor["Manifest.toml"])))

    # The registries Pkg resolved with, which `Pkg.test` and `Pkg.add` read
    # offline.
    registries = if reuse && haskey(previous, "registries")
        previous["registries"]
    else
        registry_entries()
    end
    Pkg.activate(root; io = devnull)

    # The manifests name every package by its tree hash, with its UUID and,
    # for a package added from a repository, the repository and the
    # subdirectory. The lock adds what Nix needs beyond that: the hash of
    # each package tarball from the package server, the commit and hash of
    # each checkout, and the artifacts.
    server_packages = Dict{String, String}()
    git = Dict{String, Any}()
    artifacts = Dict(system => Dict{String, Any}() for (system, _) in SYSTEMS)
    seen = Set{String}()

    for pkg in packages
        pkg.tree in seen && continue
        push!(seen, pkg.tree)
        tree = SHA1(pkg.tree)
        installed = Pkg.Operations.find_installed(pkg.name, pkg.uuid, tree)
        isdir(installed) || error("julia-purifier: Pkg did not install $(pkg.name) at $(installed)")

        url = "$SERVER/package/$(pkg.uuid)/$(pkg.tree)"
        repo = pkg.repo
        subdir = pkg.subdir
        if repo === nothing && !server_has(url)
            r = registry_repo(pkg.uuid)
            r === nothing && error("julia-purifier: neither the package server nor a registry has $(pkg.name) at $(pkg.tree)")
            repo, subdir = r
        end
        if repo === nothing
            @info "julia-purifier: hashing $(pkg.name)"
            server_packages[pkg.tree] = sri(sha256_url(url))
        else
            @info "julia-purifier: locating $(pkg.name) in $(repo)"
            src = git_source(repo, pkg.tree, pkg.rev, subdir, work)
            git[pkg.tree] = Dict("url" => src.url, "rev" => src.commit, "subdir" => subdir, "hash" => src.hash)
        end

        for (system, (arch, os, libc)) in SYSTEMS
            platform = platform_of(arch, os, libc)
            for (_, selected) in Pkg.Operations.collect_artifacts(installed; platform, include_lazy = true)
                for (name, meta) in selected
                    art_tree = meta["git-tree-sha1"]
                    haskey(artifacts[system], art_tree) && continue
                    dls = get(meta, "download", Any[])
                    artifacts[system][art_tree] = if isempty(dls)
                        a_url = "$SERVER/artifact/$(art_tree)"
                        Dict("url" => a_url, "mirrors" => server_mirrors("artifact/$(art_tree)"), "hash" => sri(sha256_url(a_url)))
                    else
                        first_dl = dls[1]
                        mirrors = [d["url"] for d in dls[2:end] if d["sha256"] == first_dl["sha256"]]
                        Dict("url" => first_dl["url"], "mirrors" => mirrors, "hash" => sri(first_dl["sha256"]))
                    end
                end
            end
        end
    end

    # The artifacts Pkg installed on this host are the ones the lock
    # recorded for it; a package whose artifact selection differs (through a
    # platform augmentation hook) would show up here.
    host = [s for (s, (arch, os, _)) in SYSTEMS if arch == string(Sys.ARCH) && os == (Sys.isapple() ? "macos" : "linux")]
    installed_artifacts = joinpath(DEPOT_PATH[1], "artifacts")
    if !isempty(host) && isdir(installed_artifacts)
        for t in readdir(installed_artifacts)
            occursin(r"^[0-9a-f]{40}$", t) || continue
            haskey(artifacts[host[1]], t) ||
                error("julia-purifier: Pkg installed the artifact $t, which the lock did not select for $(host[1])")
        end
    end

    lock = Dict(
        "version" => FORMAT,
        "server" => SERVER,
        "inputs" => inputs,
        "packages" => server_packages,
        "git" => git,
        "artifacts" => artifacts,
        "tests" => tests,
        "editor" => editor,
        "registries" => registries,
    )
    write(out, lock_text(lock))
    @info "julia-purifier: wrote $(out)"
    return
end

# The Manifest.toml of a project directory: the one that Pkg reads, which is
# Manifest-v<major>.<minor>.toml when that file exists.
function manifest_path(dir)
    versioned = joinpath(dir, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
    return isfile(versioned) ? versioned : joinpath(dir, "Manifest.toml")
end

# Runs `f` with the Manifest.toml kept at `tool_lockfile`, outside the
# project. Pkg resolves in place, so the outside copy takes the place of the
# manifest in the tree while `f` runs, and the result is written back to the
# outside copy. The manifest of the tree is the same afterwards. When the
# outside copy does not exist yet, `f` starts from the manifest of the tree.
function with_tool_lockfile(f, dir, tool_lockfile)
    tool_lockfile === nothing && return f()
    outside = abspath(tool_lockfile)
    inside = manifest_path(abspath(dir))
    original = isfile(inside) ? read(inside) : nothing
    isfile(outside) && cp(outside, inside; force = true)
    try
        f()
        mkpath(dirname(outside))
        isfile(inside) && cp(inside, outside; force = true)
    finally
        if original === nothing
            rm(inside; force = true)
        else
            write(inside, original)
        end
    end
    return
end

end

# tests/lock-unit.jl includes this file for its functions; run as a
# program, it locks the project.
if abspath(PROGRAM_FILE) == @__FILE__
    # Usage: julia lock.jl [<project directory>] [--lockfile <path>]
    #                      [--tool-lockfile <path>] [--update [<package>...]]
    let args = copy(ARGS), lockfile = nothing, tool_lockfile = nothing, update = nothing
        u = findfirst(==("--update"), args)
        if u !== nothing
            update = args[(u + 1):end]
            args = args[1:(u - 1)]
        end
        i = findfirst(==("--lockfile"), args)
        if i !== nothing
            lockfile = args[i + 1]
            deleteat!(args, i:(i + 1))
        end
        t = findfirst(==("--tool-lockfile"), args)
        if t !== nothing
            tool_lockfile = args[t + 1]
            deleteat!(args, t:(t + 1))
        end
        project = isempty(args) ? "." : args[1]
        JuliaPurifierLock.with_tool_lockfile(project, tool_lockfile) do
            JuliaPurifierLock.main(project, lockfile, update)
        end
    end
end
