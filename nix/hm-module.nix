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
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
