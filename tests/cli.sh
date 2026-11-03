#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests the julia-purifier command on the fixtures, with the network. Each
# step has a name; with names as arguments, only those steps run.
#
#   relock    `lock` on a copy of each fixture, with its committed lockfile in
#             place, writes the same lockfile byte for byte (the CI job
#             conformance-relock). The General registry changes daily, so a
#             lock from scratch would record a newer registry snapshot; a
#             relock keeps the snapshot of an unchanged project
#   update    `update` moves a package that a copy of the app pins at an old
#             version, and both the manifest and the lockfile then pass
#             their stale checks (the CI job conformance-update)
#   rebuild   `nix build --rebuild` of the depot without precompiled caches
#             gives the same output (the CI job conformance-rebuild)
#   julia     `julia` in the app fixture runs Julia on the locked
#             dependencies, offline, and loads the project
#   stale     `julia` refuses a stale lockfile, with a message to relock
#   loop      the development loop: Julia started in the environment `env`
#             prints loads the project; adding a dependency makes the
#             lockfile stale until a relock; after it, the new dependency
#             loads offline
#   damaged   a build from a damaged lockfile fails with a message that
#             names the problem: a tampered hash, an edited file, a missing
#             entry, a malformed file and a stale input
#   prefetch  `prefetch` leaves a GC root beside the lockfile, and
#             `language-server` answers an editor's initialize request
#   external  `lock --lockfile` writes a lockfile outside the project, the
#             same as the committed one, and JULIA_PURIFIER_LOCKFILE finds it
#   publish   `publish` builds and tests the committed app with Nix and
#             registers its version in a local registry, which then records
#             the tree of the committed source
#
# Run it from the repository root: bash tests/cli.sh [step...]
set -Eeuo pipefail
trap 'echo "tests/cli.sh: line number $LINENO failed: $BASH_COMMAND" >&2' ERR

all=(relock update rebuild julia stale loop damaged prefetch external publish)
steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=("${all[@]}")

repo="$(pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
export HOME="$work/home"
export XDG_CACHE_HOME="$work/cache"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
mkdir -p "$HOME"
git config --global user.name "julia-purifier tests"
git config --global user.email "tests@julia-purifier.invalid"
git config --global init.defaultBranch main

nix build "$repo#julia-purifier" --out-link "$work/cli"
cli="$work/cli/bin/julia-purifier"
system="$(nix config show system)"

# A writable copy of a fixture at $work/<name>.
fixture() {
  rm -rf "${work:?}/$2"
  cp -r "$repo/tests/fixtures/$1" "$work/$2"
  chmod -R u+w "$work/$2"
}

step_relock() {
  for f in app workspace buildscript; do
    fixture "$f" "relock-$f"
    "$cli" lock "$work/relock-$f"
    diff -u "$repo/tests/fixtures/$f/julia-purifier.lock.json" "$work/relock-$f/julia-purifier.lock.json"
  done
}

# The version of Crayons in the Manifest.toml of the current directory.
crayons_version() {
  "$cli" julia -e 'using TOML; print(TOML.parsefile("Manifest.toml")["deps"]["Crayons"][1]["version"])'
}

step_update() {
  fixture app update
  cd "$work/update"
  JULIA_PKG_OFFLINE=false "$cli" julia -e 'using Pkg; Pkg.add(name = "Crayons", version = "4.0.0")'
  "$cli" lock
  # The lock keeps the manifest's resolution.
  crayons="$(crayons_version)"
  [ "$crayons" = 4.0.0 ] || {
    echo "lock changed the resolution of Crayons: $crayons" >&2
    exit 1
  }
  "$cli" update Crayons
  crayons="$(crayons_version)"
  [ "$crayons" != 4.0.0 ] || {
    echo "update left Crayons at 4.0.0" >&2
    exit 1
  }
  # The lockfile matches the updated manifest, so `julia` accepts it, and
  # the updated Crayons loads offline.
  "$cli" julia -e 'using Crayons; print(Crayon(foreground = :red))' > /dev/null
  cd "$work"
}

