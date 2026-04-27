# home_server_infra

Home-manager flake for a single-machine home lab. Manages user services, nightly backups, and a daily log-summary report.

## Services

| service              | purpose                       | port  |
|----------------------|-------------------------------|-------|
| cloudflared          | tunnel for public services    | —     |
| vaultwarden          | password manager              | 8222  |
| vikunja (+ postgres) | task manager                  | 3456 (pg 5433) |
| couchdb              | obsidian live sync            | 5984  |
| ollama               | local LLM (qwen2.5:1.5b)      | 11434 |

## Nightly schedule (server local time)

| time  | job                |
|-------|--------------------|
| 02:00 | vaultwarden-backup |
| 03:00 | vikunja-backup     |
| 04:00 | couchdb-backup     |
| 05:00 | log-summary        |

Backups upload a tarball to a Cloudflare R2 bucket and keep 7 days locally. log-summary writes a markdown report to `~/log-reports/` (30-day retention) and, if SMTP env is configured, emails an HTML version.

## Deploy

From your dev machine:

```
./scripts/deploy <ssh-host>
```

The script `git push`es, sshes to the host, `git pull`s in `~/infra`, then runs `home-manager switch --flake .#server`.

If you're already on the server:

```
cd ~/infra
git pull
nix run nixpkgs#home-manager -- switch --flake .#server
```

## First-time setup on a fresh server

1. Install Nix with flakes enabled (`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`).
2. Clone this repo to `~/infra`.
3. Create the env / config files listed below (mode `0600`). Services with `EnvironmentFile` will fail to start until those files exist.
4. Run the deploy command above.
5. Optional: `ollama pull qwen2.5:1.5b` (the log-summary script will pull it on first run otherwise).

### Env / config files

| path                            | used by                       | contents                                              |
|---------------------------------|-------------------------------|-------------------------------------------------------|
| `~/.config/cloudflared/env`     | cloudflared.service           | `TUNNEL_TOKEN=...`                                    |
| `~/.config/vaultwarden/env`     | vaultwarden.service           | vaultwarden secrets (e.g. `ADMIN_TOKEN`)              |
| `~/.config/vikunja/env`         | vikunja.service               | vikunja secrets (e.g. `VIKUNJA_DATABASE_PASSWORD`, `VIKUNJA_MAILER_PASSWORD`, `VIKUNJA_SERVICE_JWTSECRET`) |
| `~/.config/couchdb/admin.ini`   | couchdb.service               | `[admins]\nadmin = <password>\n`                      |
| `~/.config/couchdb/init.env`    | couchdb-bootstrap.service     | `COUCHDB_ADMIN_PASSWORD=...`<br>`OBSIDIAN_SYNC_INIT_PASSWORD=...` |
| `~/.config/r2/env`              | all three backup scripts      | `R2_BUCKET=...`<br>`R2_ENDPOINT=https://<acct>.r2.cloudflarestorage.com`<br>`AWS_ACCESS_KEY_ID=...`<br>`AWS_SECRET_ACCESS_KEY=...` |
| `~/.config/log-summary/env`     | log-summary (optional)        | `SMTP_USER=...`<br>`SMTP_PASS=...`<br>`MAIL_FROM=...`<br>`MAIL_TO=...` |

## Operations

```
# Live logs for a service
journalctl --user -u <name>.service -f

# Run a backup manually
vaultwarden-backup
vikunja-backup
couchdb-backup

# Trigger today's log summary on demand
systemctl --user start log-summary.service

# Inspect timer state (next/last fire)
systemctl --user list-timers
```

## Repo layout

```
flake.nix
home.nix              entry point — imports + common config
modules/
  cloudflared.nix
  vaultwarden.nix
  vikunja.nix
  couchdb.nix
  ollama.nix
  log-summary.nix
scripts/
  deploy              ssh + git pull + home-manager switch wrapper
```

To add a new service: create `modules/<name>.nix` with its `let`-bound helpers, packages, and systemd units, then add the path to the `imports` list in `home.nix`. New files must be `git add`ed before the flake will see them.
