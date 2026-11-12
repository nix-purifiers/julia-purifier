# SPDX-License-Identifier: MIT
#
# The julia-purifier command.
#
#   julia-purifier lock [dir]        records every file Pkg downloads for
#                                    the project in julia-purifier.lock.json,
#                                    keeping the manifest's resolution
#   julia-purifier update [pkg...]   updates the named packages (or every
#                                    package) with Pkg, then locks
#   julia-purifier prefetch [dir]    realizes what development needs offline
#                                    (dependencies, test dependencies,
#                                    registries, Julia, the language server),
#                                    with a GC root in .julia-purifier/
#                                    beside the lockfile
#   julia-purifier publish <registry> [--push] [dir]
#                                    builds and tests the committed project
#                                    with Nix, then registers its packages
#   julia-purifier julia [args...]   runs Julia on the prefetched downloads
#   julia-purifier env               prints that environment as exports
#   julia-purifier language-server   runs LanguageServer.jl for an editor
#
# A lockfile kept outside the project is named by JULIA_PURIFIER_LOCKFILE or,
# taking precedence, by --lockfile <path>. Every command takes --lockfile
# right after its name. The commands take the Julia of
# the major and minor version the manifest records, from the nixpkgs this
# package was built from.
{
  lib,
  writeShellApplication,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  git,
  nix,
  path,
  stdenv,
  # The Julia for a directory without a manifest.
  julia-bin,
}:
let
  runtime = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../lib-overlays
      ../../pkgs
      ../../src
      ../../flake.lock
    ];
  };
