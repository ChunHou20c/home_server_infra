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
in
{
  home.packages = [
    pkgs.vikunja
    pkgs.postgresql
    vikunjaBackup
  ];

  home.sessionVariables = {
    VIKUNJA_DATA_DIR = "${config.home.homeDirectory}/.local/share/vikunja";
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

        "VIKUNJA_MAILER_ENABLED=true"
        "VIKUNJA_MAILER_HOST=smtp.protonmail.ch"
        "VIKUNJA_MAILER_PORT=587"
        "VIKUNJA_MAILER_USERNAME=llamma@chunhou20c.dev"
        "VIKUNJA_MAILER_FROMEMAIL=llamma@chunhou20c.dev"
        "VIKUNJA_MAILER_FORCESSL=false"
        "VIKUNJA_MAILER_SKIPTLSVERIFY=false"
      ];

      EnvironmentFile = "%h/.config/vikunja/env";
    };

    Install = {
      WantedBy = [ "default.target" ];
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
}
