# SPDX-FileCopyrightText: The Spool contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
{
  description = "Spool, a file-backed JSONL task spool";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
      # The library, the executable, and the Cabal test suite, which runs as
      # part of the build. Warnings are errors here and nowhere by default.
      #
      # nix/spool.nix is cabal2nix's reading of spool.cabal, committed rather
      # than generated while evaluating: a flake that generates it needs a
      # build during evaluation, and then nobody can evaluate this flake for
      # a system they cannot build for, such as a Linux host's configuration
      # from a Mac. The check below keeps the file current.
      package = pkgs: pkgs.haskell.lib.enableCabalFlag
        (pkgs.haskell.lib.overrideSrc
          (pkgs.haskellPackages.callPackage ./nix/spool.nix { })
          { src = ./.; })
        "werror";
    in {
      packages = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          spool = pkgs.haskell.lib.justStaticExecutables (package pkgs);
        in {
          inherit spool;
          default = spool;
        }
      );

      devShells = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.haskellPackages.shellFor {
            packages = _: [ (package pkgs) ];
            nativeBuildInputs = [ pkgs.cabal-install pkgs.jq ];
          };
        }
      );

      checks = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          spool = self.packages.${system}.spool;
        in {
          # nix/spool.nix must be what cabal2nix says of spool.cabal, or a
          # dependency added to one is missing from the other.
          spool-nix-current = pkgs.runCommand "spool-nix-current" {
            nativeBuildInputs = [ pkgs.cabal2nix pkgs.diffutils pkgs.gnused ];
          } ''
            cabal2nix ${./.} | sed 's|^  src = .*;$|  src = ./.;|' > "$TMPDIR/generated.nix"
            diff ${./nix/spool.nix} "$TMPDIR/generated.nix" \
              || { echo "nix/spool.nix is stale: run 'cabal2nix . > nix/spool.nix'" >&2; exit 1; }
            touch "$out"
          '';

          spool-version = pkgs.runCommand "spool-version" {
            nativeBuildInputs = [ pkgs.coreutils ];
          } ''
            test -x ${spool}/bin/spool
            test "$(${spool}/bin/spool --version)" = "spool 0.0.2"
            touch "$out"
          '';

          spool-tests = pkgs.runCommand "spool-tests" {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.gnused
              pkgs.jq
            ];
          } ''
            SPOOL=${spool}/bin/spool \
              ${pkgs.bash}/bin/bash ${./test.sh}
            touch "$out"
          '';
        }
      );
    };
}