in
writeShellApplication {
  name = "julia-purifier";
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
    gnused
    git
    nix
  ];
  text = ''
    nixpkgs=${path}
    system=${stdenv.hostPlatform.system}
    lib=${runtime}/pkgs/build-julia-project
    # The flake's lock, which pins the shared purifier library for the
    # evaluations below.
    flake_lock=${../../flake.lock}
    lock_jl=${../../src/lock.jl}
    publish_jl=${../../src/publish.jl}
    language_server_jl=${../../src/language-server.jl}

    usage() {
      sed -n 's/^# \{0,1\}//; 4,26p' ${./default.nix} >&2
      exit 2
    }

    # The project root: the nearest directory upwards with a manifest.
    find_root() {
      local dir
      dir="$(realpath "$1")"
      while [ ! -f "$dir/Manifest.toml" ] && ! compgen -G "$dir/Manifest-v*.toml" > /dev/null; do
        if [ "$dir" = / ]; then
          return 1
        fi
        dir="$(dirname "$dir")"
      done
      printf '%s\n' "$dir"
    }

    # The Manifest.toml of a project: the one named by --tool-lockfile or
    # JULIA_PURIFIER_TOOL_LOCKFILE when it exists, and otherwise the one in
    # the project directory.
    manifest_of() {
      if [ -n "$tool_arg" ] && [ -f "$tool_arg" ]; then
        printf '%s\n' "$tool_arg"
      elif [ -f "$1/Manifest.toml" ]; then
        printf '%s\n' "$1/Manifest.toml"
      else
        compgen -G "$1/Manifest-v*.toml" | head -n1
      fi
    }

    # The directory a lock starts from: the nearest directory upwards with a
    # manifest, or else the nearest one with a Project.toml, whose manifest
    # the lock then writes.
    find_project() {
      find_root "$1" && return
      local dir
      dir="$(realpath "$1")"
      while [ ! -f "$dir/Project.toml" ]; do
        if [ "$dir" = / ]; then
          return 1
        fi
        dir="$(dirname "$dir")"
      done
      printf '%s\n' "$dir"
    }

    # The nixpkgs Julia of the manifest's major and minor version, or
    # nixpkgs' default Julia for a project without a manifest.
    julia_for() {
      local version attr manifest
      manifest="$(manifest_of "$1")"
      if [ -z "$manifest" ]; then
        printf '%s\n' ${julia-bin}
        return
      fi
      version="$(grep -m1 '^julia_version' "$manifest" | sed 's/.*"\(.*\)".*/\1/')"
      if [ -z "$version" ]; then
        echo "julia-purifier: $1 has a manifest without julia_version; run Pkg.resolve() with Julia 1.7 or newer" >&2
        exit 1
      fi
      attr="julia_$(echo "$version" | cut -d. -f1)$(echo "$version" | cut -d. -f2)-bin"
      # The expression is Nix, which reads the attribute from the environment.
      # shellcheck disable=SC2016
      JP_NIXPKGS="$nixpkgs" JP_SYSTEM="$system" JP_ATTR="$attr" nix build --impure --no-link --print-out-paths --expr '
        (import (builtins.getEnv "JP_NIXPKGS") { system = builtins.getEnv "JP_SYSTEM"; }).''${builtins.getEnv "JP_ATTR"}
      '
    }

    # The project root with a lockfile, from the current directory, and the
    # lockfile: --lockfile, or julia-purifier.lock.json in the root.
    locked_root() {
      root="$(if [ -n "$tool_arg" ]; then find_project .; else find_root .; fi)" || {
        echo "julia-purifier: no Manifest.toml here or above; run \`julia-purifier lock\` in the project" >&2
        exit 1
      }
      lockfile="''${lockfile_arg:-$root/julia-purifier.lock.json}"
      [ -f "$lockfile" ] || {
        echo "julia-purifier: $lockfile does not exist; run \`julia-purifier lock\` in the project" >&2
        exit 1
      }
    }

    # Realizes the prefetch of $root in the store, with a GC root at
    # .julia-purifier/prefetch beside the lockfile, and sets $prefetched to
    # it. The stamp
    # covers the files a lock is made from (the lockfile, the manifest and
    # every Project.toml), so that a change to any of them is checked against
    # the lockfile again.
    prefetch() {
      local stamp state
      state="$(dirname "$lockfile")/.julia-purifier"
      prefetched="$state/prefetch"
      stamp="$(
        {
          cat "$lockfile" "$(manifest_of "$root")"
          find "$root" -name Project.toml -not -path '*/.git/*' -not -path '*/.julia-purifier/*' -print0 | sort -z | xargs -0 cat
        } | sha256sum | cut -d' ' -f1
      )"
      if [ "$(cat "$state/stamp" 2> /dev/null || true)" != "$stamp" ] || [ ! -e "$prefetched" ]; then
        echo "julia-purifier: prefetching the locked downloads of $root" >&2
        mkdir -p "$state"
        if ! JP_NIXPKGS="$nixpkgs" JP_SYSTEM="$system" JP_ROOT="$root" JP_LOCK="$lockfile" JP_MANIFEST="''${tool_arg:+$(manifest_of "$root")}" nix build --impure --out-link "$prefetched" --expr "
          import $lib/prefetch.nix {
            pkgs = import (builtins.getEnv \"JP_NIXPKGS\") { system = builtins.getEnv \"JP_SYSTEM\"; };
            src = /. + builtins.getEnv \"JP_ROOT\";
            lockFile = /. + builtins.getEnv \"JP_LOCK\";
            manifest = if builtins.getEnv \"JP_MANIFEST\" == \"\" then null else /. + builtins.getEnv \"JP_MANIFEST\";
            flakeLock = $flake_lock;
          }
        "; then
          echo "julia-purifier: the lockfile does not build; run \`julia-purifier lock\` to renew it, or set JULIA_PURIFIER=0" >&2
          exit 1
        fi
        printf '%s\n' "$stamp" > "$state/stamp"
      fi
    }

    cmd="''${1:-}"
    [ -n "$cmd" ] || usage
    shift
    lockfile_arg=
    if [ -n "''${JULIA_PURIFIER_LOCKFILE:-}" ]; then
      lockfile_arg="$(realpath -m "$JULIA_PURIFIER_LOCKFILE")"
    fi
    tool_arg=
    if [ -n "''${JULIA_PURIFIER_TOOL_LOCKFILE:-}" ]; then
      tool_arg="$(realpath -m "$JULIA_PURIFIER_TOOL_LOCKFILE")"
    fi
    while [ "''${1:-}" = --lockfile ] || [ "''${1:-}" = --tool-lockfile ]; do
      case "$1" in
        --lockfile) lockfile_arg="$(realpath -m "''${2:?--lockfile needs a path}")" ;;
        --tool-lockfile) tool_arg="$(realpath -m "''${2:?--tool-lockfile needs a path}")" ;;
      esac
      shift 2
    done

    case "$cmd" in
      lock | update)
        # `lock` takes the project directory; `update` runs in the current
        # directory and takes the packages to update, or none for every
        # package.
        if [ "$cmd" = lock ]; then
          dir="''${1:-.}"
          update=()
        else
          dir=.
          update=(--update "$@")
        fi
        root="$(find_project "$dir")" || {
          echo "julia-purifier: no Project.toml in $dir or above; run the $cmd in a Julia project" >&2
          exit 1
        }
        julia="$(julia_for "$root")"
        depot="$(mktemp -d)"
        trap 'chmod -R u+w "$depot"; rm -rf "$depot"' EXIT
        # A fresh depot, so that every file Pkg needs is downloaded and
        # recorded. The trailing ":" keeps Julia's own depots after it.
        JULIA_DEPOT_PATH="$depot:" "$julia/bin/julia" --startup-file=no "$lock_jl" "$root" \
          ''${lockfile_arg:+--lockfile "$lockfile_arg"} \
          ''${tool_arg:+--tool-lockfile "$tool_arg"} "''${update[@]}"
        ;;

      prefetch)
        if [ -n "''${1:-}" ]; then
          cd "$1"
        fi
        locked_root
        prefetch
        echo "julia-purifier: $root works offline with its locked downloads; the GC root is $prefetched" >&2
        ;;

      julia)
        # Without a lockfile (or with JULIA_PURIFIER=0) this is plain Julia:
        # the manifest's Julia where there is a manifest, nixpkgs' default
        # Julia otherwise.
        if [ "''${JULIA_PURIFIER:-1}" = 0 ] || ! root="$(find_root .)" || [ ! -f "''${lockfile_arg:-$root/julia-purifier.lock.json}" ]; then
          if [ "''${JULIA_PURIFIER:-1}" != 0 ]; then
            echo "julia-purifier: warning: no julia-purifier.lock.json found; running julia impurely. Run \`julia-purifier lock\` to use Nix-resolved dependencies." >&2
          fi
          if [ -n "''${root:-}" ] && julia="$(julia_for "$root")"; then
            exec "$julia/bin/julia" "$@"
          fi
          exec ${julia-bin}/bin/julia "$@"
        fi
        locked_root
        prefetch
        # The user's own depot comes first (the leading ":"), where Julia
        # writes; the locked downloads come after it.
        export JULIA_DEPOT_PATH=":$prefetched/depot"
        export JULIA_PKG_OFFLINE="''${JULIA_PKG_OFFLINE:-true}"
        exec "$prefetched/julia/bin/julia" --project="$root" "$@"
        ;;

      env)
        # For direnv, an editor or a shell, which start `julia` themselves:
        # the environment `julia-purifier julia` runs Julia in.
        locked_root
        prefetch
        printf 'export JULIA_DEPOT_PATH=%q\n' ":$prefetched/depot"
        printf 'export JULIA_PKG_OFFLINE=true\n'
        printf 'export JULIA_PROJECT=%q\n' "$root"
        printf 'export PATH=%q\n' "$prefetched/julia/bin:$PATH"
        ;;

      language-server)
        # LanguageServer.jl on stdin and stdout, for an editor, from the
        # prefetched editor environment. Its index goes under
        # $XDG_CACHE_HOME/julia-purifier.
        locked_root
        prefetch > /dev/null
        store="''${XDG_CACHE_HOME:-$HOME/.cache}/julia-purifier/language-server/$(printf '%s' "$root" | sha256sum | cut -c1-32)"
        export JULIA_DEPOT_PATH=":$prefetched/editor/depot:$prefetched/depot"
        export JULIA_PKG_OFFLINE=true
        exec "$prefetched/julia/bin/julia" --startup-file=no --history-file=no \
          --project="$prefetched/editor/env" "$language_server_jl" "$root" "$store"
        ;;

      publish)
        registry="''${1:-}"
        [ -n "$registry" ] || usage
        shift
        push=no
        if [ "''${1:-}" = --push ]; then
          push=push
          shift
        fi
        root="$(find_root "''${1:-.}")" || {
          echo "julia-purifier: no Manifest.toml in ''${1:-.} or above" >&2
          exit 1
        }
        if [ -n "$(git -C "$root" status --porcelain --untracked-files=no -- .)" ]; then
          echo "julia-purifier: $root has uncommitted changes; a registry records the committed tree" >&2
          exit 1
        fi
        top="$(git -C "$root" rev-parse --show-toplevel)"
        rev="$(git -C "$root" rev-parse HEAD)"
        sub="$(realpath --relative-to="$top" "$root")"
        lockfile="''${lockfile_arg:-$root/julia-purifier.lock.json}"
        manifest="$(manifest_of "$root")"
        echo "julia-purifier: building and testing the release of $rev:$sub with Nix" >&2
        # The source is the committed tree. The lockfile and the manifest
        # come from the working tree, where a package may keep them out of
        # version control.
        release="$(JP_NIXPKGS="$nixpkgs" JP_SYSTEM="$system" JP_TOP="$top" JP_REV="$rev" JP_SUB="$sub" JP_LOCK="$lockfile" JP_MANIFEST="$manifest" \
          nix build --impure --no-link --print-out-paths --expr "
          let
            pkgs = import (builtins.getEnv \"JP_NIXPKGS\") { system = builtins.getEnv \"JP_SYSTEM\"; };
            purifier = import $lib/purifier.nix { inherit (pkgs) lib; flakeLock = $flake_lock; };
            buildJuliaProject = pkgs.callPackage $lib/build-julia-project.nix { inherit purifier; };
            repo = builtins.fetchGit { url = builtins.getEnv \"JP_TOP\"; rev = builtins.getEnv \"JP_REV\"; };
            sub = builtins.getEnv \"JP_SUB\";
            src = if sub == \".\" then repo else repo + \"/\" + sub;
          in
          (buildJuliaProject {
            inherit src;
            lockFile = /. + builtins.getEnv \"JP_LOCK\";
            manifest = /. + builtins.getEnv \"JP_MANIFEST\";
          }).release
        ")"
        # Each released package must be the committed tree of its
        # directory, which is what a registry records.
        dirs=()
        for tree_file in "$release"/*.tree-sha1; do
          name="$(basename "$tree_file" .tree-sha1)"
          dir="$(cat "$release/$name.dir")"
          path="$sub/$dir"
          committed="$(git -C "$top" rev-parse "$rev:$(realpath -m --relative-to=. "$path" | sed 's|^\./||; s|^\.$||')")"
          if [ "$committed" != "$(cat "$tree_file")" ]; then
            echo "julia-purifier: the release of $name ($(cat "$tree_file")) is not the committed tree $committed" >&2
            exit 1
          fi
          dirs+=("$root/$dir")
        done
        julia="$(julia_for "$root")"
        depot="$(mktemp -d)"
        trap 'chmod -R u+w "$depot"; rm -rf "$depot"' EXIT
        JULIA_DEPOT_PATH="$depot:''${JULIA_DEPOT_PATH:-}" "$julia/bin/julia" --startup-file=no "$publish_jl" "$registry" "$push" "''${dirs[@]}"
        ;;

      *)
        usage
        ;;
    esac
  '';
}
