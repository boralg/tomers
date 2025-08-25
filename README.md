# Tomers - Rust Cross-Compilation Flake

Tomers is a Nix flake, that, when imported, sets up the right cross-compilation toolchains, dev shells, and builds, based on a user-defined list of targeted platforms.

Builds can be defined both inside and outside the Nix store in the same platform definition.

It uses [Crane](https://crane.dev/) internally to support incremental recompilation.

## Examples
See https://github.com/boralg/sursface/blob/main/flake.nix for a WebGPU project compiled to various targets.