step_rebuild() {
  nix build --no-link "$repo#checks.$system.conformance-rebuild"
  nix build --no-link --rebuild "$repo#checks.$system.conformance-rebuild"
}

step_julia() {
  fixture app julia
  cd "$work/julia"
  out="$("$cli" julia -e 'using HelloPurifier; print(HelloPurifier.greeting("cli"))')"
  [ "$out" = '{"greeting":"Hello, cli","utf16le":6}' ] || {
    echo "unexpected output: $out" >&2
    exit 1
  }
  cd "$work"
}

step_stale() {
  fixture app stale-cli
  cd "$work/stale-cli"
  printf '\n# an edit\n' >> Project.toml
  if "$cli" julia -e 'exit(0)' 2> "$work/stale.log"; then
    echo "julia ran with a stale lockfile" >&2
    exit 1
  fi
  grep -q 'julia-purifier lock' "$work/stale.log"
  cd "$work"
}

step_loop() {
  fixture app loop
  cd "$work/loop"
  # An editor or a language server starts `julia` itself, in the
  # environment `julia-purifier env` prints.
  (
    eval "$("$cli" env)"
    out="$(julia -e 'using HelloPurifier; print(HelloPurifier.greeting("env"))')"
    [ "$out" = '{"greeting":"Hello, env","utf16le":6}' ] || {
      echo "unexpected output through julia-purifier env: $out" >&2
      exit 1
    }
  )
  # Adding a dependency needs the network, which Pkg has with
  # JULIA_PKG_OFFLINE=false; the lockfile is then stale until a relock.
  JULIA_PKG_OFFLINE=false "$cli" julia -e 'using Pkg; Pkg.add("Crayons")'
  if "$cli" julia -e 'exit(0)' 2> "$work/loop-stale.log"; then
    echo "julia ran after a dependency was added without a relock" >&2
    exit 1
  fi
  grep -q 'julia-purifier lock' "$work/loop-stale.log"
  "$cli" lock
  "$cli" julia -e 'using Crayons; print(Crayon(foreground = :red))' > /dev/null
  cd "$work"
}

# Builds the depot of the app copy at $work/<name> and checks that the
# build fails with a message that has the given pattern.
expect_failure() {
  local name="$1" pattern="$2"
  if NIX_JP_SRC="$work/$name" nix build --impure --no-link --expr "
    let
      f = builtins.getFlake \"git+file://$repo\";
      pkgs = import f.inputs.nixpkgs {
        system = builtins.currentSystem;
        overlays = [ f.overlays.default ];
      };
    in
    (pkgs.julia-purifier.buildJuliaProject {
      src = /. + builtins.getEnv \"NIX_JP_SRC\";
    }).depot
  " 2> "$work/$name.log"; then
    echo "$name: the build succeeded" >&2
    exit 1
  fi
  grep -q "$pattern" "$work/$name.log" || {
    echo "$name: the error does not mention '$pattern':" >&2
    cat "$work/$name.log" >&2
    exit 1
  }
}

step_damaged() {
  edit_lock() {
    nix shell 'nixpkgs#julia_113-bin' -c julia --startup-file=no "$repo/tests/edit-lock.jl" \
      "$work/$1/julia-purifier.lock.json" "$work/$1/Manifest.toml" "$2" "$3"
  }
  # A tampered hash with a correct content hash: the fetch of that tarball
  # fails.
  fixture app tampered
  edit_lock tampered tamper JSON
  expect_failure tampered "hash mismatch"
  # An edit without the lock run: the content hash no longer matches.
  fixture app edited
  sed -i.orig 's/"server": "https/"server": "http/' "$work/edited/julia-purifier.lock.json"
  rm "$work/edited/julia-purifier.lock.json.orig"
  expect_failure edited "does not match the hash of its own content"
  # A missing entry: the manifest pins JSON, and the lockfile has no hash
  # for it.
  fixture app missing
  edit_lock missing drop JSON
  expect_failure missing "has no hash for JSON"
  # A truncated lockfile.
  fixture app malformed
  head -c 200 "$repo/tests/fixtures/app/julia-purifier.lock.json" > "$work/malformed/julia-purifier.lock.json"
  expect_failure malformed "julia-purifier lock"
  # A stale lockfile, found at evaluation.
  fixture app stale
  printf '\n# an edit\n' >> "$work/stale/Project.toml"
  expect_failure stale "julia-purifier lock"
}

