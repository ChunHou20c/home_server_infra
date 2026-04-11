{ pkgs, ... }:

{
  home.username = "chunhou";
  home.homeDirectory = "/home/chunhou";

  home.stateVersion = "25.11";

  home.packages = [
    pkgs.git
    pkgs.curl
    pkgs.htop

    pkgs.cloudflared
  ];

  systemd.user.services.cloudflared = {
    Unit = {
      Description = "Cloudflare Tunnel";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel run --token YOUR_TOKEN";
      Restart = "always";
      RestartSec = 5;
      Environment = "TUNNEL_TOKEN=your_token_here";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  programs.home-manager.enable = true;
}
