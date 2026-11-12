# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # lib.julia-purifier.readLock of this flake.
  readLock',
  # lib.purifier.checkLock of the shared library.
  checkLock,
  # The flake's default package overlay, which adds the julia-purifier
  # command.
  overlay,
  # The source of JSON3.jl, pinned in tests/dependencies.
  json3,
}:
let
  inherit (pkgs) lib;

  withOverlay = pkgs.extend overlay;
  inherit (withOverlay.julia-purifier) buildJuliaProject;
  build = buildJuliaProject;

  # One package with a command, a JSON dependency from the General
  # registry, StringEncodings with its Libiconv_jll artifact, Example from
  # its git repository, and a test-only dependency from [extras].
  app = build { src = ./fixtures/app; };
  appChecked = build {
    src = ./fixtures/app;
    doCheck = true;
  };

  # A workspace with a library member that uses a package from a
  # subdirectory of a git repository, its test project, and a command
  # member that depends on the library through a path source.
  workspace = build { src = ./fixtures/workspace; };

  # An environment (no package of its own) whose dependency Conda has a
  # deps/build.jl, which the depot build runs offline.
  buildscript = build { src = ./fixtures/buildscript; };

  # A real-world package, JSON3.jl, whose manifest and lockfile lie beside
  # the source rather than in it. Its tests use Arrow, with the LZ4 and
  # Zstandard binary artifacts, and JSON3's ArrowTypes extension.
  realworld = build {
    src = json3;
    manifest = ./realworld/JSON3/Manifest.toml;
    lockFile = ./realworld/JSON3/julia-purifier.lock.json;
  };

  readLock =
    lockFile:
    readLock' {
      inherit lockFile;
      src = ./fixtures/app;
    };

  # A check passes when `assertion` holds; it fails with `message`
  # otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "julia-purifier check ${name}: ${message}";

  # Whether evaluating `value` throws.
  fails = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  # A conformance check on the app's lock from the lockfile `text`: the
  # lock has exactly one problem, which says `reason` and names
  # `julia-purifier lock`, and checkLock fails on it.
  conformanceCheck =
    name: text: reason:
    let
      lock = readLock' {
        src = ./fixtures/app;
        lockFile = builtins.toFile "${name}.lock.json" text;
      };
      problems = lock.problems;
    in
    evalCheck name (
      builtins.length problems == 1
      && lib.hasInfix reason (builtins.head problems)
      && lib.hasInfix "julia-purifier lock" (builtins.head problems)
      && lock.entries == [ ]
      && fails (checkLock lock)
    ) "the lock has the problems ${builtins.toJSON problems}; one that says \"${reason}\" was expected";

  # The app's lockfile with one edit. `rehash` gives the edited text a
  # correct content hash, as a lock run would write it.
  appLock = builtins.readFile ./fixtures/app/julia-purifier.lock.json;
  hashOf =
    text:
    builtins.head (
      builtins.match "  \"hash\": \"(sha256-[^\"]*)\"," (builtins.elemAt (lib.splitString "\n" text) 2)
    );
  rehash =
    text:
    let
      blank = builtins.replaceStrings [ ''"hash": "${hashOf text}"'' ] [ ''"hash": ""'' ] text;
      hash = builtins.convertHash {
        hash = builtins.hashString "sha256" blank;
        hashAlgo = "sha256";
        toHashFormat = "sri";
      };
    in
    builtins.replaceStrings [ ''"hash": ""'' ] [ ''"hash": "${hash}"'' ] blank;
  lines = lib.splitString "\n" appLock;

  # The tree hash JSON has in the app's manifest.
  jsonTree =
    (builtins.head (builtins.fromTOML (builtins.readFile ./fixtures/app/Manifest.toml)).deps.JSON)
    ."git-tree-sha1";

  # The app fixture with its lockfile and its Manifest.toml kept outside the
  # source, which holds only the other files of the project.
  appExternal = build {
    src = lib.fileset.toSource {
      root = ./fixtures/app;
      fileset = lib.fileset.difference ./fixtures/app (
        lib.fileset.unions [
          ./fixtures/app/julia-purifier.lock.json
          ./fixtures/app/Manifest.toml
        ]
      );
    };
    lockFile = ./fixtures/app/julia-purifier.lock.json;
    manifest = ./fixtures/app/Manifest.toml;
  };

  # What `julia-purifier prefetch` realizes for the app fixture.
  appPrefetch = import ../pkgs/build-julia-project/prefetch.nix {
    inherit pkgs;
    src = ./fixtures/app;
    flakeLock = ../flake.lock;
  };
