{
  description = "Tomers, a cross-platform Rust flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, crane, fenix, flake-utils, ... }:
    {
      libFor = system: targetPlatforms:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;

          mkPlatform = { system, arch, depsBuild ? [ ], env ? { }, postInstall ? _: "", fileFilter ? _: _: _: _: true, isDefault ? false }: {
            name = arch;
            value = let pi = postInstall; in
              rec {
                inherit system;
                inherit arch;
                inherit depsBuild;
                inherit env;
                inherit isDefault;
                inherit fileFilter;
                postInstall = crateName: if isDefault then "" else pi crateName;
              };
          };

          mkCraneLib = targetPlatform:
            let
              toolchain = with fenix.packages.${system};
                combine [
                  latest.rustc
                  latest.cargo
                  targets.${targetPlatform.system}.latest.rust-std
                ];
            in
            (crane.mkLib pkgs).overrideToolchain toolchain;

          crateFor = srcLocation: targetPlatform:
            let
              craneLib = mkCraneLib targetPlatform;
            in
            craneLib.buildPackage
              ({
                src = lib.cleanSourceWith {
                  src = craneLib.path srcLocation;
                  filter = path: type:
                    targetPlatform.fileFilter lib craneLib path type;
                };

                strictDeps = true;
                doCheck = false;

                CARGO_BUILD_TARGET = targetPlatform.system;
                depsBuildBuild = targetPlatform.depsBuild;

                postInstall = targetPlatform.postInstall (craneLib.crateNameFromCargoToml { cargoToml = "${srcLocation}/Cargo.toml"; }).pname;
              } // targetPlatform.env);

          shellFor = srcLocation: targetPlatform:
            let
              craneLib = mkCraneLib targetPlatform;
            in
            craneLib.devShell ({
              CARGO_BUILD_TARGET = targetPlatform.system;
              depsBuildBuild = targetPlatform.depsBuild;
            } // targetPlatform.env);

          eachPlatform = targetPlatforms: mkFor: pkgs.lib.attrsets.mapAttrs (name: platform: mkFor platform) targetPlatforms // {
            default = mkFor ((mkPlatform (targetPlatforms.${system} // { isDefault = true; })).value);
          };

          platforms = builtins.listToAttrs (map mkPlatform targetPlatforms);
        in
        rec {
          packagesForEachPlatform = srcLocation: eachPlatform platforms (crateFor srcLocation);
          devShellsForEachPlatform = srcLocation: eachPlatform platforms (shellFor srcLocation);
        };
    };
} 
 