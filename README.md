# debuginfod-zig

`debuginfod-zig` is a lightweight, portable alternative to GNU's `debuginfod`, compatible with GNU debuginfod version 0.194.

## Why?

While GNU `debuginfod` works well only on Linux, it comes with several limitations that make it less practical in other environments or for static builds.

| Problem with GNU `debuginfod` | How `debuginfod-zig` solves it                                                                      |
|-------------------------------|-----------------------------------------------------------------------------------------------------|
| ❌ **No static builds** – cannot be compiled statically. | ✅ **Supports static builds** – fully self-contained binary.                                         |
| ❌ **Heavy dependency chain** – depends on `libcurl`, `sqlite`, `libelf`, and many others. | ✅ **No external dependencies** – written in pure **Zig**, minimal footprint.                        |
| ❌ **Linux-only** – cannot be built or used on macOS. | ✅ **Cross-platform** – works on **Linux** and **macOS**.                                            |
| ❌ **Broken source path handling** – only supports absolute paths (`/path/to/file.c`). | ✅ **Flexible source resolution** – supports both relative (`./build/../file.c`) and absolute paths. |
| ❌ **Written in C** – complex dependency management and less safe by design. | ✅ **Implemented in Zig** – safer, simpler, and easier to maintain.                                  |


## Build
```
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe -Dlinkage=dynamic
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe -Dlinkage=dynamic

zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe -Dlinkage=dynamic
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe -Dlinkage=dynamic
```

`zig build` also produces `zig-out/bin/debuginfod-find`, a CLI with the same command line as
elfutils' `debuginfod-find` (built directly on `src/client.zig`, no C ABI involved):
```
export DEBUGINFOD_URLS="https://debuginfod.debian.net"   # optional, defaults to https://debuginfod.pwndbg.re
debuginfod-find debuginfo bea6a154d9a9158114ee0a2a439045596615df14   # by hex build-id
debuginfod-find executable /usr/bin/bash                             # by ELF path (build-id read from the .note.gnu.build-id)
debuginfod-find source bea6a154d9a9158114ee0a2a439045596615df14 /usr/src/debug/bash/shell.c
debuginfod-find section /usr/bin/bash .text
debuginfod-find -v debuginfo ...                                     # log + download progress on stderr

# from the source tree:
zig build run -- debuginfo bea6a154d9a9158114ee0a2a439045596615df14
```
On success the path of the cached file is printed on stdout (exit 0); otherwise
`Server query failed: ...` goes to stderr (exit 1). `metadata` queries are not implemented.

## How to replace GDB debuginfod with this repo?
```
nix build github:pwndbg/debuginfod-zig#dynamic
cp ./result/lib/libdebuginfod.so /usr/lib64/libdebuginfod.so.1

# OR use env `LD_PRELOAD`
LD_PRELOAD=./result/lib/libdebuginfod.so /usr/bin/gdb
```
> NOTE1: `/usr/lib64/libdebuginfod.so.1` path depends on your distribution

## ENV's implemented:
- DEBUGINFOD_URLS
- DEBUGINFOD_CACHE_PATH
- DEBUGINFOD_MAXTIME
- DEBUGINFOD_MAXSIZE
- DEBUGINFOD_VERBOSE
- DEBUGINFOD_PROGRESS
- DEBUGINFOD_HEADERS_FILE
- DEBUGINFOD_TIMEOUT
- http_proxy / https_proxy (also all_proxy)

## ENV's not-implemented:
- DEBUGINFOD_IMA_CERT_PATH (hard?)
- DEBUGINFOD_RETRY_LIMIT
- no_proxy (proxy bypass list)

## Caching:
- positive results cached under `<cache>/<buildid>/<kind>` (tmp file + atomic rename)
- negative (404/501) results cached as a 0-byte marker file, re-queried after `cache_miss_s`
  seconds (default 600, read from `<cache>/cache_miss_s` if present) — like GNU debuginfod
- `find_source` extra short-circuits (no per-file network query): if `debuginfo` for the
  build-id is negatively cached (no debuginfo ⇒ no source), or a `501` marked the build-id's
  source unsupported (`<cache>/<buildid>/source-unsupported`)

## What is missing:
- missing func debuginfod_find_metadata
- auto-cleanup old debuginfo files (`max_unused_age_s`, `cache_clean_interval_s`)
- ima policies/verification
- caching headers as file `/hdr-debuginfo`


## `flake.nix` example usage:
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    debuginfod-zig.url = "github:pwndbg/debuginfod-zig";
  };
  outputs =
    inputs@{
      self,
      nixpkgs,
      debuginfod-zig,
      ...
    }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
      fun_pkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            debuginfod-zig.overlays.default
            (final: prev: {
              gdb-with-debuginfod = (prev.gdb.override { enableDebuginfod = false; }).overrideAttrs( old: {
                 buildInputs = (old.buildInputs or []) ++ [
                    prev.libdebuginfod-zig-static
                 ];
                 configureFlags = (old.configureFlags or []) ++ [
                    "--with-debuginfod=yes"
                 ];
              });
            })
          ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = (fun_pkgs system);
        in
        {
          gdb-with-debuginfod = pkgs.gdb-with-debuginfod;
        }
      );
    };
}
```
