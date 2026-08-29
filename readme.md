# S&box nix dev environment

This flake pins [`joshuascript/sbox-public`](https://github.com/joshuascript/sbox-public),
provides its .NET 10/GCC/Python build toolchain, and puts `sbox-dev` on `PATH`.

## Usage

```bash
nix develop
sbox-dev
```

The build is split into independently pinned stages:

1. `sbox-build-tool` builds upstream's build driver from `deps.json`.
2. `sbox-artifacts` downloads the commit-compatible public artifacts into a
   fixed-output derivation. Its recursive hash prevents the server response from
   silently changing the build input.
3. `sbox-public` restores from `engine-deps.json`, patches script shebangs, and
   compiles the managed engine in Nix's network-isolated build sandbox.
4. `sbox-dev` is a small launcher around that completed store tree.

The repository remains a locked, non-flake input. Git history is reconstructed
only in the artifact stage because upstream uses it to find the nearest public
artifact manifest; `.git` is removed from that stage's output.

On first launch, `sbox-dev` copies that already-built store tree to a writable
directory and launches `game/bin/linuxsteamrt64/sbox-dev`; it does not build or
download the project at runtime.

Each pinned revision gets a checkout below `$XDG_CACHE_HOME/sbox-public` (or
`~/.cache/sbox-public`). Set `SBOX_PUBLIC_DIR` to use an exact directory.

You can also run the packaged command directly:

```bash
nix run .
```

Individual stages can be built for diagnosis or caching:

```bash
nix build .#sbox-build-tool
nix build .#sbox-artifacts
nix build .#sbox-public
```
