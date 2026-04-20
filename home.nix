{ pkgs, config, ... }:
let
  vikunjaPgInit = pkgs.writeShellScript "vikunja-pg-init" ''
    set -euo pipefail

    PGDATA="$HOME/.local/share/vikunja/postgres"

    if [ ! -s "$PGDATA/PG_VERSION" ]; then
      mkdir -p "$PGDATA"
      chmod 700 "$PGDATA"

      ${pkgs.postgresql}/bin/initdb \
        -D "$PGDATA" \
        --auth-local=trust \
        --auth-host=trust \
        --username=vikunja \
        --encoding=UTF8

      {
        echo "listen_addresses = 'localhost'"
        echo "port = 5433"
        echo "unix_socket_directories = '''"
      } >> "$PGDATA/postgresql.conf"

      echo "CREATE DATABASE vikunja OWNER vikunja;" | \
        ${pkgs.postgresql}/bin/postgres --single -D "$PGDATA" postgres
    fi
  '';

  vikunjaBackup = pkgs.writeShellScriptBin "vikunja-backup" ''
    set -euo pipefail

    DATA_DIR="$HOME/.local/share/vikunja"
    BACKUP_DIR="$HOME/backups/vikunja"
    DATE=$(date +%Y-%m-%d_%H-%M-%S)

    DUMP="$BACKUP_DIR/$DATE/vikunja.sql.gz"
    LOCAL_FILE="$BACKUP_DIR/vikunja_$DATE.tar.gz"

    mkdir -p "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR/$DATE"

    echo "[backup] dumping postgres database..."
    ${pkgs.postgresql}/bin/pg_dump \
      -h localhost \
      -p 5433 \
      -U vikunja \
      -d vikunja \
      --no-owner \
      --no-privileges \
      | ${pkgs.gzip}/bin/gzip > "$DUMP"

    if [ -d "$DATA_DIR/files" ]; then
      echo "[backup] copying files directory..."
      cp -r "$DATA_DIR/files" "$BACKUP_DIR/$DATE/files"
    fi

    echo "[backup] compressing..."
    tar czf $LOCAL_FILE \
      -C "$BACKUP_DIR/$DATE" \
      .

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
      "s3://$R2_BUCKET/vikunja/$DATE.tar.gz" \
      --endpoint-url "$R2_ENDPOINT"

    echo "[backup] remote backup done: $DATE"

    echo "[backup] cleaning local backups older than 7 days..."

    find "$BACKUP_DIR" \
      -type f \
      -name "vikunja_*.tar.gz" \
      -mtime +7 \
      -delete

    echo "[backup] done: $DATE"
  '';

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
    pkgs.vikunja
    pkgs.postgresql

    vaultwardenBackup
    vikunjaBackup
  ];

  home.sessionVariables = {
    VAULTWARDEN_DATA_DIR = "${config.home.homeDirectory}/.local/share/vaultwarden";
    VIKUNJA_DATA_DIR = "${config.home.homeDirectory}/.local/share/vikunja";
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

  systemd.user.services.vikunja-postgres = {
    Unit = {
      Description = "PostgreSQL instance for Vikunja";
      After = [ "network.target" ];
    };

    Service = {
      Type = "notify";
      ExecStartPre = "${vikunjaPgInit}";
      ExecStart = "${pkgs.postgresql}/bin/postgres -D %h/.local/share/vikunja/postgres";
      Restart = "always";
      RestartSec = 5;
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.vikunja = {
    Unit = {
      Description = "Vikunja Task Manager";
      After = [ "network.target" "vikunja-postgres.service" ];
      Requires = [ "vikunja-postgres.service" ];
    };

    Service = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/.local/share/vikunja/files";
      ExecStart = "${pkgs.vikunja}/bin/vikunja";
      Restart = "always";

      Environment = [
	"VIKUNJA_DATABASE_TYPE=postgres"
	"VIKUNJA_DATABASE_HOST=localhost:5433"
	"VIKUNJA_DATABASE_USER=vikunja"
	"VIKUNJA_DATABASE_DATABASE=vikunja"
	"VIKUNJA_DATABASE_SSLMODE=disable"

	"VIKUNJA_SERVICE_ROOTPATH=%h/.local/share/vikunja"
	"VIKUNJA_FILES_BASEPATH=%h/.local/share/vikunja/files"

	"VIKUNJA_SERVICE_INTERFACE=127.0.0.1:3456"
	"VIKUNJA_SERVICE_PUBLICURL=https://vikunja.chunhou20c.dev"
	"VIKUNJA_SERVICE_ENABLEREGISTRATION=false"
      ];

      EnvironmentFile = "%h/.config/vikunja/env";
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

  systemd.user.services.vikunja-backup = {
    Unit = {
      Description = "Vikunja nightly backup";
      After = [ "vikunja-postgres.service" ];
      Requires = [ "vikunja-postgres.service" ];
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${vikunjaBackup}/bin/vikunja-backup";
    };
  };

  systemd.user.timers.vikunja-backup = {
    Unit = {
      Description = "Run Vikunja backup daily at night";
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
