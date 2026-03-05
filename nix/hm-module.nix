{ config, lib, pkgs, ... }:

let
  cfg = config.services.tidepool;
in {
  options.services.tidepool = {
    enable = lib.mkEnableOption "Tidepool window manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tidepool;
      defaultText = lib.literalExpression "pkgs.tidepool";
      description = "The tidepool package to use.";
    };

    wallpaper = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to wallpaper image. Tidepool renders it directly on the background surface.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.tidepool = {
      Unit = {
        Description = "Tidepool window manager";
        PartOf = ["graphical-session.target"];
      };
      Service = {
        ExecStart = lib.getExe cfg.package;
        ExecStop = pkgs.writeShellScript "tidepool-save" ''
          ${lib.getExe' cfg.package "tidepoolmsg"} save > "$XDG_RUNTIME_DIR/tidepool-state.jdn"
        '';
        ExecStartPost = pkgs.writeShellScript "tidepool-load" ''
          if [ -f "$XDG_RUNTIME_DIR/tidepool-state.jdn" ]; then
            ${lib.getExe' cfg.package "tidepoolmsg"} load < "$XDG_RUNTIME_DIR/tidepool-state.jdn"
            rm -f "$XDG_RUNTIME_DIR/tidepool-state.jdn"
          fi
        '';
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
