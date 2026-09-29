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
    in {
      packages = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          spool = pkgs.haskell.lib.justStaticExecutables (
            pkgs.haskellPackages.callCabal2nix "spool" ./. { }
          );
        in {
          inherit spool;
          default = spool;
        }
      );

      checks = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          spool = self.packages.${system}.spool;
        in {
          spool-version = pkgs.runCommand "spool-version" {
            nativeBuildInputs = [ pkgs.coreutils ];
          } ''
            test -x ${spool}/bin/spool
            test "$(${spool}/bin/spool --version)" = "spool 0.0.1"
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
