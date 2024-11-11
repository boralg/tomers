{
  description = "Tomers, a cross-platform Rust flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, crane, fenix, ... }: {
    libFor = system: targetPlatforms:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        mkPlatform =
          { system
          , arch
          , depsBuild ? [ ]
          , env ? { }
          , postInstall ? _crateName: ""
          , buildFilePatterns ? [ ]
          , isDefault ? false
          , toolchainPackages ? _fenixPkgs: _crossFenixPkgs: [ ]
          }: {
            name = arch;
            value = let pi = postInstall; in
              rec {
                inherit system;
                inherit arch;
                inherit depsBuild;
                inherit env;
                postInstall = crateName: if isDefault then "" else pi crateName;
                inherit buildFilePatterns;
                inherit isDefault;
                inherit toolchainPackages;
              };
          };

        mkCraneLib = targetPlatform:
          let
            toolchain = with fenix.packages.${system};
              combine ([
                stable.rustc
                stable.cargo
                targets.${targetPlatform.system}.stable.rust-std
              ] ++ targetPlatform.toolchainPackages fenix.packages.${system} fenix.packages.${system}.targets.${targetPlatform.system});
          in
          (crane.mkLib pkgs).overrideToolchain toolchain;

        crateFor = srcLocation: targetPlatform:
          let
            craneLib = mkCraneLib targetPlatform;

            src = lib.cleanSourceWith {
              src = craneLib.path srcLocation;
              filter = path: type:
                (lib.foldl' (acc: p: acc || builtins.match p path != null) false targetPlatform.buildFilePatterns)
                || (craneLib.filterCargoSources path type);
            };
          in
          craneLib.buildPackage ({
            inherit src;

            strictDeps = true;
            doCheck = false;

            CARGO_BUILD_TARGET = targetPlatform.system;
            depsBuildBuild = targetPlatform.depsBuild;

            postInstall = targetPlatform.postInstall (craneLib.crateNameFromCargoToml { cargoToml = "${src}/Cargo.toml"; }).pname;
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
      {
        packagesForEachPlatform = srcLocation: eachPlatform platforms (crateFor srcLocation);
        devShellsForEachPlatform = srcLocation: eachPlatform platforms (shellFor srcLocation);
      };
  };
}
