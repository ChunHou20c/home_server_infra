{ pkgs, config, ... }:

{
  home.username = "chunhou";
  home.homeDirectory = "/home/chunhou";

  home.stateVersion = "25.11";

  home.packages = [
    pkgs.git
    pkgs.curl
    pkgs.htop

    pkgs.cloudflared
    pkgs.vaultwarden
  ];

  home.sessionVariables = {
    VAULTWARDEN_DATA_DIR = "${config.home.homeDirectory}/.local/share/vaultwarden";
  };

  systemd.user.services.cloudflared = {
    Unit = {
      Description = "Cloudflare Tunnel";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel run --token $TUNNEL_TOKEN";
      Restart = "always";
      RestartSec = 5;
      EnvironmentFile = "%h/.config/cloudflared/env";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.vaultwarden = {
    Unit = {
      Description = "Vaultwarden Password Manager";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${pkgs.vaultwarden}/bin/vaultwarden";
      Restart = "always";

      Environment = [
	"DATA_FOLDER=%h/.local/share/vaultwarden"
	"ROCKET_PORT=8222"
	"ROCKET_ADDRESS=127.0.0.1"

	"SIGNUPS_ALLOWED=false"
	"WEBSOCKET_ENABLED=true"
	"WEB_VAULT_ENABLED=false"
      ];

      EnvironmentFile = "%h/.config/vaultwarden/env";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  programs.home-manager.enable = true;
}
