{ pkgs, ... }:
let
  logReportHtmlPrefix = pkgs.writeText "log-summary-prefix.html" ''
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="UTF-8">
    <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: #222; max-width: 720px; margin: 0 auto; padding: 16px; line-height: 1.5; }
    h1 { font-size: 20px; border-bottom: 1px solid #ddd; padding-bottom: 8px; margin-top: 0; }
    h2 { font-size: 16px; margin-top: 24px; color: #333; }
    h3 { font-size: 14px; color: #444; margin-top: 18px; margin-bottom: 4px; }
    table { border-collapse: collapse; margin: 12px 0; font-size: 14px; }
    th, td { padding: 6px 12px; border: 1px solid #ddd; text-align: left; }
    th { background: #f5f5f5; font-weight: 600; }
    td:nth-child(2), td:nth-child(3) { text-align: right; font-variant-numeric: tabular-nums; }
    ul { padding-left: 22px; margin: 6px 0; }
    li { margin: 2px 0; }
    p { margin: 6px 0; }
    code { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 13px; background: #f5f5f5; padding: 1px 5px; border-radius: 3px; }
    blockquote { border-left: 3px solid #fbc02d; background: #fff8e1; padding: 8px 14px; margin: 12px 0; color: #5d4037; }
    </style>
    </head>
    <body>
  '';

  logReportHtmlSuffix = pkgs.writeText "log-summary-suffix.html" ''
    </body>
    </html>
  '';

  logSummary = pkgs.writeShellScriptBin "log-summary" ''
    set -euo pipefail

    REPORT_DIR="$HOME/log-reports"
    DATE=$(${pkgs.coreutils}/bin/date +%Y-%m-%d)
    REPORT="$REPORT_DIR/$DATE.md"
    OLLAMA="http://127.0.0.1:11434/api/generate"
    MODEL="qwen2.5:1.5b"
    SERVICES=(vaultwarden vikunja vikunja-postgres couchdb cloudflared)

    ENV_FILE="$HOME/.config/log-summary/env"
    if [ -f "$ENV_FILE" ]; then
      # shellcheck disable=SC1090
      source "$ENV_FILE"
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$REPORT_DIR"

    if ! ${pkgs.ollama}/bin/ollama list 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "qwen2.5:1.5b"; then
      echo "[log-summary] pulling $MODEL..."
      ${pkgs.ollama}/bin/ollama pull "$MODEL"
    fi

    call_llm() {
      local prompt="$1"
      local keep_alive="''${2:-60s}"
      ${pkgs.jq}/bin/jq -n \
        --arg model "$MODEL" \
        --arg prompt "$prompt" \
        --arg ka "$keep_alive" \
        '{model: $model, prompt: $prompt, stream: false, keep_alive: $ka, options: {temperature: 0.2}}' \
      | ${pkgs.curl}/bin/curl -fsS "$OLLAMA" -H "Content-Type: application/json" -d @- \
      | ${pkgs.jq}/bin/jq -r '.response'
    }

    declare -A SUMMARIES
    declare -A WARN_COUNTS
    declare -A ERR_COUNTS
    TOTAL_ERR=0
    TOTAL_WARN=0

    for svc in "''${SERVICES[@]}"; do
      raw=$(${pkgs.systemd}/bin/journalctl --user -u "$svc.service" \
              --since "24 hours ago" -p warning -o short-iso \
              --no-pager 2>/dev/null || true)

      err=$(${pkgs.systemd}/bin/journalctl --user -u "$svc.service" \
              --since "24 hours ago" -p err..emerg -o cat \
              --no-pager 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
      warn=$(${pkgs.systemd}/bin/journalctl --user -u "$svc.service" \
               --since "24 hours ago" -p warning..warning -o cat \
               --no-pager 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)

      ERR_COUNTS[$svc]=$err
      WARN_COUNTS[$svc]=$warn
      TOTAL_ERR=$((TOTAL_ERR + err))
      TOTAL_WARN=$((TOTAL_WARN + warn))

      if [ -z "$raw" ]; then
        SUMMARIES[$svc]="No warnings or errors in the last 24 hours."
        continue
      fi

      digest=$(echo "$raw" | ${pkgs.coreutils}/bin/head -c 8000)

      prompt="You are summarizing 24 hours of journald logs for the systemd service '$svc' on a home server. Below are warning-or-higher entries (counts: $warn warnings, $err errors).

    LOGS:
    $digest

    Produce a terse summary in 3-6 short bullets. Group similar errors and give approximate counts. Do not speculate about causes. Do not invent details that are not in the logs. If the logs look benign, say so."

      SUMMARIES[$svc]=$(call_llm "$prompt" "60s")
    done

    {
      echo "# Home Lab Log Summary — $DATE"
      echo ""
      echo "Window: last 24 hours"
      echo ""
      echo "| service | warnings | errors |"
      echo "|---------|---------:|-------:|"
      for svc in "''${SERVICES[@]}"; do
        echo "| $svc | ''${WARN_COUNTS[$svc]} | ''${ERR_COUNTS[$svc]} |"
      done
      echo ""
      echo "## Per-service"
      for svc in "''${SERVICES[@]}"; do
        echo ""
        echo "### $svc"
        echo ""
        echo "''${SUMMARIES[$svc]}"
      done
    } > "$REPORT"

    if [ "$TOTAL_ERR" -gt 0 ]; then
      combined=""
      for svc in "''${SERVICES[@]}"; do
        if [ "''${ERR_COUNTS[$svc]}" -gt 0 ] || [ "''${WARN_COUNTS[$svc]}" -gt 0 ]; then
          combined+="[$svc] ''${SUMMARIES[$svc]}"$'\n\n'
        fi
      done

      headline_prompt="You are writing a 3-line TL;DR for a sysadmin who has 30 seconds. Below are per-service log summaries from the last 24 hours. Produce 3 lines max. Lead with the most important issue. No speculation.

    $combined"

      headline=$(call_llm "$headline_prompt" "0")

      {
        echo "# Home Lab Log Summary — $DATE"
        echo ""
        echo "## TL;DR"
        echo ""
        echo "$headline" | ${pkgs.gnused}/bin/sed 's/^/> /'
        ${pkgs.coreutils}/bin/tail -n +2 "$REPORT"
      } > "$REPORT.tmp" && ${pkgs.coreutils}/bin/mv "$REPORT.tmp" "$REPORT"
    else
      call_llm "ok" "0" >/dev/null 2>&1 || true
    fi

    ${pkgs.findutils}/bin/find "$REPORT_DIR" -name "*.md" -mtime +30 -delete

    echo "[log-summary] wrote $REPORT"

    if [ -n "''${MAIL_TO:-}" ] && [ -n "''${SMTP_USER:-}" ] && [ -n "''${SMTP_PASS:-}" ] && [ -n "''${MAIL_FROM:-}" ]; then
      SUBJECT="[home-lab] log summary $DATE — $TOTAL_ERR errors, $TOTAL_WARN warnings"
      RFC_DATE=$(${pkgs.coreutils}/bin/date -R)
      BOUNDARY="homelab-$(${pkgs.coreutils}/bin/date +%s)-$$"
      {
        echo "From: $MAIL_FROM"
        echo "To: $MAIL_TO"
        echo "Subject: $SUBJECT"
        echo "Date: $RFC_DATE"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/alternative; boundary=\"$BOUNDARY\""
        echo ""
        echo "--$BOUNDARY"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        ${pkgs.coreutils}/bin/cat "$REPORT"
        echo ""
        echo "--$BOUNDARY"
        echo "Content-Type: text/html; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        ${pkgs.coreutils}/bin/cat ${logReportHtmlPrefix}
        ${pkgs.cmark-gfm}/bin/cmark-gfm --extension table "$REPORT"
        ${pkgs.coreutils}/bin/cat ${logReportHtmlSuffix}
        echo ""
        echo "--$BOUNDARY--"
      } | ${pkgs.curl}/bin/curl --silent --show-error --ssl-reqd \
          --url "smtp://smtp.protonmail.ch:587" \
          --user "$SMTP_USER:$SMTP_PASS" \
          --mail-from "$MAIL_FROM" \
          --mail-rcpt "$MAIL_TO" \
          --upload-file -
      echo "[log-summary] sent email to $MAIL_TO"
    else
      echo "[log-summary] skipping email (env not configured at $ENV_FILE)"
    fi
  '';
in
{
  home.packages = [ logSummary ];

  systemd.user.services.log-summary = {
    Unit = {
      Description = "Daily log anomaly summary";
      After = [ "ollama.service" ];
      Requires = [ "ollama.service" ];
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${logSummary}/bin/log-summary";
    };
  };

  systemd.user.timers.log-summary = {
    Unit = {
      Description = "Run daily log summary";
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
