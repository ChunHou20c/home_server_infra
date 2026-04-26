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

  couchdbBaseIni = pkgs.writeText "couchdb-local.ini" ''
    [chttpd]
    port = 5984
    bind_address = 127.0.0.1
    enable_cors = true
    max_http_request_size = 4294967296

    [chttpd_auth]
    require_valid_user = true

    [couchdb]
    single_node = true
    database_dir = ${config.home.homeDirectory}/.local/share/couchdb
    view_index_dir = ${config.home.homeDirectory}/.local/share/couchdb
    max_document_size = 50000000

    [cors]
    origins = app://obsidian.md,capacitor://localhost,http://localhost
    credentials = true
    methods = GET, PUT, POST, HEAD, DELETE
    headers = accept, authorization, content-type, origin, referer, x-csrf-token

    [log]
    level = warning
  '';

  couchdbInit = pkgs.writeShellScript "couchdb-init" ''
    set -euo pipefail

    ADMIN_INI="$HOME/.config/couchdb/admin.ini"

    if [ ! -f "$ADMIN_INI" ]; then
      echo "ERROR: $ADMIN_INI not found." >&2
      echo "Create it with an initial admin password before starting:" >&2
      echo "" >&2
      echo "  mkdir -p ~/.config/couchdb" >&2
      echo "  printf '[admins]\nadmin = <password>\n' > ~/.config/couchdb/admin.ini" >&2
      echo "  chmod 600 ~/.config/couchdb/admin.ini" >&2
      exit 1
    fi

    mkdir -p "$HOME/.local/share/couchdb"
  '';

  couchdbBackup = pkgs.writeShellScriptBin "couchdb-backup" ''
    set -euo pipefail

    BACKUP_DIR="$HOME/backups/couchdb"
    DATE=$(date +%Y-%m-%d_%H-%M-%S)

    LOCAL_FILE="$BACKUP_DIR/couchdb_$DATE.tar.gz"

    mkdir -p "$BACKUP_DIR"

    echo "[backup] stopping couchdb..."
    ${pkgs.systemd}/bin/systemctl --user stop couchdb.service

    # ensure couchdb restarts even if backup fails
    trap '${pkgs.systemd}/bin/systemctl --user start couchdb.service' EXIT

    echo "[backup] compressing..."
    tar czf "$LOCAL_FILE" \
      -C "$HOME" \
      ".local/share/couchdb" \
      ".config/couchdb/admin.ini"

    echo "[backup] restarting couchdb..."
    ${pkgs.systemd}/bin/systemctl --user start couchdb.service
    trap - EXIT

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
      "s3://$R2_BUCKET/couchdb/$DATE.tar.gz" \
      --endpoint-url "$R2_ENDPOINT"

    echo "[backup] remote backup done: $DATE"

    echo "[backup] cleaning local backups older than 7 days..."

    find "$BACKUP_DIR" \
      -type f \
      -name "couchdb_*.tar.gz" \
      -mtime +7 \
      -delete

    echo "[backup] done: $DATE"
  '';

  couchdbBootstrap = pkgs.writeShellScript "couchdb-bootstrap" ''
    set -euo pipefail

    ENV_FILE="$HOME/.config/couchdb/init.env"

    if [ ! -f "$ENV_FILE" ]; then
      echo "[bootstrap] $ENV_FILE not found, skipping (assumed already provisioned)"
      exit 0
    fi

    # shellcheck disable=SC1090
    source "$ENV_FILE"

    : "''${COUCHDB_ADMIN_PASSWORD:?COUCHDB_ADMIN_PASSWORD not set in init.env}"
    : "''${OBSIDIAN_SYNC_INIT_PASSWORD:?OBSIDIAN_SYNC_INIT_PASSWORD not set in init.env}"

    BASE="http://127.0.0.1:5984"
    AUTH=(-u "admin:$COUCHDB_ADMIN_PASSWORD")

    echo "[bootstrap] waiting for couchdb to be ready..."
    for _ in $(seq 1 30); do
      if ${pkgs.curl}/bin/curl -fsS "$BASE/_up" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    if ! ${pkgs.curl}/bin/curl -fsS "$BASE/_up" >/dev/null 2>&1; then
      echo "[bootstrap] couchdb not reachable on $BASE, aborting" >&2
      exit 1
    fi

    echo "[bootstrap] ensuring obsidian database exists..."
    STATUS=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
      "''${AUTH[@]}" -X PUT "$BASE/obsidian")
    case "$STATUS" in
      201|202) echo "[bootstrap] created obsidian database" ;;
      412)     echo "[bootstrap] obsidian database already exists" ;;
      *)       echo "[bootstrap] PUT /obsidian failed: HTTP $STATUS" >&2; exit 1 ;;
    esac

    echo "[bootstrap] ensuring obsidian-sync user exists..."
    STATUS=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
      "''${AUTH[@]}" -X PUT "$BASE/_users/org.couchdb.user:obsidian-sync" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"obsidian-sync\",\"password\":\"$OBSIDIAN_SYNC_INIT_PASSWORD\",\"roles\":[],\"type\":\"user\"}")
    case "$STATUS" in
      201|202) echo "[bootstrap] created obsidian-sync user" ;;
      409)     echo "[bootstrap] obsidian-sync user already exists (password preserved)" ;;
      *)       echo "[bootstrap] PUT _users failed: HTTP $STATUS" >&2; exit 1 ;;
    esac

    echo "[bootstrap] applying _security on obsidian..."
    ${pkgs.curl}/bin/curl -fsS "''${AUTH[@]}" -X PUT "$BASE/obsidian/_security" \
      -H "Content-Type: application/json" \
      -d '{"admins":{"names":[],"roles":[]},"members":{"names":["obsidian-sync"],"roles":[]}}' \
      >/dev/null
    echo "[bootstrap] _security applied"

    echo "[bootstrap] done"
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
    pkgs.couchdb3

    vaultwardenBackup
    vikunjaBackup
    couchdbBackup
  ];

  home.sessionVariables = {
    VAULTWARDEN_DATA_DIR = "${config.home.homeDirectory}/.local/share/vaultwarden";
    VIKUNJA_DATA_DIR = "${config.home.homeDirectory}/.local/share/vikunja";
    COUCHDB_DATA_DIR = "${config.home.homeDirectory}/.local/share/couchdb";
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

  systemd.user.services.couchdb = {
    Unit = {
      Description = "Apache CouchDB";
      After = [ "network.target" ];
    };

    Service = {
      ExecStartPre = "${couchdbInit}";
      ExecStart = "${pkgs.couchdb3}/bin/couchdb -couch_ini ${couchdbBaseIni} %h/.config/couchdb/admin.ini";
      Restart = "always";
      RestartSec = 5;
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.couchdb-bootstrap = {
    Unit = {
      Description = "CouchDB bootstrap (idempotent: obsidian DB, sync user, security)";
      After = [ "couchdb.service" ];
      Requires = [ "couchdb.service" ];
    };

    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${couchdbBootstrap}";
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

  systemd.user.services.couchdb-backup = {
    Unit = {
      Description = "CouchDB nightly backup";
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${couchdbBackup}/bin/couchdb-backup";
    };
  };

  systemd.user.timers.couchdb-backup = {
    Unit = {
      Description = "Run CouchDB backup daily at night";
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
