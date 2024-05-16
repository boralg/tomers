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

  outputs = { nixpkgs, crane, fenix, flake-utils, ... }: {
    libFor = system: targetPlatforms:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        mkPlatform =
          { system
          , arch
          , depsBuild ? [ ]
          , env ? { }
          , postInstall ? _: ""
          , buildFiles ? [ ]
          , resultFiles ? [ ]
          , isDefault ? false
          }: {
            name = arch;
            value = let pi = postInstall; in
              rec {
                inherit system;
                inherit arch;
                inherit depsBuild;
                inherit env;
                postInstall = crateName: if isDefault then "" else pi crateName;
                inherit buildFiles;
                inherit resultFiles;
                inherit isDefault;
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
            src = lib.cleanSourceWith {
              src = craneLib.path srcLocation;
              filter = path: type:
                (lib.foldl' (acc: p: acc || builtins.match ".*/${p}/.*" path != null) false targetPlatform.buildFiles)
                || (craneLib.filterCargoSources path type);
            };
            out = lib.cleanSourceWith {
              src = craneLib.path srcLocation;
              filter = path: type:
                (lib.foldl' (acc: p: acc || builtins.match "*/${p}/.*" path != null) false targetPlatform.resultFiles)
                || (craneLib.filterCargoSources path type);
            };

            package = craneLib.buildPackage {
              inherit src;

              strictDeps = true;
              doCheck = false;

              CARGO_BUILD_TARGET = targetPlatform.system;
              depsBuildBuild = targetPlatform.depsBuild;

              postInstall = targetPlatform.postInstall (craneLib.crateNameFromCargoToml { cargoToml = "${src}/Cargo.toml"; }).pname;
            };
          in
          pkgs.stdenv.mkDerivation
            {
              pname = "filtered-files";
              version = "1.0";

              src = out;

              buildInputs = [ pkgs.coreutils ];
              phases = [ "installPhase" ];

              installPhase = ''
                mkdir -p $out/bin

                cp -R ${package} $out

                for dir in ${lib.concatStringsSep " " targetPlatform.resultFiles}; do
                  cp -R ${out}/$dir $out/bin/$dir
                done
              '';
            };


        shellFor = srcLocation: targetPlatform:
          let
            craneLib = mkCraneLib targetPlatform;
          in
          craneLib.devShell ({
            CARGO_BUILD_TARGET = targetPlatform.system;
            depsBuildBuild = targetPlatform.depsBuild;
          });

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
