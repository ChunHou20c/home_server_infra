{ pkgs, ... }:
{
  home.packages = [ pkgs.cloudflared ];

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
}
