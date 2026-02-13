#!/bin/bash
# Paperless-ngx Export: document_exporter -> versionierte ZIP-Exports + Retention + optionale Mail (Text + HTML)
SCRIPT_VERSION="1.0"
COPYRIGHT_LINE="Copyright Roman Glos $(date +%Y)"

# UGREEN NAS Community Script (Roman Glos) – v1.0
#
# Features:
# - Zentrale ENV-Datei (paperlessngx.env) wird automatisch geladen
# - Export via `document_exporter` im Container
# - ZIP-Dateiname automatisch erkennen (export.zip / export-YYYY-MM-DD.zip etc.)
# - Retention (KEEP_FILES)
# - Mail via SMTP (curl): multipart/alternative (Text + HTML)
# - Optional: HTML-Dateiliste (Outlook/Handy-tauglich) mit Limit + Toggle über ENV
# - Legt benötigte Host-Verzeichnisse automatisch an
#
# Cron (Beispiel, täglich 02:10):
#   10 02 * * * /volume2/docker/paperless-ngx/scripts/paperless-export_with_mail.sh
#
# Optional: ENV-Datei explizit setzen:
#   ENV_FILE=/volume2/docker/paperless-ngx/paperlessngx.env ./scripts/paperless-export_with_mail.sh

set -Eeuo pipefail

# =========================
# Zentrale ENV-Datei laden (optional)
# =========================
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-}"

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

