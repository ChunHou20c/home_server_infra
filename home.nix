{ pkgs, config, ... }:
let
  vaultwardenBackup = pkgs.writeShellScriptBin "vaultwarden-backup" ''
    set -euo pipefail

    DATA_DIR="$HOME/.local/share/vaultwarden"
    BACKUP_DIR="$HOME/backups/vaultwarden"
    DATE=$(date +%Y-%m-%d_%H-%M-%S)

    DB="$DATA_DIR/db.sqlite3"
    OUT_DB="$BACKUP_DIR/$DATE/db.sqlite3"
    RSA_KEY="$DATA_DIR/rsa_key.pem"

    mkdir -p "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR/$DATE"

    echo "[backup] creating sqlite snapshot..."

    # Safe online backup (NO downtime)
    ${pkgs.sqlite}/bin/sqlite3 "$DB" ".backup '$OUT_DB'"

    echo "[backup] copying encryption key..."
    cp "$RSA_KEY" "$BACKUP_DIR/$DATE/rsa_key.pem"

    echo "[backup] compressing..."
    tar czf "$BACKUP_DIR/vaultwarden_$DATE.tar.gz" \
      -C "$BACKUP_DIR/$DATE" \
      "db.sqlite3" \
      "rsa_key.pem"

    # cleanup intermediate files
    rm "$BACKUP_DIR/$DATE/db.sqlite3" "$BACKUP_DIR/$DATE/rsa_key.pem"

    echo "[backup] done: $DATE"
  '';
in
{
  home.username = "chunhou";
  home.homeDirectory = "/home/chunhou";

  home.stateVersion = "25.11";

  home.packages = [
    pkgs.git
    pkgs.curl
    pkgs.htop
    pkgs.sqlite

    pkgs.cloudflared
    pkgs.vaultwarden
    pkgs.vaultwarden-webvault

    vaultwardenBackup
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
	"WEB_VAULT_ENABLED=true"
	"WEB_VAULT_FOLDER=${pkgs.vaultwarden-webvault}/share/vaultwarden/vault"
      ];

      EnvironmentFile = "%h/.config/vaultwarden/env";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.vaultwarden-backup = {
    Unit = {
      Description = "Vaultwarden nightly backup";
    };

    Service = {
      Type = "oneshot";
      ExecStart = "%h/scripts/vaultwarden-backup.sh";
    };
  };

  systemd.user.timers.vaultwarden-backup = {
    Unit = {
      Description = "Run Vaultwarden backup daily at night";
    };

    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };

    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  programs.home-manager.enable = true;
}