step_prefetch() {
  fixture app prefetch
  cd "$work/prefetch"
  "$cli" prefetch
  root="$(readlink .julia-purifier/prefetch)"
  case "$root" in
    /nix/store/*) ;;
    *)
      echo "prefetch left no GC root: $root" >&2
      exit 1
      ;;
  esac
  body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
  # The server stops when its input closes, so the input stays open for
  # a minute after the request, which is long enough for the reply.
  { printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body"; sleep 60; } \
    | nix shell 'nixpkgs#coreutils' -c timeout 900 "$cli" language-server > "$work/lsp.out" 2> "$work/lsp.err" || true
  grep -q '"capabilities"' "$work/lsp.out" || {
    echo "the language server did not answer initialize:" >&2
    cat "$work/lsp.err" >&2
    exit 1
  }
  cd "$work"
}

step_external() {
  mkdir -p "$work/external"
  fixture app external/app
  mv "$work/external/app/julia-purifier.lock.json" "$work/external/julia-purifier.lock.json"
  # The Manifest.toml of the tree stays as it is, and the one outside the
  # tree starts as a copy of it.
  "$cli" lock --lockfile "$work/external/julia-purifier.lock.json" \
    --tool-lockfile "$work/external/Manifest.toml" "$work/external/app"
  cmp "$repo/tests/fixtures/app/julia-purifier.lock.json" "$work/external/julia-purifier.lock.json"
  cmp "$repo/tests/fixtures/app/Manifest.toml" "$work/external/app/Manifest.toml"
  cmp "$repo/tests/fixtures/app/Manifest.toml" "$work/external/Manifest.toml"
  cd "$work/external/app"
  out="$(JULIA_PURIFIER_LOCKFILE="$work/external/julia-purifier.lock.json" \
    JULIA_PURIFIER_TOOL_LOCKFILE="$work/external/Manifest.toml" \
    "$cli" julia -e 'using HelloPurifier; print(HelloPurifier.greeting("ext"))')"
  [ "$out" = '{"greeting":"Hello, ext","utf16le":6}' ] || {
    echo "unexpected output: $out" >&2
    exit 1
  }
  [ -L "$work/external/.julia-purifier/prefetch" ]
  cd "$work"
}

step_publish() {
  fixture app publish
  cd "$work/publish"
  git init -q
  git add -A
  git commit -q -m "HelloPurifier 0.1.0"
  # LocalRegistry records the package's repository from its remote.
  git init -q --bare "$work/app.git"
  git remote add origin "file://$work/app.git"
  git push -q origin main
  git init -q --bare "$work/registry.git"
  JULIA_DEPOT_PATH="$work/registry-depot:" nix shell 'nixpkgs#julia_113-bin' -c \
    julia --startup-file=no "$repo/tests/create-registry.jl" "$work/registry" "file://$work/registry.git"
  "$cli" publish "file://$work/registry.git" --push "$work/publish"
  git clone -q "file://$work/registry.git" "$work/registry-check"
  tree="$(git -C "$work/publish" rev-parse 'HEAD^{tree}')"
  grep -q "git-tree-sha1 = \"$tree\"" "$work/registry-check/H/HelloPurifier/Versions.toml"
  cd "$work"
}

for s in "${steps[@]}"; do
  echo "== $s"
  "step_$s"
done
echo "julia-purifier command tests passed: ${steps[*]}"