load_env_file() {
  local file="$1"
  [[ -z "${file}" || ! -f "${file}" ]] && return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    if [[ "${line}" == export\ * ]]; then
      line="${line#export }"
    fi

    [[ "${line}" != *"="* ]] && continue

    local key="${line%%=*}"
    local val="${line#*=}"

    key="$(trim_ws "$key")"
    [[ -z "${key}" ]] && continue

    val="$(trim_ws "$val")"
    if [[ ( "${val}" == \"*\" && "${val}" == *\" ) || ( "${val}" == \'*\' && "${val}" == *\' ) ]]; then
      val="${val:1:${#val}-2}"
    fi

    printf -v "$key" '%s' "$val"
    export "$key"
  done < "${file}"
}

if [[ -z "${ENV_FILE}" ]]; then
  for candidate in \
    "${SCRIPT_DIR}/paperlessngx.env" \
    "${SCRIPT_DIR}/.env" \
    "${SCRIPT_DIR}/../paperlessngx.env" \
    "${SCRIPT_DIR}/../.env" \
    "$(pwd)/paperlessngx.env" \
    "$(pwd)/.env"
  do
    if [[ -f "${candidate}" ]]; then
      ENV_FILE="${candidate}"
      break
    fi
  done
fi

load_env_file "${ENV_FILE}"
if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  echo "INFO: ENV geladen: ${ENV_FILE}" >&2
fi

# =========================
# Konfiguration
# =========================
: "${CONTAINER_NAME:=${PAPERLESS_CONTAINER_NAME:-Paperless-ngx}}"
: "${HOST_BACKUP_DIR:=${PAPERLESS_HOST_BACKUP_DIR:-/volume2/docker/paperless-ngx/export}}"
: "${KEEP_FILES:=${PAPERLESS_KEEP_FILES:-10}}"
: "${CONTAINER_TMP_DIR:=${PAPERLESS_CONTAINER_TMP_DIR:-/tmp/paperless-export}}"

# Logfile (Host)
: "${PAPERLESS_EXPORT_LOGFILE:=}"
LOGFILE_DEFAULT="${SCRIPT_DIR}/exporter.log"
logfile="${PAPERLESS_EXPORT_LOGFILE:-$LOGFILE_DEFAULT}"

# =========================
# Mail-Benachrichtigung (optional)
# =========================
: "${MAIL_ENABLED:=1}"           # 1 = Mail senden, 0 = deaktiviert
: "${MAIL_ON_SUCCESS:=0}"        # 1 = auch bei Erfolg senden
: "${MAIL_ON_FAILURE:=1}"        # 1 = bei Fehler senden

# Mail-Format
: "${MAIL_SEND_HTML:=1}"         # 1 = multipart (Text + HTML), 0 = nur Text

# Dateiliste
: "${MAIL_FILELIST_ENABLED:=1}"  # 1 = Dateiliste in Mail, 0 = ohne
: "${MAIL_FILELIST_LIMIT:=10}"   # Anzahl Dateien in der Liste

# Exportierte Dateien (Inhalt des ZIP-Exports)
: "${MAIL_EXPORTED_FILES_ENABLED:=0}"   # 1 = exportierte Dateien in Mail anzeigen
: "${MAIL_EXPORTED_FILES_LIMIT:=50}"
: "${MAIL_EXPORTED_FILES_MODE:=grouped}"   # grouped | primary
: "${MAIL_EXPORTED_FILES_PRIMARY_EXTS:=pdf}"  # bevorzugte Endungen (comma-separated), z.B. pdf,jpg,png
    # max. Dokument-Gruppen in der Liste (0 = aus)

# SMTP Settings (curl)
: "${SMTP_HOST:=smtp.example.com}"
: "${TLS_ENABLED:=1}"
: "${SMTP_PORT:=}"              # leer = auto (TLS->587, ohne TLS->25). Für SMTPS: 465
: "${SMTP_USER:=user@example.com}"
: "${SMTP_PASS:=}"

: "${MAIL_FROM:=user@example.com}"
: "${MAIL_FROM_NAME:=UGREEN Paperless Export}"
: "${MAIL_TO:=ziel@example.com}"

# Icons
: "${MAIL_ASCII_ICONS:=0}"      # 1 = [OK]/[FAIL] statt ✅/❌
ICON_OK="✅"
ICON_FAIL="❌"
if [[ "${MAIL_ASCII_ICONS}" == "1" ]]; then
  ICON_OK="[OK]"
  ICON_FAIL="[FAIL]"
fi

# =========================
# Helper
# =========================
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

is_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}


is_true() {
  local v="${1:-0}"
  v="${v,,}"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

# Ensure log directory exists
mkdir -p "$(dirname -- "$logfile")" 2>/dev/null || true
: >"$logfile" 2>/dev/null || {
  # fallback to script dir if user path not writable
  logfile="$LOGFILE_DEFAULT"
  mkdir -p "$(dirname -- "$logfile")" 2>/dev/null || true
  : >"$logfile" || {
    echo "FATAL: Kann Logfile nicht schreiben: $logfile" >&2
    exit 1
  }
}
chmod 664 "$logfile" 2>/dev/null || true

log() {
  echo "$(timestamp) - $*" | tee -a "$logfile"
}

pick_port() {
  if [[ -n "${SMTP_PORT}" ]]; then echo "${SMTP_PORT}"; return; fi
  [[ "${TLS_ENABLED}" == "1" ]] && echo "587" || echo "25"
}

human_size() {
  local f="$1"
  local bytes
  bytes="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B --format="%.1f" "$bytes" 2>/dev/null || echo "${bytes}B"
  else
    echo "${bytes}B"
  fi
}

fmt_mtime() {
  local f="$1"
  # GNU stat
  stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1 || echo "-"
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&#39;}"
  printf '%s' "$s"
}

html_escape_nbsp() {
  # HTML-escape and replace spaces with &nbsp; to avoid line breaks in dates/times
  local s
  s="$(html_escape "$1")"
  s="${s// /&nbsp;}"
  printf "%s" "$s"
}


build_filelist_text() {
  local limit="$1"
  shift || true
  local -a arr=("$@")
  local out=""
  local count=0

  for f in "${arr[@]}"; do
    [[ -f "$f" ]] || continue
    ((count++))
    out+="- $(basename -- "$f")  ($(human_size "$f"), $(fmt_mtime "$f"))\n"
    ((count>=limit)) && break
  done

  printf '%b' "$out"
}

build_filelist_html_rows() {
  local highlight="$1"
  local limit="$2"
  shift 2 || true
  local -a arr=("$@")

  local rows=""
  local count=0
  for f in "${arr[@]}"; do
    [[ -f "$f" ]] || continue
    ((count++))

    local base size mt style_row style_name
    base="$(basename -- "$f")"
    size="$(human_size "$f")"
    mt="$(fmt_mtime "$f")"

    style_row="border-bottom:1px solid #eeeeee;"
    style_name="font-weight:400;"
    if [[ -n "${highlight}" && "$f" == "$highlight" ]]; then
      style_row="background:#f1fff4; border-bottom:1px solid #d7f5dd;"
      style_name="font-weight:700;"
    fi

    rows+="<tr style=\"${style_row}\">"
    rows+="<td style=\"padding:10px; word-break:break-word; overflow-wrap:anywhere; ${style_name}\">$(html_escape "$base")</td>"
    rows+="<td style=\"padding:10px; text-align:right; white-space:nowrap; width:90px;\">$(html_escape "$size")</td>"
    rows+="<td style=\"padding:10px; white-space:nowrap; width:170px;\">$(html_escape_nbsp "$mt")</td>"
    rows+="</tr>"

    ((count>=limit)) && break
  done

  printf '%s' "$rows"
}

send_mail() {
  [[ "${MAIL_ENABLED}" != "1" ]] && return 0
  command -v curl >/dev/null 2>&1 || { log "WARN: curl nicht gefunden -> keine Mail gesendet."; return 0; }

  local subject="$1"
  local body_text="$2"
  local body_html="${3:-}"

  local port url
  port="$(pick_port)"

  local now_rfc2822 msg_id tmp boundary
  now_rfc2822="$(LC_ALL=C date -R)"
  msg_id="<$(date +%s).$$.$(hostname)@${MAIL_FROM#*@}>"

  # Subject korrekt MIME-encoden, falls Nicht-ASCII enthalten ist
  local subject_hdr="$subject"
  if LC_ALL=C printf '%s' "$subject" | grep -q '[^ -~]'; then
    if command -v base64 >/dev/null 2>&1; then
      subject_hdr="=?UTF-8?B?$(printf '%s' "$subject" | base64 | tr -d '\r\n')?="
    else
      subject_hdr="$(printf '%s' "$subject" | tr -cd '[:print:]')"
    fi
  fi

  tmp="$(mktemp)"

  # Empfänger: erlaubt "a@b.de,b@c.de" oder mehrere via Leerzeichen
  IFS=,
  read -ra _rcpts <<< "${MAIL_TO// /}"
  unset IFS
  local -a MAIL_RCPT_ARGS=()
  for r in "${_rcpts[@]}"; do
    [[ -n "$r" ]] && MAIL_RCPT_ARGS+=(--mail-rcpt "$r")
  done

  boundary="====BOUNDARY_$(date +%s)_$$===="

  {
    echo "From: ${MAIL_FROM_NAME} <${MAIL_FROM}>"
    echo "To: ${MAIL_TO}"
    echo "Subject: ${subject_hdr}"
    echo "Date: ${now_rfc2822}"
    echo "Message-ID: ${msg_id}"
    echo "MIME-Version: 1.0"

    if [[ "${MAIL_SEND_HTML}" == "1" && -n "${body_html}" ]]; then
      echo "Content-Type: multipart/alternative; boundary=\"${boundary}\""
      echo "X-Mailer: bash/curl"
      echo

      echo "--${boundary}"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      printf "%b\n" "$body_text"

      echo "--${boundary}"
      echo "Content-Type: text/html; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      printf "%b\n" "$body_html"

      echo "--${boundary}--"
    else
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo "X-Mailer: bash/curl"
      echo
      printf "%b\n" "$body_text"
    fi
  } >"$tmp"

  local -a tls_args=()
  if [[ "${TLS_ENABLED}" == "1" ]]; then
    if [[ "${port}" == "465" ]]; then
      url="smtps://${SMTP_HOST}:${port}"
    else
      url="smtp://${SMTP_HOST}:${port}"
      tls_args+=(--ssl-reqd)
    fi
  else
    url="smtp://${SMTP_HOST}:${port}"
  fi

  curl --silent --show-error --fail \
    --connect-timeout 15 --max-time 90 \
    --url "$url" \
    --user "${SMTP_USER}:${SMTP_PASS}" \
    --mail-from "$MAIL_FROM" \
    ${MAIL_RCPT_ARGS[@]+"${MAIL_RCPT_ARGS[@]}"} \
    --upload-file "$tmp" \
    "${tls_args[@]}" \
    | tee -a "$logfile" || true

  rm -f "$tmp"
}

fail() {
  local rc=$1
  shift || true
  log "FEHLER (rc=$rc): $*"
  if [[ "${MAIL_ON_FAILURE}" == "1" ]]; then
    local tail_log
    tail_log="$(tail -n 200 "$logfile" 2>/dev/null || true)"

    local msg_txt msg_html
    msg_txt="${ICON_FAIL} Paperless Export fehlgeschlagen: $(timestamp)\nHost: $(hostname)\nContainer: ${CONTAINER_NAME}\nHost-Backup-Dir: ${HOST_BACKUP_DIR}\nLog: ${logfile}\n\nLetzte Zeilen:\n${tail_log}"

    msg_html="$(build_html_mail \
      "FEHLER" "${ICON_FAIL} Paperless Export fehlgeschlagen" \
      "$(timestamp)" "$(hostname)" "${CONTAINER_NAME}" "${HOST_BACKUP_DIR}" "" "${logfile}" \
      "${tail_log}" \
      "" \
    )"

    send_mail "Paperless Export FEHLER (rc=$rc)" "$msg_txt" "$msg_html"
  fi
  exit "$rc"
}

build_html_mail() {
  # args:
  # 1 status_word, 2 headline, 3 timestamp, 4 host, 5 container, 6 backup_dir, 7 backup_file, 8 logfile, 9 log_tail, 10 filelist_section_html
  local status_word="$1"
  local headline="$2"
  local ts="$3"
  local host="$4"
  local container="$5"
  local backup_dir="$6"
  local backup_file="$7"
  local logf="$8"
  local log_tail="$9"
  local filelist_html="${10:-}"

  local esc_head esc_host esc_cont esc_bdir esc_bfile esc_logf esc_tail
  esc_head="$(html_escape "$headline")"
  esc_host="$(html_escape "$host")"
  esc_cont="$(html_escape "$container")"
  esc_bdir="$(html_escape "$backup_dir")"
  esc_bfile="$(html_escape "$backup_file")"
  esc_logf="$(html_escape "$logf")"
  esc_tail="$(html_escape "$log_tail")"

  # Basic color (Outlook-safe)
  local badge_bg badge_text
  if [[ "$status_word" == "OK" ]]; then
    badge_bg="#e7f7ee"
    badge_text="#1a7f37"
  else
    badge_bg="#fdecec"
    badge_text="#b42318"
  fi

  cat <<HTML
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body style="margin:0; padding:0; background:#f6f7f9;">
  <table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background:#f6f7f9; padding:18px 0;">
    <tr>
      <td align="center">
        <table role="presentation" cellpadding="0" cellspacing="0" width="640" style="width:100%; max-width:640px; background:#ffffff; border:1px solid #e6e8eb; border-radius:14px; overflow:hidden; font-family:Segoe UI, Arial, sans-serif; color:#111827;">
          <tr>
            <td style="padding:18px 20px; border-bottom:1px solid #e6e8eb;">
              <div style="font-size:18px; font-weight:700; line-height:1.3;">${esc_head}</div>
              <div style="margin-top:8px; display:inline-block; padding:6px 10px; border-radius:999px; background:${badge_bg}; color:${badge_text}; font-size:12px; font-weight:700;">${status_word}</div>
            </td>
          </tr>

          <tr>
            <td style="padding:16px 20px;">
              <table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="font-size:14px;">
                <tr>
                  <td style="padding:6px 0; width:140px; color:#6b7280;">Zeit</td>
                  <td style="padding:6px 0;">$(html_escape "$ts")</td>
                </tr>
                <tr>
                  <td style="padding:6px 0; color:#6b7280;">Host</td>
                  <td style="padding:6px 0;">${esc_host}</td>
                </tr>
                <tr>
                  <td style="padding:6px 0; color:#6b7280;">Container</td>
                  <td style="padding:6px 0;">${esc_cont}</td>
                </tr>
                <tr>
                  <td style="padding:6px 0; color:#6b7280;">Backup-Dir</td>
                  <td style="padding:6px 0; word-break:break-all; font-family:Consolas, monospace; font-size:13px;">${esc_bdir}</td>
                </tr>
HTML

  if [[ -n "$backup_file" ]]; then
    cat <<HTML
                <tr>
                  <td style="padding:6px 0; color:#6b7280;">Backup</td>
                  <td style="padding:6px 0; word-break:break-all; font-family:Consolas, monospace; font-size:13px;">${esc_bfile}</td>
                </tr>
HTML
  fi

  cat <<HTML
                <tr>
                  <td style="padding:6px 0; color:#6b7280;">Log</td>
                  <td style="padding:6px 0; word-break:break-all; font-family:Consolas, monospace; font-size:13px;">${esc_logf}</td>
                </tr>
              </table>
            </td>
          </tr>

          ${filelist_html}

          <tr>
            <td style="padding:0 20px 18px 20px;">
              <div style="font-size:13px; color:#6b7280; margin-bottom:8px;">Letzte Log-Zeilen</div>
              <pre style="margin:0; padding:12px; background:#0b1220; color:#e5e7eb; border-radius:12px; overflow:auto; white-space:pre-wrap; word-break:break-word; font-size:12px; line-height:1.4;">${esc_tail}</pre>
            </td>
          </tr>

          <tr>
            <td style="padding:14px 20px; background:#f9fafb; border-top:1px solid #e6e8eb; font-size:12px; color:#6b7280;">
              UGREEN Paperless Export – Community Script (v${SCRIPT_VERSION})<br>${COPYRIGHT_LINE}
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
HTML
}

build_filelist_section_html() {
  local highlight_file="$1"
  local limit="$2"
  shift 2 || true
  local -a arr=("$@")

  local rows
  rows="$(build_filelist_html_rows "$highlight_file" "$limit" "${arr[@]}")"

  # If no rows, return empty
  [[ -z "$rows" ]] && { printf '%s' ""; return 0; }

  cat <<HTML
          <tr>
            <td style="padding:0 20px 18px 20px;">
              <div style="font-size:13px; color:#6b7280; margin-bottom:10px;">Letzte Backups (max. ${limit})</div>
              <table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="border:1px solid #e6e8eb; border-radius:12px; overflow:hidden; font-size:13px; table-layout:fixed;">
                <tr style="background:#f3f4f6;">
                  <th align="left" style="padding:10px; font-weight:700; width:auto;">Datei</th>
                  <th align="right" style="padding:10px; font-weight:700; white-space:nowrap; width:90px;">Größe</th>
                  <th align="left" style="padding:10px; font-weight:700; white-space:nowrap; width:170px;">Datum</th>
                </tr>
                ${rows}
              </table>
            </td>
          </tr>
HTML
}


collect_exported_files_lists() {
  # Builds EXPORTED_FILES_TEXT + EXPORTED_FILES_SECTION_HTML from a zip inside the container.
  # Args: 1=zip_path_in_container 2=limit_groups
  local zip_in_container="$1"
  local limit_groups="$2"

  EXPORTED_FILES_TEXT=""
  EXPORTED_FILES_SECTION_HTML=""

  # Validate limit
  if [[ -z "$limit_groups" || "$limit_groups" == "0" ]]; then
    return 0
  fi
  if ! is_int "$limit_groups"; then
    limit_groups=50
  fi

  local out
    local pybin
  pybin="$(docker exec "$CONTAINER_NAME" sh -c 'command -v python3 || command -v python || true' 2>>"$logfile" | head -n 1 | tr -d '
' || true)"
  if [[ -z "$pybin" ]]; then
    log "WARN: Kein python im Container gefunden (python3/python). Export-Dateiliste wird übersprungen."
    EXPORTED_FILES_TEXT=""
    EXPORTED_FILES_SECTION_HTML=""
    return 0
  fi
  out="$(docker exec -i "$CONTAINER_NAME" "$pybin" - "$zip_in_container" "$limit_groups" "$MAIL_EXPORTED_FILES_MODE" "$MAIL_EXPORTED_FILES_PRIMARY_EXTS" 2>>"$logfile" <<'PY'
import sys, os, re, html, zipfile

zip_path = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 0
except Exception:
    limit = 0
if limit < 0:
    limit = 0
mode = (sys.argv[3] if len(sys.argv) > 3 else "grouped").strip().lower() or "grouped"
preferred_exts_raw = sys.argv[4] if len(sys.argv) > 4 else "pdf"
preferred_exts = [e.strip().lower().lstrip(".") for e in preferred_exts_raw.split(",") if e.strip()]
if not preferred_exts:
    preferred_exts = ["pdf"]


def emit(text_lines, html_block):
    print("__BEGIN_TEXT__")
    for line in text_lines:
        print(line)
    print("__END_TEXT__")
    print("__BEGIN_HTML__")
    if html_block:
        print(html_block)
    print("__END_HTML__")

if not zip_path:
    emit(["(ZIP-Pfad leer)"], '<div style="font-size:13px; color:#b91c1c; padding:10px; border:1px solid #fecaca; background:#fef2f2; border-radius:10px;">ZIP-Pfad leer</div>')
    sys.exit(0)

if not os.path.exists(zip_path):
    msg = f"(ZIP nicht gefunden im Container: {zip_path})"
    emit([msg], f'<div style="font-size:13px; color:#b91c1c; padding:10px; border:1px solid #fecaca; background:#fef2f2; border-radius:10px;">{html.escape(msg)}</div>')
    sys.exit(0)

try:
    zf = zipfile.ZipFile(zip_path, "r")
except Exception as e:
    msg = f"(Fehler beim Öffnen des ZIP: {e})"
    emit([msg], f'<div style="font-size:13px; color:#b91c1c; padding:10px; border:1px solid #fecaca; background:#fef2f2; border-radius:10px;">{html.escape(msg)}</div>')
    sys.exit(0)

RX_SUFFIX = re.compile(r'-(archive|archiv|thumbnail)(?=\.[^.]+$)', re.IGNORECASE)

def strip_suffix(filename: str) -> str:
    return RX_SUFFIX.sub('', filename)

def group_key(filename: str) -> str:
    # Group by stem without suffix + without extension (so .pdf/.webp variants land in one group)
    base = strip_suffix(filename)
    stem, _ext = os.path.splitext(base)
    return stem

def variant(filename: str) -> str:
    low = filename.lower()
    if "-thumbnail." in low:
        return "thumbnail"
    if "-archive." in low or "-archiv." in low:
        return "archive"
    return "original"

# Collect unique basenames (de-duplicate)
seen = set()
files = []
for n in zf.namelist():
    if n.endswith("/"):
        continue
    b = os.path.basename(n)
    if not b:
        continue
    if b in seen:
        continue
    seen.add(b)
    files.append(b)

# Group by key
groups = {}
for b in files:
    k = group_key(b)
    groups.setdefault(k, []).append(b)

# Sort groups and limit
items = sorted(groups.items(), key=lambda kv: kv[0].lower())

def ext(fn: str) -> str:
    return os.path.splitext(fn)[1].lstrip(".").lower()

if mode == "primary":
    primary_items = []
    for k, flist in items:
        originals = [fn for fn in flist if variant(fn) == "original"]
        if not originals:
            continue
        chosen = None
        for ex in preferred_exts:
            for fn in originals:
                if ext(fn) == ex:
                    chosen = fn
                    break
            if chosen:
                break
        # If nothing matches preferred exts (e.g. only .webp), skip in primary mode
        if not chosen:
            continue
        # Display key: keep filename with extension (user-friendly)
        primary_items.append((chosen, [chosen]))
    items = primary_items

total_groups = len(items)
shown = items if limit == 0 else items[:limit]

order = {"original": 0, "archive": 1, "thumbnail": 2}
def sort_key(fn: str):
    return (order.get(variant(fn), 99), fn.lower())

# TEXT
text_lines = []
if not shown:
    text_lines.append("(keine Dateien im Export gefunden)")
else:
    text_lines.append(f"Exportierte Dateien (Auszug, max. {limit if limit>0 else 'alle'} Dokumente):")
    for k, flist in shown:
        flist_sorted = sorted(flist, key=sort_key)
        text_lines.append(f"- {k}:")
        for fn in flist_sorted:
            text_lines.append(f"    - {fn}")
    if limit and total_groups > limit:
        text_lines.append(f"... ({total_groups-limit} weitere Dokumente nicht angezeigt)")

# HTML
html_block = ""
if shown:
    rows = []
    for k, flist in shown:
        flist_sorted = sorted(flist, key=sort_key)
        items_html = "<br>".join([html.escape(fn) for fn in flist_sorted])
        rows.append(
            f'<tr>'
            f'  <td style="padding:10px; border-top:1px solid #e6e8eb; vertical-align:top; white-space:nowrap;"><b>{html.escape(k)}</b></td>'
            f'  <td style="padding:10px; border-top:1px solid #e6e8eb; vertical-align:top;">{items_html}</td>'
            f'</tr>'
        )
    note = ""
    if limit and total_groups > limit:
        note = f'<div style="margin-top:10px; font-size:12px; color:#6b7280;">… {total_groups-limit} weitere Dokument-Gruppen nicht angezeigt.</div>'

    html_block = "\n".join([
        '<tr>',
        '  <td style="padding:0 20px 18px 20px;">',
        f'    <div style="font-size:13px; color:#6b7280; margin-bottom:10px;">Exportierte Dateien (Auszug, max. {limit if limit else total_groups})</div>',
        '    <table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse; border:1px solid #e6e8eb; border-radius:12px; overflow:hidden;">',
        '      <tr style="background:#f3f4f6;">',
        '        <th align="left" style="padding:10px; font-weight:700;">Dokument</th>',
        '        <th align="left" style="padding:10px; font-weight:700;">Dateien</th>',
        '      </tr>',
        *rows,
        '    </table>',
        note,
        '  </td>',
        '</tr>',
    ])

emit(text_lines, html_block)

PY
)"
  EXPORTED_FILES_TEXT="$(awk 'BEGIN{f=0} /^__BEGIN_TEXT__/{f=1;next} /^__END_TEXT__/{f=0} f{print}' <<<"$out" | sed '/^[[:space:]]*$/d' || true)"
  EXPORTED_FILES_SECTION_HTML="$(awk 'BEGIN{f=0} /^__BEGIN_HTML__/{f=1;next} /^__END_HTML__/{f=0} f{print}' <<<"$out" || true)"
}

# =========================
# Start
# =========================
log "starte PaperlessNGX-Exporter (v${SCRIPT_VERSION})"

# Validate ints
if ! is_int "$KEEP_FILES"; then
  log "WARN: PAPERLESS_KEEP_FILES ist nicht numerisch (${KEEP_FILES}) -> setze 10"
  KEEP_FILES=10
fi
if ! is_int "$MAIL_FILELIST_LIMIT"; then
  log "WARN: MAIL_FILELIST_LIMIT ist nicht numerisch (${MAIL_FILELIST_LIMIT}) -> setze 10"
  MAIL_FILELIST_LIMIT=10
fi

mkdir -p "$HOST_BACKUP_DIR" || fail 2 "Kann Host Backup Dir nicht anlegen: $HOST_BACKUP_DIR"

if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  log "Container '$CONTAINER_NAME' nicht gefunden. Ausgabe von docker ps:"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | tee -a "$logfile" || true
  fail 3 "Container nicht gefunden"
fi

ARCHIVE_NAME="paperless_export_$(date +%Y%m%d_%H%M%S).zip"
HOST_ARCHIVE_PATH="${HOST_BACKUP_DIR}/${ARCHIVE_NAME}"

# Container TMP vorbereiten (beschreibbar machen, falls nötig)
if ! docker exec "$CONTAINER_NAME" sh -c "mkdir -p '$CONTAINER_TMP_DIR' && test -w '$CONTAINER_TMP_DIR'" >>"$logfile" 2>&1; then
  log "WARN: Export-Tmp nicht beschreibbar, versuche Rechte als root zu korrigieren..."
  docker exec -u 0 "$CONTAINER_NAME" sh -c "mkdir -p '$CONTAINER_TMP_DIR' && chmod 777 '$CONTAINER_TMP_DIR'" >>"$logfile" 2>&1 || true
fi
if ! docker exec "$CONTAINER_NAME" sh -c "mkdir -p '$CONTAINER_TMP_DIR' && test -w '$CONTAINER_TMP_DIR' && find '$CONTAINER_TMP_DIR' -maxdepth 1 -type f -name '*.zip' -delete" >>"$logfile" 2>&1; then
  fail 4 "Kann Export-Tmp im Container nicht vorbereiten/beschreiben: $CONTAINER_TMP_DIR (Tipp: PAPERLESS_CONTAINER_TMP_DIR=/usr/src/paperless/export/_tmp)"
fi

log "Starte document_exporter im Container..."
if ! docker exec "$CONTAINER_NAME" sh -c "document_exporter '$CONTAINER_TMP_DIR' -z" >>"$logfile" 2>&1; then
  fail 5 "document_exporter fehlgeschlagen"
fi

ZIP_IN_CONTAINER="$(docker exec "$CONTAINER_NAME" sh -c "ls -1t '$CONTAINER_TMP_DIR'/*.zip 2>/dev/null | head -n 1" | tr -d '\r' || true)"
if [[ -z "${ZIP_IN_CONTAINER}" ]]; then
  fail 6 "Kein ZIP im Container gefunden in: $CONTAINER_TMP_DIR"
fi

if is_true "${MAIL_ON_SUCCESS}" && is_true "${MAIL_EXPORTED_FILES_ENABLED}" && [[ "${MAIL_EXPORTED_FILES_LIMIT}" != "0" ]]; then
  collect_exported_files_lists "$ZIP_IN_CONTAINER" "${MAIL_EXPORTED_FILES_LIMIT}"
  if [[ -z "${EXPORTED_FILES_TEXT}" ]]; then
    log "WARN: Export-Dateiliste konnte nicht erzeugt werden. Prüfe Log: $logfile"
  fi
fi

if ! docker cp "${CONTAINER_NAME}:${ZIP_IN_CONTAINER}" "$HOST_ARCHIVE_PATH" >>"$logfile" 2>&1; then
  fail 6 "docker cp fehlgeschlagen: ${ZIP_IN_CONTAINER}"
fi

log "Export erstellt: $HOST_ARCHIVE_PATH"

# Container TMP cleanup
docker exec "$CONTAINER_NAME" sh -c "find '$CONTAINER_TMP_DIR' -maxdepth 1 -type f -name '*.zip' -delete" >>"$logfile" 2>&1 || true

# Retention
mapfile -t files < <(ls -1t "${HOST_BACKUP_DIR}"/paperless_export_*.zip 2>/dev/null || true)
if (( ${#files[@]} > KEEP_FILES )); then
  log "Retention: behalte $KEEP_FILES ZIPs, lösche ${#files[@]}-${KEEP_FILES}"
  for ((i=KEEP_FILES; i<${#files[@]}; i++)); do
    rm -f "${files[$i]}" && log "gelöscht: ${files[$i]}"
  done
fi

# Refresh file list after retention
mapfile -t files_now < <(ls -1t "${HOST_BACKUP_DIR}"/paperless_export_*.zip 2>/dev/null || true)

log "PaperlessNGX-Exporter abgeschlossen."

# Mail on success
if [[ "${MAIL_ON_SUCCESS}" == "1" ]]; then
  local_tail="$(tail -n 120 "$logfile" 2>/dev/null || true)"

  filelist_txt=""
  filelist_section_html=""
  exported_txt=""
  exported_section_html=""
  if is_true "${MAIL_FILELIST_ENABLED}" && [[ "${MAIL_FILELIST_LIMIT}" != "0" ]] && [[ ${#files_now[@]} -gt 0 ]]; then
    filelist_txt="\nLetzte Backups (max. ${MAIL_FILELIST_LIMIT}):\n$(build_filelist_text "${MAIL_FILELIST_LIMIT}" "${files_now[@]}")"
    filelist_section_html="$(build_filelist_section_html "$HOST_ARCHIVE_PATH" "${MAIL_FILELIST_LIMIT}" "${files_now[@]}")"
  fi


  if is_true "${MAIL_EXPORTED_FILES_ENABLED}" && [[ -n "${EXPORTED_FILES_TEXT}" ]]; then
    exported_txt="\n\n${EXPORTED_FILES_TEXT}"
    exported_section_html="${EXPORTED_FILES_SECTION_HTML}"
  fi

  # Combine sections: Export-Inhalt zuerst, dann Backup-Liste
  combined_section_html="${exported_section_html}${filelist_section_html}"
  msg_txt="${ICON_OK} Paperless Export erfolgreich: $(timestamp)\nHost: $(hostname)\nContainer: ${CONTAINER_NAME}\nBackup: ${HOST_ARCHIVE_PATH}\nLog: ${logfile}${filelist_txt}\n\nLetzte Zeilen:\n${local_tail}"

  msg_html="$(build_html_mail \
    "OK" "${ICON_OK} Paperless Export erfolgreich" \
    "$(timestamp)" "$(hostname)" "${CONTAINER_NAME}" "${HOST_BACKUP_DIR}" "${HOST_ARCHIVE_PATH}" "${logfile}" \
    "${local_tail}" \
    "${combined_section_html}" \
  )"

  send_mail "Paperless Export OK" "$msg_txt" "$msg_html"
fi

exit 0
