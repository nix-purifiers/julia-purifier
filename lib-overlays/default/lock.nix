# SPDX-License-Identifier: MIT
#
# lib.julia-purifier.readLock: reads a project's manifest, its
# julia-purifier.lock.json and its Project.toml files at evaluation time,
# into the lock in memory that the purifier contract describes:
#
#   purifier  "julia-purifier"
#   entries   the package sources, the registries and the artifacts, as
#             download entries of the shared purifier library. An artifact
#             entry carries `systems`, the one Nix system it is for
#   outputs   the projects that are packages (with a name and a UUID), by
#             package name: the parsed Project.toml and `dir`, the
#             project's directory in `src`
#   problems  why the lockfiles cannot be used, each naming the command
#             that fixes it
#
# The manifest names every package by its UUID and git tree hash; the
# lockfile adds what Nix needs beyond that, by tree hash (see src/lock.jl).
# This file joins the two. The builder also reads `julia`:
#
#   placements  per package of the manifest, of a recorded test environment
#               and of the editor environment: its name, UUID and tree
#               hash, the download path of its source, and whether the
#               project's manifest pins it. pkgs/build-julia-project/place.jl puts each
#               source at the depot path Julia looks for it at
#   tests       per project directory with a test target that Pkg tests in
#               a sandbox, the recorded Project.toml and Manifest.toml text
#   editor      the recorded Project.toml and Manifest.toml text of the
#               language server's environment
#   systems     the Nix systems the lockfile records artifacts for
#   version     the Julia version the manifest records
#   manifest    the manifest file, and `manifestName`, its name
#   projects    per project directory ("." for the root, then the members
#               of a workspace), the parsed Project.toml and `dir`
#
# A problem is recorded when
#
#   - the lockfile or the manifest does not exist
#   - the lockfile's text does not match the hash of its own content: it was
#     edited, truncated or is not JSON at all
#   - its format is not the one this julia-purifier reads
#   - a file the lock was made from has changed since (the lock is stale)
#   - the manifest, a recorded test environment or the editor environment
#     pins a package tree the lockfile has no hash for
#
# Each check runs only when the ones before it pass, and `entries` is empty
# while there is a problem, so reading the lock never throws.
{ lib }:
{
  src,
  lockFile ? src + "/julia-purifier.lock.json",
  # The manifest, when it is not in `src`: Julia packages often keep their
  # Manifest.toml out of version control, beside the lockfile.
  manifest ? null,
}:
let
  relock = "run `julia-purifier lock` in the project to renew it";
  format = 2;
  name = toString lockFile;

  exists = builtins.pathExists lockFile;
  text = builtins.readFile lockFile;

  # The lockfile's third line holds the hash of its own content: the SHA-256
  # of the text with that hash's value empty. It is checked before the text
  # is parsed, so a damaged file is a problem rather than an error of the
  # JSON parser.
  hashLine = builtins.elemAt (
    lib.splitString "\n" text
    ++ [
      ""
      ""
      ""
    ]
  ) 2;
  recorded = builtins.match "  \"hash\": \"(sha256-[A-Za-z0-9+/=]+)\"," hashLine;
  intact =
    recorded != null
    &&
      builtins.convertHash {
        hash = builtins.hashString "sha256" (
          builtins.replaceStrings [ ''"hash": "${builtins.head recorded}"'' ] [ ''"hash": ""'' ] text
        );
        hashAlgo = "sha256";
        toHashFormat = "sri";
      } == builtins.head recorded;

  # Nix cannot catch a parse error, so one that gets past the content hash
  # check fails evaluation with a message that names the command.
  parsed = builtins.addErrorContext "while parsing ${name}; ${relock}" (builtins.fromJSON text);

  manifestName = builtins.head (
    builtins.filter (lib.hasPrefix "Manifest") (builtins.attrNames (parsed.inputs or { }))
    ++ [ "Manifest.toml" ]
  );
  manifestPath = if manifest != null then manifest else src + "/${manifestName}";

  # The path of a file the lock was made from.
  inputPath = f: if f == manifestName then manifestPath else src + "/${f}";
  stale = builtins.filter (
    f:
    !builtins.pathExists (inputPath f) || builtins.hashFile "sha256" (inputPath f) != parsed.inputs.${f}
  ) (builtins.attrNames parsed.inputs);

  projectManifest = builtins.addErrorContext "while parsing ${toString manifestPath}; ${relock}" (
    builtins.fromTOML (builtins.readFile manifestPath)
  );

  # The packages a manifest pins by tree hash. Packages with a path are part
  # of the source, and standard libraries come with Julia.
  pinned =
    main: m:
    lib.concatLists (
      lib.mapAttrsToList (
        name: entries:
        map (e: {
          inherit name main;
          inherit (e) uuid;
          tree = e."git-tree-sha1";
        }) (builtins.filter (e: e ? "git-tree-sha1" && !(e ? path)) entries)
      ) (m.deps or { })
    );

  allPinned =
    pinned true projectManifest
    ++ lib.concatMap (t: pinned false (builtins.fromTOML t."Manifest.toml")) (
      builtins.attrValues parsed.tests
    )
    ++ pinned false (builtins.fromTOML parsed.editor."Manifest.toml");

  # Every pinned tree needs a hash in the lockfile.
  unhashed = lib.unique (
    map (p: p.name) (
      builtins.filter (p: !(parsed.packages ? ${p.tree} || parsed.git ? ${p.tree})) allPinned
    )
  );

  problem =
    if !exists then
      "julia-purifier: ${name} does not exist; run `julia-purifier lock` in the project."
    else if !intact then
      "julia-purifier: ${name} does not match the hash of its own content: it was edited, truncated or is not a julia-purifier lockfile; ${relock}."
    else if parsed.version or null != format then
      "julia-purifier: ${name} has format ${
        toString (parsed.version or "?")
      }; this julia-purifier reads format ${toString format}, so ${relock}."
    else if stale != [ ] then
      "julia-purifier: ${lib.concatStringsSep ", " stale} changed since ${name} was made; ${relock}."
    else if !builtins.pathExists manifestPath then
      "julia-purifier: ${toString manifestPath} does not exist; ${relock}."
    else if unhashed != [ ] then
      "julia-purifier: ${name} has no hash for ${lib.concatStringsSep ", " unhashed}, which the project pins; ${relock}."
    else
      null;

  # The public package server redirects to one storage server, which serves
  # the same bytes, so that is a mirror of every public download.
  serverMirrors =
    path:
    lib.optional (parsed.server == "https://pkg.julialang.org") "https://storage.julialang.net/${path}";

  # The source of a pinned package in the download tree: a tarball from the
  # package server at trees/<tree>, or a directory of a checkout at
  # git/<commit>.
  sourceOf =
    p:
    if parsed.packages ? ${p.tree} then
      "trees/${p.tree}"
    else
      let
        g = parsed.git.${p.tree};
      in
      "git/${g.rev}${lib.optionalString (g.subdir != null) "/${g.subdir}"}";

  uuidOf = lib.listToAttrs (map (p: lib.nameValuePair p.tree p.uuid) allPinned);

  packageEntries = lib.mapAttrsToList (tree: hash: {
    path = "trees/${tree}";
    archive = {
      url = "${parsed.server}/package/${uuidOf.${tree}}/${tree}";
      mirrors = serverMirrors "package/${uuidOf.${tree}}/${tree}";
      stripTop = false;
    };
    inherit hash;
  }) (lib.filterAttrs (tree: _: uuidOf ? ${tree}) parsed.packages);

  # One checkout per commit, which several packages in subdirectories of
  # one repository can share.
  gitEntries = lib.attrValues (
    lib.listToAttrs (
      map (
        g:
        lib.nameValuePair g.rev {
          path = "git/${g.rev}";
          git = {
            inherit (g) url rev;
            submodules = false;
            leaveDotGit = false;
            commitObject = null;
          };
          inherit (g) hash;
        }
      ) (builtins.attrValues parsed.git)
    )
  );

  # An artifact tree can be the same on several systems; the entry then
  # lists each of them.
  artifactEntries =
    lib.mapAttrsToList
      (tree: bySystem: {
        path = "artifacts/${tree}";
        archive = {
          inherit (builtins.head (builtins.attrValues bySystem)) url mirrors;
          stripTop = false;
        };
        inherit (builtins.head (builtins.attrValues bySystem)) hash;
        systems = builtins.attrNames bySystem;
      })
      (
        lib.foldlAttrs (
          acc: system: artifacts:
          lib.recursiveUpdate acc (lib.mapAttrs (_: a: { ${system} = a; }) artifacts)
        ) { } parsed.artifacts
      );

  # Each registry is a tarball beside the pointer file that names it, as Pkg
  # keeps a registry it installs from a package server.
  registryEntries = lib.concatLists (
    lib.mapAttrsToList (uuid: r: [
      {
        path = "registries/${r.name}.tar.gz";
        url = "${parsed.server}/registry/${uuid}/${r.tree}";
        mirrors = serverMirrors "registry/${uuid}/${r.tree}";
        inherit (r) hash;
      }
      {
        path = "registries/${r.name}.toml";
        contents = ''
          git-tree-sha1 = "${r.tree}"
          path = "${r.name}.tar.gz"
          uuid = "${uuid}"
        '';
      }
    ]) parsed.registries
  );

  readProject =
    dir:
    builtins.fromTOML (builtins.readFile (src + "/${if dir == "." then "" else dir + "/"}Project.toml"))
    // {
      inherit dir;
    };

  root = readProject ".";
  # A workspace lists its members relative to the root, possibly with a
  # leading "./".
  memberDirs = map (lib.removePrefix "./") (root.workspace.projects or [ ]);
  projects = lib.listToAttrs (
    map (dir: lib.nameValuePair dir (readProject dir)) ([ "." ] ++ memberDirs)
  );
in
{
  purifier = "julia-purifier";
  entries = lib.optionals (problem == null) (
    packageEntries ++ gitEntries ++ artifactEntries ++ registryEntries
  );
  outputs = lib.listToAttrs (
    map (p: lib.nameValuePair p.name p) (
      builtins.filter (p: p ? name && p ? uuid) (builtins.attrValues projects)
    )
  );
  problems = lib.optional (problem != null) problem;
  julia = {
    placements = map (p: p // { from = sourceOf p; }) allPinned;
    inherit (parsed) tests editor;
    systems = builtins.attrNames parsed.artifacts;
    version = projectManifest.julia_version;
    inherit manifestName projects;
    manifest = manifestPath;
  };
}
