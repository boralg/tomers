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
          , buildFiles ? _: craneLib: path: type: (craneLib.filterCargoSources path type)
          , resultFiles ? _: craneLib: path: type: false
          , isDefault ? false
          }: {
            name = arch;
            value =
              let
                pi = postInstall;
                bf = buildFiles;
                rf = resultFiles;
              in
              rec {
                inherit system;
                inherit arch;
                inherit depsBuild;
                inherit env;
                postInstall = crateName: if isDefault then "" else pi crateName;
                buildFiles = lib: craneLib: path: type: (bf lib craneLib path type) || (craneLib.filterCargoSources path type);
                resultFiles = lib: craneLib: path: type: rf lib craneLib path type;
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
            buildPath = srcLocation;

            filter = path: type: targetPlatform.resultFiles lib craneLib path type;
            
            filteredSrc = lib.cleanSourceWith {
              src = craneLib.path srcLocation;
              filter = path: type: targetPlatform.buildFiles lib craneLib path type && filter path type;
            };
            filteredResults = lib.cleanSourceWith {
              src = craneLib.path srcLocation;
              filter = path: type: targetPlatform.resultFiles lib craneLib path type;
            };

            filteredFilesList = builtins.filter (path: filter path "regular") (lib.attrNames (builtins.readDir (toString filteredSrc)));
          in
          (craneLib.buildPackage
            ({
              src = filteredSrc;

              strictDeps = true;
              doCheck = false;

              CARGO_BUILD_TARGET = targetPlatform.system;
              depsBuildBuild = targetPlatform.depsBuild;

              postInstall = targetPlatform.postInstall (craneLib.crateNameFromCargoToml { cargoToml = "${srcLocation}/Cargo.toml"; }).pname;

            })) // pkgs.stdenv.mkDerivation {
            pname = "filtered-files";
            version = "1.0";

            src = filteredSrc;
            _ = builtins.trace filteredSrc;

            buildInputs = [ pkgs.coreutils ];
            phases = [ "unpackPhase" "filterPhase" "installPhase" ];

            unpackPhase = ''
              runHook preUnpack
              sourceRoot=$(mktemp -d)
              cp -r ${filteredSrc}/* $sourceRoot
              runHook postUnpack
            '';

            filterPhase = ''
              echo "Contents of the source directory before filtering:"
              ls -R $sourceRoot

              mkdir -p $TMPDIR/filtered
              for file in ${lib.concatStringsSep " " filteredFilesList}; do
                cp --parents "$sourceRoot/$file" $TMPDIR/filtered
              done

              echo "Contents of the filtered directory after copying files:"
              ls -R $TMPDIR/filtered

              cp -r $TMPDIR/filtered/* .
              echo ${lib.concatStringsSep "\n" filteredFilesList} > files.txt
            '';

            installPhase = ''
              mkdir -p $out
              cp -r . $out/
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
