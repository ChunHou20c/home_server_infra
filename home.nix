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
    LOCAL_FILE="$BACKUP_DIR/vaultwarden_$DATE.tar.gz"

    mkdir -p "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR/$DATE"
    mkdir -p "$BACKUP_DIR/$DATE/attachments"

    echo "[backup] creating sqlite snapshot..."

    # Safe online backup (NO downtime)
    ${pkgs.sqlite}/bin/sqlite3 "$DB" ".backup '$OUT_DB'"

    echo "[backup] copying encryption key..."
    cp "$RSA_KEY" "$BACKUP_DIR/$DATE/rsa_key.pem"

    if [ -d "$DATA_DIR/attachments" ]; then
      echo "[backup] copying attachments directory..."
      cp -r "$DATA_DIR/attachments" "$BACKUP_DIR/$DATE/attachments"
    fi

    echo "[backup] compressing..."
    tar czf $LOCAL_FILE \
      -C "$BACKUP_DIR/$DATE" \
      "db.sqlite3" \
      "rsa_key.pem" \
      "attachments"

    # cleanup intermediate files
    rm -rf "$BACKUP_DIR/$DATE"

    echo "[backup] local backup done: $DATE"

    echo "Setting up environment variables for R2 CLI..."
    if [ -f "$HOME/.config/r2/env" ]; then
      source "$HOME/.config/r2/env"
    else
      echo "Missing R2 env file"
    exit 1
    fi

    echo "[backup] uploading to R2..."

    ${pkgs.awscli2}/bin/aws s3 cp \
      "$LOCAL_FILE" \
      "s3://$R2_BUCKET/vaultwarden/$DATE.tar.gz" \
      --endpoint-url "$R2_ENDPOINT"

    echo "[backup] remote backup done: $DATE"

    echo "[backup] cleaning local backups older than 7 days..."

    find "$BACKUP_DIR" \
      -type f \
      -name "vaultwarden_*.tar.gz" \
      -mtime +7 \
      -delete

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
    pkgs.awscli2

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
      ExecStart = "${vaultwardenBackup}/bin/vaultwarden-backup";
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