in
{
  # The command runs, with every dependency loaded, and Julia writes no
  # compiled cache of its own: the store holds them all.
  app =
    pkgs.runCommand "app-check"
      {
        nativeBuildInputs = [ app.packages.HelloPurifier ];
      }
      ''
        export HOME="$TMPDIR"
        hello-purifier Nix | grep -qx '{"greeting":"Hello, Nix","utf16le":6}'
        if [ -n "$(find "$HOME" -name '*.ji' -print -quit)" ]; then
          echo "the command compiled caches into the user's depot" >&2
          find "$HOME" -name '*.ji' >&2
          exit 1
        fi
        touch $out
      '';

  # The tests run in the environment Pkg.test resolved in the lock run,
  # with the test-only dependency.
  app-tests = app.tests;

  # With doCheck, building the package runs its tests.
  app-checked = appChecked.packages.HelloPurifier;

  # The release holds the package source and its git tree hash, after the
  # tests passed.
  app-release = pkgs.runCommand "app-release-check" { } ''
    test -f ${app.release}/HelloPurifier/Project.toml
    grep -Eqx '[0-9a-f]{40}' ${app.release}/HelloPurifier.tree-sha1
    touch $out
  '';

  # The environment is Julia with the project active.
  app-environment =
    pkgs.runCommand "app-environment-check"
      {
        nativeBuildInputs = [ app.environment ];
      }
      ''
        export HOME="$TMPDIR"
        julia -e 'using HelloPurifier; print(HelloPurifier.greeting("env"))' \
          | grep -qx '{"greeting":"Hello, env","utf16le":6}'
        touch $out
      '';

  # The command member greets through the library member.
  workspace =
    pkgs.runCommand "workspace-check"
      {
        nativeBuildInputs = [ workspace.packages.Greeter ];
      }
      ''
        export HOME="$TMPDIR"
        greet Nix | grep -qx 'Hello, Nix (SnoopCompileCore loaded: true)'
        touch $out
      '';

  # Conda loads, with the deps/deps.jl its build script wrote in the depot.
  buildscript =
    pkgs.runCommand "buildscript-check"
      {
        nativeBuildInputs = [ buildscript.environment ];
      }
      ''
        export HOME="$TMPDIR"
        julia -e '
          using Conda
          deps = joinpath(dirname(pathof(Conda)), "..", "deps", "deps.jl")
          isfile(deps) || error("Conda has no deps/deps.jl: its build script did not run")
          startswith(pathof(Conda), "${buildscript.depot}") || error("Conda loaded from $(pathof(Conda))")
        '
        touch $out
      '';

  # JSON3.jl's own test suite runs offline.
  realworld-json3-tests = realworld.tests;

  # JSON3.jl loads from its package and parses.
  realworld-json3 =
    pkgs.runCommand "realworld-json3-check"
      {
        nativeBuildInputs = [ realworld.environment ];
      }
      ''
        export HOME="$TMPDIR"
        julia -e 'using JSON3; print(JSON3.read("{\"a\":[1,2]}").a[2])' | grep -qx 2
        touch $out
      '';

  # The library member's tests run in the workspace's test project.
  workspace-tests = workspace.packages.Greeting.tests;

  # The outputs are known at evaluation time: one package per member that
  # is a package, one test run per package with tests.
  outputs = evalCheck "outputs" (
    builtins.attrNames workspace.packages == [
      "Greeter"
      "Greeting"
    ]
    && workspace.packages.Greeting.tests != null
    && workspace.packages.Greeter.tests == null
    && builtins.attrNames app.packages == [ "HelloPurifier" ]
    && app.packages.HelloPurifier.meta.mainProgram == "hello-purifier"
    && builtins.all (e: e ? path && e ? hash || e ? contents) app.fetches
  ) "the fixtures' packages, tests, commands or fetches differ from their Project.toml files";

  # A lockfile older than the project: its recorded hash of Project.toml
  # differs from the file.
  conformance-stale = conformanceCheck "conformance-stale" (rehash (
    builtins.replaceStrings [ ''"Project.toml": "'' ] [ ''"Project.toml": "0'' ] appLock
  )) "changed since";

  # A lockfile whose content changed without the lock run: a package hash
  # differs, and the content hash no longer matches.
  conformance-tampered = conformanceCheck "conformance-tampered" (builtins.replaceStrings
    [
      ''"${jsonTree}": "sha256-''
    ]
    [ ''"${jsonTree}": "sha256-A'' ]
    appLock
  ) "does not match the hash of its own content";

  # A lockfile without the hash of a package the manifest pins.
  conformance-missing = conformanceCheck "conformance-missing" (rehash (
    lib.concatStringsSep "\n" (builtins.filter (l: !lib.hasInfix ''"${jsonTree}"'' l) lines)
  )) "has no hash for JSON";

  # A truncated lockfile, which is not JSON.
  conformance-malformed = conformanceCheck "conformance-malformed" (builtins.substring 0 (
    builtins.stringLength appLock / 2
  ) appLock) "does not match the hash of its own content";

  # The lock of the unchanged app has no problems.
  lock-intact =
    let
      inherit (readLock ./fixtures/app/julia-purifier.lock.json) problems;
    in
    evalCheck "lock-intact" (
      problems == [ ]
    ) "the app's committed lockfile has the problems ${builtins.toJSON problems}";

  # A build for a system the lockfile has no artifacts for fails
  # evaluation.
  unlocked-system =
    let
      riscv = (import pkgs.path { system = "riscv64-linux"; }).extend overlay;
      project = riscv.julia-purifier.buildJuliaProject {
        src = ./fixtures/app;
        julia = pkgs.julia_113-bin;
      };
    in
    evalCheck "unlocked-system" (fails project.depot.drvPath)
      "a lockfile evaluated for a system it has no artifacts for";

  # A package written for callPackage takes the builder by name.
  consumer =
    evalCheck "consumer"
      (
        (withOverlay.callPackage (
          { julia-purifier }:
          (julia-purifier.buildJuliaProject { src = ./fixtures/app; }).packages.HelloPurifier
        ) { }).name == app.packages.HelloPurifier.name
      )
      "a package that takes the julia-purifier scope by name differs from the one built through the overlay";

  # `override` replaces what the builder takes from the package set: here
  # the Julia that the manifest names.
  builder-override = evalCheck "builder-override" (
    ((buildJuliaProject.override { julia_113-bin = pkgs.julia_110-bin; }) { src = ./fixtures/app; })
    .julia == pkgs.julia_110-bin
  ) "override did not replace the Julia package of the builder";

  # The app's source without its lockfile builds from the lockfile beside
  # it.
  conformance-external =
    pkgs.runCommand "conformance-external-check"
      {
        nativeBuildInputs = [ appExternal.packages.HelloPurifier ];
      }
      ''
        export HOME="$TMPDIR"
        hello-purifier external | grep -qx '{"greeting":"Hello, external","utf16le":16}'
        touch $out
      '';

  # The depot without precompiled caches, whose rebuild the CI job
  # conformance-rebuild compares with `nix build --rebuild`.
  conformance-rebuild =
    (build {
      src = ./fixtures/app;
      precompile = false;
    }).depot;

  # After a prefetch, with no network (the sandbox has none), the
  # development loop works in a writable copy of the project: Pkg
  # instantiates, the project loads, Pkg.test resolves and runs the tests
  # against the prefetched registry, and the language server loads.
  conformance-offline =
    pkgs.runCommand "conformance-offline-check"
      {
        nativeBuildInputs = [ pkgs.julia_113-bin ];
      }
      ''
        export HOME="$TMPDIR"
        cp -r ${./fixtures/app} app
        chmod -R u+w app
        export JULIA_DEPOT_PATH="$TMPDIR/depot:${appPrefetch}/depot:"
        export JULIA_PKG_OFFLINE=true
        julia --startup-file=no --project=app -e '
          using Pkg
          Pkg.instantiate()
          using HelloPurifier
          print(HelloPurifier.greeting("offline"))
          Pkg.test()
        ' | grep -q '"greeting":"Hello, offline"'
        JULIA_DEPOT_PATH="$TMPDIR/depot:${appPrefetch}/editor/depot:${appPrefetch}/depot:" \
          julia --startup-file=no --project=${appPrefetch}/editor/env -e 'using LanguageServer'
        touch $out
      '';

  # The lock run's parsing and path logic, in the sandbox.
  lock-unit =
    let
      sources = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../src
          ./lock-unit.jl
        ];
      };
    in
    pkgs.runCommand "lock-unit-check"
      {
        nativeBuildInputs = [
          pkgs.julia_113-bin
          pkgs.git
        ];
      }
      ''
        export HOME="$TMPDIR"
        julia --startup-file=no ${sources}/tests/lock-unit.jl
        touch $out
      '';

  # The command builds (writeShellApplication runs shellcheck on it).
  cli = withOverlay.julia-purifier.julia-purifier;
}
