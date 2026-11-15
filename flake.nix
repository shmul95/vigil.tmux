{
  description = "Vigil - tmux attention router for Claude Code sessions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.bash
              pkgs.jq
              pkgs.util-linux
              pkgs.bats
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.tmux
            ];
          };
        }
      );
    };
}
