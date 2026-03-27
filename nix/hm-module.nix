{
  config,
  lib,
  pkgs,
  ...
}: let
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
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    systemd.user.services.tidepool = {
      Unit = {
        Description = "Tidepool window manager";
        PartOf = ["graphical-session.target"];
      };
      Service = {
        ExecStart = lib.getExe cfg.package;
        ExecStop = pkgs.writeShellScript "tidepool-stop" ''
          timeout 5 ${lib.getExe' cfg.package "tidepoolmsg"} save > "$XDG_RUNTIME_DIR/tidepool-state.jdn" || true
          kill -TERM "$MAINPID"
        '';
        ExecStartPost = pkgs.writeShellScript "tidepool-load" ''
          if [ -f "$XDG_RUNTIME_DIR/tidepool-state.jdn" ]; then
            for i in $(seq 1 10); do
              ${lib.getExe' cfg.package "tidepoolmsg"} load < "$XDG_RUNTIME_DIR/tidepool-state.jdn" && break
              sleep 0.2
            done
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
