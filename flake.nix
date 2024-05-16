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
            value = rec {
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
                (lib.foldl' (acc: p: acc || lib.hasPrefix "${p}/" path) false targetPlatform.buildFiles)
                || (craneLib.filterCargoSources path type);
            };
          in
          (craneLib.buildPackage {
            inherit src;

            strictDeps = true;
            doCheck = false;

            CARGO_BUILD_TARGET = targetPlatform.system;
            depsBuildBuild = targetPlatform.depsBuild;

            postInstall = targetPlatform.postInstall (craneLib.crateNameFromCargoToml { cargoToml = "${srcLocation}/Cargo.toml"; }).pname;
          }) // pkgs.stdenv.mkDerivation {
            pname = "filtered-files";
            version = "1.0";

            src = filteredResults;

            buildInputs = [ pkgs.coreutils ];
            phases = [ "installPhase" ];

            installPhase = ''
              mkdir -p $out/bin
              ls ${filteredResults}
              echo oye ${filteredResults}
              cp -R ${filteredResults} $out/bin
            '';

            # installPhase = ''
            #   runHook preInstall

            #   echo "Copying contents of filteredResults to $out"
            #   mkdir -p $out

            #   for file in $(find ${filteredResults} -type f); do
            #     mkdir -p $out/$(dirname $\{file#${filteredResults}})
            #     cp $file $out/$(dirname $\{file#${filteredResults}})
            #   done

            #   echo "Contents of the output directory after installation:"
            #   ls -R $out

            #   runHook postInstall
            # '';
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
