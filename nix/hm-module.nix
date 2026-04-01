{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.tidepool;

  modifierMap = {
    super = "mod4";
    shift = "shift";
    ctrl = "ctrl";
    control = "ctrl";
    alt = "mod1";
    mod1 = "mod1";
    mod4 = "mod4";
  };

  parseKey = key: let
    parts = lib.splitString "+" key;
    keysym = lib.last parts;
    mods = lib.init parts;
    modEntries = map (m: ":${modifierMap.${lib.toLower m}} true") mods;
    modsJanet =
      if mods == []
      then "{}"
      else "{${lib.concatStringsSep " " modEntries}}";
  in {
    inherit keysym modsJanet;
  };

  keybindingToJanet = key: action: let
    parsed = parseKey key;
  in "[:${parsed.keysym} ${parsed.modsJanet} ${action}]";

  keybindLines = lib.mapAttrsToList keybindingToJanet cfg.keybindings;

  outputOrderEntry = entry:
    "{:name ${builtins.toJSON entry.name}${lib.optionalString (entry.tag != null) " :tag ${toString entry.tag}"}}";

  hasConfig = cfg.keybindings != {} || cfg.outputOrder != [] || cfg.extraConfig != "";

  initJanet = pkgs.writeText "tidepool-init.janet" (lib.concatStringsSep "\n" (lib.filter (s: s != "") [
    "(def config (ctx :config))"
    (lib.optionalString (cfg.keybindings != {}) ''

      (put config :xkb-bindings
        @[${lib.concatStringsSep "\n    " keybindLines}])'')
    (lib.optionalString (cfg.outputOrder != []) ''

      (put config :output-order
        @[${lib.concatStringsSep "\n    " (map outputOrderEntry cfg.outputOrder)}])'')
    (lib.optionalString (cfg.extraConfig != "") "\n${cfg.extraConfig}")
  ]));
in {
  options.services.tidepool = {
    enable = lib.mkEnableOption "Tidepool window manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tidepool;
      defaultText = lib.literalExpression "pkgs.tidepool";
      description = "The tidepool package to use.";
    };

    keybindings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Keybindings as an attribute set mapping key combinations to Janet
        action expressions. Keys use `modifier+...+keysym` format.

        Modifiers: super, shift, ctrl, alt (or mod1, mod4).
        Keysyms: xkb names like Return, q, 1, space, etc.

        Values are Janet expressions that evaluate to action functions.
      '';
      example = lib.literalExpression ''
        {
          "super+Return" = '''(actions/spawn "foot")''';
          "super+shift+q" = "actions/close-focused";
          "super+j" = "actions/focus-next";
          "super+1" = "(actions/focus-tag 1)";
        }
      '';
    };

    outputOrder = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "wl_output name (e.g. DP-1, HDMI-A-1).";
          };
          tag = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Initial tag to assign to this output.";
          };
        };
      });
      default = [];
      description = ''
        Preferred output ordering, left to right. Each entry specifies a
        wl_output name and an optional initial tag. Outputs not listed
        sort after configured ones by compositor position.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional Janet code appended to init.janet.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    xdg.configFile."tidepool/init.janet" = lib.mkIf hasConfig {
      source = initJanet;
    };

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
