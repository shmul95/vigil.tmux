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
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.tmuxPlugins.mkTmuxPlugin {
            pluginName = "vigil";
            version = self.rev or "dev";
            src = self;
            dontCheckForBrokenSymlinks = true;
          };
        }
      );

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
              pkgs.gh
            ];
          };
        }
      );

      homeManagerModules.default = import ./home-manager.nix { inherit self; };
    };
}
