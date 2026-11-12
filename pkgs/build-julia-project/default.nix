# SPDX-License-Identifier: MIT
#
# buildJuliaProject: builds a Julia project in the Nix sandbox from its
# manifest and julia-purifier.lock.json, offline.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The flake of
# julia-purifier adds it to the package set as `buildJuliaProject` with
# `overlays.default`, so a package written for callPackage takes it like any
# other dependency:
#
#   { buildJuliaProject }: (buildJuliaProject { src = ./.; }).packages.<Name>
#
# and `buildJuliaProject.override` replaces what it takes from the set. The
# builder returns
#
#   packages     one package per project that is a Julia package (the root
#                and the members of a workspace), by package name. Each has
#                `bin/<app>` for every entry of the [apps] table in its
#                Project.toml, and `share/julia-purifier/project`. Its
#                `tests` attribute runs the package's tests
#   tests        the run of every package's tests
#   release      what `julia-purifier publish` registers: per package, its
#                source as Nix tested it and the git tree hash of that source
#   fetches      the entries of the lock (lib.julia-purifier.readLock): the
#                download entries of the shared purifier library for every
#                system the lockfile covers, each artifact with `systems`
#   depot        the Julia depot of the project's dependencies: every
#                package source, artifact and registry the lock names, the
#                files that the dependencies' deps/build.jl scripts write,
#                and the dependencies' precompiled caches. It is built from
#                the manifest and the lockfile only, so it stays the same
#                while the project's own sources change
#   compiled     a depot with the precompiled caches of the project's own
#                packages, on top of `depot`
#   environment  `bin/julia`, Julia with the project active and both depots
#                behind the user's own depot, offline
#   editor       the environment of LanguageServer.jl, with its own depot,
#                for an editor's language server
#   julia        the Julia the project builds with
#
# Every attribute name of the result is known at evaluation time, from the
# Project.toml files and the lockfile.
{
  lib,
  stdenvNoCC,
  runCommand,
  makeWrapper,
  writeText,
  unzip,
  zstd,
  python3,
  fetchurl,
  fetchgit,
  # The shared purifier library, which lays out the downloads.
  purifier,
  # The Julia packages of the package set. The default Julia of a build is
  # the one of the major and minor version that the manifest names.
  julia_110-bin ? null,
  julia_111-bin ? null,
  julia_112-bin ? null,
  julia_113-bin ? null,
}:
{
  # The project root: the directory with the Manifest.toml (the root of a
  # workspace).
  src,
  # Fetchers for the shared purifier library, in place of the ones of the
  # package set, such as a `fetchurl` that goes through a company mirror or
  # sends credentials.
  fetchers ? { },
  # The lockfile. A lockfile kept outside `src` replaces any copy in it.
  lockFile ? src + "/julia-purifier.lock.json",
  # The Manifest.toml, which defaults to the copy in `src`. A copy kept
  # outside `src`, such as one beside an external lockfile, replaces the one
  # in `src` for the build.
  manifest ? null,
  # The Julia that builds and runs the project. The default is the
  # nixpkgs Julia of the major and minor version the lock was made with.
  julia ? null,
  # Runs every package's tests as part of building it.
  doCheck ? false,
  # Precompiles the dependencies and the project in the build. Julia stamps
  # every precompiled cache with a build identifier, so a build with
  # precompiled caches differs from a rebuild of it; without them, every
  # output is reproducible, and Julia compiles on first use instead.
  precompile ? true,
}:
let
  system = stdenvNoCC.hostPlatform.system;
  lock = purifier.checkLock (
    import ../../lib-overlays/default/lock.nix { inherit lib; } {
      inherit src lockFile manifest;
    }
  );
  l = lock.julia // {
    packages = lock.outputs;
    julia = lock.julia.version;
    downloads =
      if builtins.elem system lock.julia.systems then
        purifier.entriesFor system lock
      else
        throw "julia-purifier: ${toString lockFile} records no artifacts for ${system}; the lock covers ${lib.concatStringsSep ", " lock.julia.systems}.";
  };

  # The project as Julia sees it: `src`, with the manifest beside its
  # Project.toml when the manifest is kept elsewhere. Evaluation reads the
  # files from `src` and `manifest`; only builds use this copy.
  projectSrc =
    if manifest == null then
      src
    else
      runCommand "julia-project-source" { } ''
        cp -r ${src} "$out"
        chmod -R u+w "$out"
        cp ${manifest} "$out/${l.manifestName}"
      '';

  juliaVersion = lib.splitVersion l.julia;
  juliaAttr = "julia_${builtins.elemAt juliaVersion 0}${builtins.elemAt juliaVersion 1}-bin";
  juliaPackages = {
    "julia_110-bin" = julia_110-bin;
    "julia_111-bin" = julia_111-bin;
    "julia_112-bin" = julia_112-bin;
    "julia_113-bin" = julia_113-bin;
  };
  julia' =
    if julia != null then
      julia
    else if juliaPackages.${juliaAttr} or null != null then
      juliaPackages.${juliaAttr}
    else
      throw "julia-purifier: the lock was made with Julia ${l.julia}, and the package set has no ${juliaAttr}; pass `julia` to buildJuliaProject.";

  downloads = purifier.tree (
    {
      # The packages that the shared library builds the downloads with.
      inherit
        runCommand
        writeText
        unzip
        zstd
        python3
        fetchurl
        fetchgit
        ;
      name = "julia-purifier-downloads";
      entries = l.downloads;
    }
    // fetchers
  );

  # The downloads that go into the depot at their own path: artifacts and
  # registries. Package sources come from trees/ and git/, and
  # pkgs/build-julia-project/place.jl puts them at the paths Julia derives from the
  # manifests.
  depotPaths = builtins.filter (p: lib.hasPrefix "artifacts/" p || lib.hasPrefix "registries/" p) (
    map (d: d.path) l.downloads
  );

  projectDir = dir: if dir == "." then "${projectSrc}" else "${projectSrc}/${dir}";

  offlineEnv = ''
    export HOME="$TMPDIR"
    export JULIA_PKG_OFFLINE=true
    export JULIA_PKG_SERVER=""
    export JULIA_PKG_PRECOMPILE_AUTO=0
  '';

  # The manifest is copied to the store on its own, so the depot does not
  # depend on the rest of the source.
  manifestStore = builtins.path {
    path = l.manifest;
    name = "Manifest.toml";
  };

  depot =
    runCommand "julia-purifier-depot"
      {
        nativeBuildInputs = [ julia' ];
        passAsFile = [
          "paths"
          "placements"
        ];
        paths = lib.concatMapStrings (p: "${p}\n") depotPaths;
        placements = lib.concatMapStrings (
          p: "${p.name} ${p.uuid} ${p.tree} ${p.from} ${if p.main then "1" else "0"}\n"
        ) l.placements;
      }
      ''
        ${offlineEnv}
        mkdir -p "$out/packages" "$out/artifacts"
        while IFS= read -r p; do
          mkdir -p "$out/$(dirname "$p")"
          cp -rL --preserve=mode ${downloads}/"$p" "$out/$p"
        done < "$pathsPath"
        export JULIA_DEPOT_PATH="$out:"
        julia --startup-file=no ${./place.jl} ${downloads} "$out" "$placementsPath" > builds
        chmod -R u+w "$out"

        julia --startup-file=no ${./deps-env.jl} ${manifestStore} deps
        deps="$PWD/deps"
        julia --startup-file=no --project="$deps" -e 'using Pkg; Pkg.instantiate()'
        # Each deps/build.jl runs from its deps directory, in the environment
        # of the manifest's packages, with the flags Pkg builds with. Pkg's
        # own build resolves a fresh environment against a registry, which
        # the sandbox does not have.
        while IFS= read -r p; do
          echo "julia-purifier: running $p/deps/build.jl"
          (cd "$out/$p/deps" && julia --startup-file=no --project="$deps" -O0 --compile=min --color=no build.jl)
        done < builds
        ${lib.optionalString precompile ''
          julia --startup-file=no --project="$deps" -e 'using Pkg; Pkg.precompile()'
        ''}
        rm -rf "$out/logs" "$out/scratchspaces"
      '';

  # Julia writes new caches into the first depot only, so the project's own
  # packages are compiled into this depot and the dependencies' caches stay
  # in `depot`.
  compiled =
    runCommand "julia-purifier-compiled"
      {
        nativeBuildInputs = [ julia' ];
      }
      ''
        ${offlineEnv}
        mkdir -p "$out"
        export JULIA_DEPOT_PATH="$out:${depot}:"
        # Pkg precompiles what the active project reaches, so each project
        # of a workspace is precompiled on its own.
        ${lib.optionalString precompile ''
          for dir in ${lib.escapeShellArgs (map projectDir (builtins.attrNames l.projects))}; do
            julia --startup-file=no --project="$dir" -e '
              using Pkg
              Pkg.instantiate()
              Pkg.precompile()
            '
          done
        ''}
        rm -rf "$out/logs" "$out/environments" "$out/scratchspaces"
      '';

  # The depots a program of the project runs with. The leading empty entry
  # puts the user's own depot first, where Julia writes.
  runtimeDepots = ":${compiled}:${depot}";

  environment =
    runCommand "julia-purifier-environment"
      {
        nativeBuildInputs = [ makeWrapper ];
      }
      ''
        mkdir -p "$out/bin"
        makeWrapper ${lib.getExe julia'} "$out/bin/julia" \
          --set JULIA_DEPOT_PATH ${lib.escapeShellArg runtimeDepots} \
          --set-default JULIA_PKG_OFFLINE true \
          --add-flags "--project=${projectSrc}"
      '';

  # The language server's environment: `env` holds its Project.toml and
  # Manifest.toml, `depot` the precompiled caches of LanguageServer.jl on
  # top of the project's depot.
  editor =
    runCommand "julia-purifier-editor"
      {
        nativeBuildInputs = [ julia' ];
        passAsFile = [
          "project"
          "manifest"
        ];
        project = l.editor."Project.toml";
        manifest = l.editor."Manifest.toml";
      }
      ''
        ${offlineEnv}
        mkdir -p "$out/env" "$out/depot"
        cp "$projectPath" "$out/env/Project.toml"
        cp "$manifestPath" "$out/env/Manifest.toml"
        export JULIA_DEPOT_PATH="$out/depot:${depot}:"
        julia --startup-file=no ${./project-hash.jl} "$out/env"
        julia --startup-file=no --project="$out/env" -e '
          using Pkg
          Pkg.instantiate()
          ${lib.optionalString precompile "Pkg.precompile()"}
        '
        rm -rf "$out/depot/logs" "$out/depot/environments" "$out/depot/scratchspaces"
      '';

  testFor =
    p:
    let
      dir = projectDir p.dir;
      recorded = l.tests.${p.dir} or null;
      inWorkspace = l.projects ? ${if p.dir == "." then "test" else "${p.dir}/test"};
      depots = "$TMPDIR/depot:${compiled}:${depot}:";
    in
    if recorded != null then
      runCommand "${p.name}-tests"
        {
          nativeBuildInputs = [ julia' ];
          passAsFile = [
            "project"
            "manifest"
          ];
          project = recorded."Project.toml";
          manifest = recorded."Manifest.toml";
        }
        ''
          ${offlineEnv}
          # The recorded environment names the project as ../root.
          mkdir -p env
          ln -s ${projectSrc} root
          cp "$projectPath" env/Project.toml
          cp "$manifestPath" env/Manifest.toml
          env="$PWD/env"
          export JULIA_DEPOT_PATH="${depots}"
          julia --startup-file=no ${./project-hash.jl} "$env"
          julia --startup-file=no --project="$env" -e 'using Pkg; Pkg.instantiate()'
          cd ${dir}/test
          julia --startup-file=no --project="$env" --check-bounds=yes runtests.jl
          touch "$out"
        ''
    else if inWorkspace || builtins.pathExists (src + "/${p.dir}/test/runtests.jl") then
      runCommand "${p.name}-tests"
        {
          nativeBuildInputs = [ julia' ];
        }
        ''
          ${offlineEnv}
          export JULIA_DEPOT_PATH="${depots}"
          cd ${dir}/test
          julia --startup-file=no --project=${
            if inWorkspace then "${dir}/test" else dir
          } --check-bounds=yes runtests.jl
          touch "$out"
        ''
    else
      null;

  packageTests = lib.filterAttrs (_: t: t != null) (lib.mapAttrs (_: testFor) l.packages);

  tests = runCommand "julia-purifier-tests" { } ''
    mkdir -p "$out"
    ${lib.concatStrings (lib.mapAttrsToList (name: t: "ln -s ${t} \"$out/${name}\"\n") packageTests)}
  '';

  # Per package, its source as `src` holds it, its directory in `src` and the
  # git tree hash of that source, which a registry records. The source comes
  # from `src` rather than from the copy with an added manifest, so that its
  # tree hash is the tree of the committed directory. A release depends on
  # the tests, so only a tested source is released.
  release =
    runCommand "julia-purifier-release"
      {
        nativeBuildInputs = [ julia' ];
        inherit tests;
      }
      ''
        export HOME="$TMPDIR"
        mkdir -p "$out"
        ${lib.concatStrings (
          lib.mapAttrsToList (name: p: ''
            cp -r ${if p.dir == "." then "${src}" else "${src}/${p.dir}"} "$out/${name}"
            printf '%s\n' ${lib.escapeShellArg p.dir} > "$out/${name}.dir"
            julia --startup-file=no -e '
              using Pkg
              print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))
            ' "$out/${name}" > "$out/${name}.tree-sha1"
          '') l.packages
        )}
      '';

  packageFor =
    name: p:
    let
      apps = p.apps or { };
      appFlags =
        spec:
        lib.concatStringsSep " " (
          [
            "--startup-file=no"
            "--project=${projectDir p.dir}"
          ]
          ++ (spec.julia_flags or [ ])
          ++ [
            "-m"
            (if spec ? submodule then "${name}.${spec.submodule}" else name)
          ]
        );
      test = packageTests.${name} or null;
    in
    runCommand "${lib.strings.sanitizeDerivationName name}-${p.version or "0.0.0"}"
      {
        nativeBuildInputs = [ makeWrapper ];
        # With doCheck, building the package runs its tests.
        checked = lib.optionalString (doCheck && test != null) "${test}";
        passthru = {
          inherit depot compiled;
          julia = julia';
          tests = test;
          project = projectDir p.dir;
        };
        meta = lib.optionalAttrs (apps != { }) {
          mainProgram = builtins.head (builtins.attrNames apps);
        };
      }
      ''
        mkdir -p "$out/bin" "$out/share/julia-purifier"
        ln -s ${projectDir p.dir} "$out/share/julia-purifier/project"
        ${lib.concatStrings (
          lib.mapAttrsToList (app: spec: ''
            makeWrapper ${lib.getExe julia'} "$out/bin/${app}" \
              --set JULIA_DEPOT_PATH ${lib.escapeShellArg runtimeDepots} \
              --set-default JULIA_PKG_OFFLINE true \
              --add-flags ${lib.escapeShellArg (appFlags spec)}
          '') apps
        )}
      '';
in
{
  packages = lib.mapAttrs packageFor l.packages;
  inherit
    tests
    release
    depot
    compiled
    environment
    editor
    ;
  fetches = lock.entries;
  julia = julia';
}
