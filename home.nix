{ pkgs, ... }:
{
  imports = [
    ./modules/cloudflared.nix
    ./modules/vaultwarden.nix
    ./modules/vikunja.nix
    ./modules/couchdb.nix
    ./modules/ollama.nix
    ./modules/log-summary.nix
  ];

  home.username = "chunhou";
  home.homeDirectory = "/home/chunhou";

  home.stateVersion = "25.11";

  home.packages = [
    pkgs.git
    pkgs.curl
    pkgs.htop
    pkgs.sqlite
    pkgs.awscli2
  ];

  programs.home-manager.enable = true;
}
