{ pkgs, config, ... }:
let
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
  home.packages = [
    pkgs.couchdb3
    couchdbBackup
  ];

  home.sessionVariables = {
    COUCHDB_DATA_DIR = "${config.home.homeDirectory}/.local/share/couchdb";
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
      OnCalendar = "04:00";
      Persistent = true;
    };

    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
