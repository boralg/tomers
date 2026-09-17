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

  outputs =
    {
      nixpkgs,
      crane,
      fenix,
      ...
    }:
    {
      libFor =
        system: targetPlatforms:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;

          mkPlatform =
            {
              system,
              arch,
              depsBuild ? [ ],
              targetLibs ? [ ],
              env ? { },
              postInstall ? (_crateName: ""),
              postInstallNixStore ? (_crateName: ""),
              buildFilePatterns ? [ ],
              isDefault ? false,
              toolchainPackages,
            }:
            let
              pi = postInstall;
              pins = postInstallNixStore;
            in
            rec {
              inherit system;
              inherit arch;
              inherit depsBuild;
              inherit targetLibs;
              inherit env;
              postInstall = if isDefault then pins else pi;
              inherit buildFilePatterns;
              inherit isDefault;
              inherit toolchainPackages;
            };

          mkCraneLib =
            targetPlatform:
            let
              fenixPkgs = fenix.packages.${system};
              crossFenixPkgs = fenixPkgs.targets.${targetPlatform.system};

              targetSupport =
                [ crossFenixPkgs.stable.rust-std ]
                ++ lib.optional (lib.hasSuffix "-windows-gnu" targetPlatform.system)
                  crossFenixPkgs.stable.rust-mingw;

              toolchain = fenixPkgs.combine (
                lib.unique (targetPlatform.toolchainPackages fenixPkgs crossFenixPkgs ++ targetSupport)
              );
            in
            (crane.mkLib pkgs).overrideToolchain toolchain;

          targetLibFlagsOf =
            targetPlatform:
            lib.concatStringsSep " " (map (drv: "-L native=${drv}/lib") targetPlatform.targetLibs);

          envOf =
            targetPlatform:
            if builtins.isFunction targetPlatform.env then
              targetPlatform.env { targetLibFlags = targetLibFlagsOf targetPlatform; }
            else
              targetPlatform.env;

          targetLibFlagsFor =
            targetPlatform:
            let
              triple = lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] targetPlatform.system);
              varName = "CARGO_TARGET_${triple}_RUSTFLAGS";
              flags = targetLibFlagsOf targetPlatform;
              env = envOf targetPlatform;

              # hasInfix rejects needles with store refs in them
              needle = builtins.unsafeDiscardStringContext flags;
              clobbering = lib.filter (
                name: env ? ${name} && !(lib.hasInfix needle (toString env.${name}))
              ) [ "CARGO_ENCODED_RUSTFLAGS" "RUSTFLAGS" varName ];
            in
            lib.optionalAttrs (targetPlatform.targetLibs != [ ]) (
              if clobbering != [ ] then
                throw ''
                  tomers: platform ${targetPlatform.system} sets ${lib.concatStringsSep ", " clobbering} in `env`,
                  replacing the linker search paths implicitly derived from targetLibs.

                  Either extend them rather than replacing:

                    env = { targetLibFlags }: {
                      RUSTFLAGS = "<your flags> ''${targetLibFlags}";
                    };

                  or move the libraries those flags point at into targetLibs.
                ''
              else
                { "${varName}" = flags; }
            );

          crateFor =
            srcLocation: targetPlatform:
            let
              craneLib = mkCraneLib targetPlatform;

              src = lib.cleanSourceWith {
                src = craneLib.path srcLocation;
                filter =
                  path: type:
                  (lib.foldl' (acc: p: acc || builtins.match p path != null) false targetPlatform.buildFilePatterns)
                  || (craneLib.filterCargoSources path type);
              };

              # crane defaults srcForRemapPathPrefix to `src` (which includes .rs files),
              # making buildDepsOnly rebuild on every source edit. A manifest-only source
              # is stable across .rs changes.
              manifestSrc = lib.cleanSourceWith {
                src = craneLib.path srcLocation;
                filter =
                  path: type:
                  lib.elem (baseNameOf path) [
                    "Cargo.toml"
                    "Cargo.lock"
                  ]
                  || type == "directory";
              };

              cargoArtifacts = craneLib.buildDepsOnly (
                {
                  inherit src;
                  srcForRemapPathPrefix = manifestSrc;

                  strictDeps = true;
                  doCheck = false;

                  CARGO_BUILD_TARGET = targetPlatform.system;
                  depsBuildBuild = targetPlatform.depsBuild;
                }
                // targetLibFlagsFor targetPlatform
                // envOf targetPlatform
              );
            in
            craneLib.buildPackage (
              {
                inherit src cargoArtifacts;
                srcForRemapPathPrefix = manifestSrc;

                strictDeps = true;
                doCheck = false;

                CARGO_BUILD_TARGET = targetPlatform.system;
                depsBuildBuild = targetPlatform.depsBuild;

                postInstall =
                  targetPlatform.postInstall
                    (craneLib.crateNameFromCargoToml { cargoToml = "${src}/Cargo.toml"; }).pname;
              }
              // targetLibFlagsFor targetPlatform
              // envOf targetPlatform
            );

          shellFor =
            srcLocation: targetPlatform:
            let
              craneLib = mkCraneLib targetPlatform;
            in
            craneLib.devShell (
              {
                CARGO_BUILD_TARGET = targetPlatform.system;
                depsBuildBuild = targetPlatform.depsBuild;
              }
              // targetLibFlagsFor targetPlatform
              // envOf targetPlatform
            );

          eachPlatform =
            targetPlatforms: mkFor:
            pkgs.lib.attrsets.mapAttrs (_name: platform: mkFor (mkPlatform platform)) targetPlatforms
            // {
              default = mkFor (mkPlatform (targetPlatforms.${system} // { isDefault = true; }));
            };

          platforms = builtins.listToAttrs (
            map (e: {
              name = e.arch;
              value = e;
            }) targetPlatforms
          );
        in
        {
          packagesForEachPlatform = srcLocation: eachPlatform platforms (crateFor srcLocation);
          devShellsForEachPlatform = srcLocation: eachPlatform platforms (shellFor srcLocation);
        };
    };
}
