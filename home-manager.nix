{ self }:
{ config, lib, pkgs, options, ... }:
let
  inherit (lib) mkEnableOption mkIf mkAfter mkOption optionalAttrs types;
  cfg = config.programs."vigil-tmux";
in
{
  options.programs."vigil-tmux" = {
    enable = mkEnableOption "vigil.tmux tmux attention router";

    package = mkOption {
      type = types.package;
      default = pkgs.tmuxPlugins.mkTmuxPlugin {
        pluginName = "vigil";
        version = self.rev or "dev";
        src = self;
        dontCheckForBrokenSymlinks = true;
      };
      description = "The vigil.tmux plugin derivation injected into tshmux's extraConfig.";
    };
  };

  config = mkIf cfg.enable (optionalAttrs (options.programs ? tshmux) {
    programs.tshmux.extraConfig = mkAfter ''
      run-shell "${cfg.package}/share/tmux-plugins/vigil/vigil.tmux"
    '';
  });
}
