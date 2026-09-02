#!/usr/bin/env bash
#===============================================================================
# Diktierbox – Proxmox VE LXC-Installer (Community-Scripts-Stil)
#-------------------------------------------------------------------------------
# Lokale Spracherkennungs-Web-App im Stil von Handy (cjpais/Handy): Mikrofon-
# Aufnahme oder Datei-Upload → Transkript, komplett lokal über whisper.cpp
# (Handys Engine-Familie) und Handys öffentliche Whisper-Modelle
# (blob.handy.computer). Web-UI auf jedem Gerät im LAN nutzbar.
#
# Einzeiler auf dem Proxmox-Host (als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/install/diktierbox.sh)"
#
# Debug (vollständiges bash -x Log):
#   DEBUG=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/install/diktierbox.sh)"
#
# Weitere Aufrufe:
#   ./diktierbox.sh --update        # App im vorhandenen CT aktualisieren
#   ./diktierbox.sh --uninstall     # Container vollständig entfernen (DESTRUKTIV!)
#   CTID=200 VAR_RAM=4096 ./diktierbox.sh   # nicht-interaktiv mit eigenen Werten
#===============================================================================
set -Eeuo pipefail

#==============================
# Konfiguration (per Env überschreibbar)
#==============================
readonly APP_ID="diktierbox"
readonly APP_NAME="Diktierbox"
readonly UPSTREAM_WHISPER_REPO="ggml-org/whisper.cpp"
readonly SCRIPT_URL_DEFAULT="https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/install/diktierbox.sh"

# Ressourcen: whisper.cpp (CPU, small-Modell) braucht moderat RAM; die
# Standard-Community-Werte (2 vCPU / 2 GB) reichen für ggml-small. Wer
# large-v3-turbo per UI nachlädt, gibt mehr RAM mit (Hinweis in der Web-UI).
VAR_DISK="${VAR_DISK:-12}"        # GB (venv klein, Modelle bis 1,6 GB, Log-Puffer)
VAR_CPU="${VAR_CPU:-2}"
VAR_RAM="${VAR_RAM:-2048}"       # MB
VAR_SWAP="${VAR_SWAP:-2048}"      # MB

VAR_OS="debian"
VAR_VERSION="12"
CT_TYPE="1"                       # 1 = unprivileged
BRIDGE="${BRIDGE:-vmbr0}"
NET_MODE="${NET_MODE:-dhcp}"      # dhcp | static
NET_CIDR="${NET_CIDR:-}"          # z. B. 192.168.1.100/24 (bei NET_MODE=static)
NET_GW="${NET_GW:-}"              # z. B. 192.168.1.1

WEB_PORT="${WEB_PORT:-8080}"

# Modell-Pinning für den Erstdownload (weitere jederzeit per Web-UI nachladbar):
#   ggml-small.bin (487 MB) | ggml-medium-q5_0.bin (514 MB)
#   ggml-large-v3-turbo.bin (1600 MB) | ggml-large-v3-q5_0.bin (1100 MB)
PRELOAD_MODEL="${PRELOAD_MODEL:-ggml-small.bin}"
# leer → kein Erstdownload, Modelle nur per Web-UI
#PRELOAD_MODEL="${PRELOAD_MODEL:-}"

MODE="${MODE:-install}"           # install | update | uninstall
DEBUG="${DEBUG:-0}"
GUEST_LOG_FILE="/var/log/${APP_ID}-install.log"

TARGET_CTID=""
STORAGE=""
TEMPLATE=""
NET_CFG="ip=dhcp"
CT_IP=""

TMPDIR_INSTALL="$(mktemp -d /tmp/${APP_ID}-install.XXXXXX)"
LOG_FILE="/tmp/${APP_ID}-install-$(date +%Y%m%d-%H%M%S).log"

trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

#==============================
# Logging + vollständige Fehlermeldungskette
# (Logzeilen nach stderr, damit stdout-Kommandosubstitutionen sauber bleiben)
#==============================
msg_info()  { printf '\033[1;36m[Info]\033[0m  %s\n' "$*" >&2; }
msg_ok()    { printf '\033[1;32m [OK]\033[0m  %s\n' "$*" >&2; }
msg_warn()  { printf '\033[1;33m [WARN]\033[0m %s\n' "$*" >&2; }
msg_error() { printf '\033[1;31m[Fehler]\033[0m %s\n' "$*" >&2; }

die() {
  msg_error "$*"
  msg_error "Komplettes Installationslog: $LOG_FILE"
  exit 1
}

enable_debug() {
  PS4='+ $(date +%H:%M:%S) [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
  msg_warn "Debug-Modus aktiv (bash -x) – jede Anweisung wird ins Log mitgeschrieben."
}

print_call_stack() {
  local frame=0
  while caller "$frame" 2>/dev/null; do frame=$((frame + 1)); done
}

on_error() {
  local exit_code="$1"
  local failed_cmd="$2"
  trap - ERR
  set +Eeuo pipefail

  printf '\n' >&2
  msg_error "Installationsfehler – vollständige Fehlermeldungskette:"
  msg_error "Exit-Code : ${exit_code}"
  msg_error "Fehlschlag: ${failed_cmd}"
  local frame=0 line func file
  while IFS=' ' read -r line func file; do
    msg_error "  aufrufend: ${func}() (${file}:${line})"
    frame=$((frame + 1))
  done < <(while caller "$frame" 2>/dev/null; do frame=$((frame + 1)); done)

  if [[ "${PHASE:-host}" == "guest" ]]; then
    msg_error "--- systemctl status ${APP_ID} ---"
    systemctl --no-pager -l status ${APP_ID} 2>&1 | tail -n 25 || true
    msg_error "--- journalctl -u ${APP_ID} (letzte 40 Zeilen) ---"
    journalctl --no-pager -n 40 -u ${APP_ID} 2>&1 || true
    msg_error "--- offene Ports (ss -tlnp) ---"
    ss -tlnp 2>/dev/null || true
    msg_error "--- Speicher/Platte ---"
    free -m 2>/dev/null || true
    df -h / 2>/dev/null || true
    msg_error "Gast-Log: ${GUEST_LOG_FILE}"
  elif [[ -n "${CTID:-}" ]] && pct status "${CTID}" >/dev/null 2>&1; then
    msg_error "--- Gast-Log (letzte 60 Zeilen) ---"
    pct exec "${CTID}" -- tail -n 60 "$GUEST_LOG_FILE" 2>/dev/null || true
  fi

  msg_error "Alle Ausgaben wurden mitgeschrieben: ${LOG_FILE} (Phase: ${PHASE:-host})"
  msg_error "Zum Nachvollziehen mit vollem Shelltrace erneut ausführen:"
  msg_error "  DEBUG=1 bash -c \"\$(wget -qLO - ${SCRIPT_URL:-$SCRIPT_URL_DEFAULT})\""
  exit "$exit_code"
}

trap 'on_error $? "$BASH_COMMAND"' ERR

if [[ "$DEBUG" == "1" ]]; then
  enable_debug
fi

PHASE="${DB_PHASE:-host}"

#==============================
# Hilfsfunktionen
#==============================
have() { command -v "$1" >/dev/null 2>&1; }

ask_default() { # ask_default <Prompt> <Default>
  local reply=""
  if [[ -t 0 ]]; then
    read -r -p "$1 [$2]: " reply </dev/tty || reply=""
    printf '%s\n' "${reply:-$2}"
  else
    msg_info "$1 → nicht-interaktiv, verwende Default: $2"
    printf '%s\n' "$2"
  fi
}

ask_required_value() { # ask_required_value <Option> <Wert>
  if (($# < 2)) || [[ -z "$2" ]]; then
    die "Option $1 benötigt einen Wert (--help anzeigen)."
  fi
  printf '%s\n' "$2"
}

confirm_or_die() { # confirm_or_die <Frage>
  if [[ -t 0 ]]; then
    local reply=""
    read -r -p "$1 [y/N]: " reply </dev/tty || reply=""
    case "$reply" in y|Y|ja|JA|Ja) return 0 ;; *) die "Abgebrochen." ;; esac
  else
    die "$1 – nicht-interaktiv und Bestätigung erforderlich (TTY fehlt)."
  fi
}

fetch_to() { # fetch_to <URL> <Zieldatei>
  local url="$1" out="$2" attempt
  for attempt in 1 2 3; do
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "${out}.part" "$url"; then
      mv "${out}.part" "$out"
      return 0
    fi
    msg_warn "Download-Versuch ${attempt}/3 fehlgeschlagen: $url"
    sleep 2
  done
  die "Konnte Datei nicht laden: $url"
}

wait_for_http() { # wait_for_http <URL> <Timeout-Sekunden>
  local url="$1" timeout_s="$2" elapsed=0 code=""
  until code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)" && [[ "$code" =~ ^(200|301|302|307|308|401)$ ]]; do
    if (( elapsed >= timeout_s )); then
      msg_error "HTTP-Check fehlgeschlagen nach ${timeout_s}s: $url (letzter Code: ${code:-keiner})"
      return 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 0
}

require_active_unit() { # require_active_unit <unit>
  if ! systemctl is-active --quiet "$1"; then
    msg_error "systemd-Unit '$1' ist NICHT aktiv (Status: $(systemctl is-active "$1" 2>&1 || true))"
    journalctl --no-pager -u "$1" -n 30 2>&1 || true
    return 1
  fi
  msg_ok "Service läuft: $1"
}

#==============================
# GAST-PHASE: Installation im LXC (Debian 12)
#==============================
APT_UPDATED=0
apt_install() {
  if (( APT_UPDATED == 0 )); then
    msg_info "apt-get update …"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

install_app() {
  msg_info "Installiere System-Abhängigkeiten (Build-Tools, ffmpeg, Python) …"
  apt_install build-essential cmake git ca-certificates curl ffmpeg python3 \
    python3-venv python3-pip pkg-config
  msg_ok "System-Abhängigkeiten installiert."

  build_whisper
  install_webapp
  create_service_user
  write_data_dirs
  preload_model
  start_service
}

build_whisper() {
  # whisper.cpp aus der Quelle kompilieren – dieselbe Engine-Familie, die auch
  # Handy (transcribe-cpp) nutzt. Reines CPU-Target (kein CUDA/hip), läuft
  # daher auf jedem x86_64-Host ohne Treiber-Anforderungen.
  if [[ -x /usr/local/bin/whisper-cli ]]; then
    msg_ok "whisper-cli bereits vorhanden – Update nur bei Fehlen."
    msg_ok "whisper-cli bereits vorhanden ($( /usr/local/bin/whisper-cli --help 2>&1 | head -n1 | grep -o 'whisper-cli.*' || echo 'Version unbekannt'))."
    return 0
  fi
  local src="/tmp/whisper.cpp"
  rm -rf "$src"
  msg_info "Klone ${UPSTREAM_WHISPER_REPO} (Master) …"
  git clone -q --depth 1 "https://github.com/${UPSTREAM_WHISPER_REPO}.git" "$src"
  cd "$src"
  local nproc_build
  nproc_build="$(nproc)"
  msg_info "Konfiguriere und kompiliere whisper-cli (cmake -j${nproc_build}, ~2-5 Minuten) …"
  if ! cmake -B build -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DGGML_NATIVE=ON \
         > /tmp/whisper-build.log 2>&1; then
    msg_error "cmake-Konfiguration fehlgeschlagen – letzte 60 Zeilen:"
    tail -n 60 /tmp/whisper-build.log >&2 || true
    die "whisper.cpp cmake configure fehlgeschlagen."
  fi
  if ! cmake --build build --target whisper-cli -j"${nproc_build}" >> /tmp/whisper-build.log 2>&1; then
    msg_error "Build fehlgeschlagen – letzte 60 Zeilen:"
    tail -n 60 /tmp/whisper-build.log >&2 || true
    die "whisper.cpp Build fehlgeschlagen."
  fi
  [[ -x build/bin/whisper-cli ]] || die "build/bin/whisper-cli fehlt nach Build (Log: /tmp/whisper-build.log)."
  install -m 755 build/bin/whisper-cli /usr/local/bin/whisper-cli
  msg_ok "whisper-cli installiert."
  cd /
  rm -rf "$src"
}

install_webapp() {
  # App-Code aus unserem eigenen GitHub-Repo holen (GitHub-first).
  local base="https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/app"
  msg_info "Lade App-Code aus HatchetMan111/DiktierBoxProxmox …"
  mkdir -p /opt/diktierbox/static
  fetch_to "${base}/server.py" /opt/diktierbox/server.py
  fetch_to "${base}/static/index.html" /opt/diktierbox/static/index.html
  msg_ok "App-Code installiert nach /opt/diktierbox."

  msg_info "Erstelle Python-venv und installiere FastAPI/uvicorn …"
  python3 -m venv /opt/diktierbox/venv
  /opt/diktierbox/venv/bin/pip install --no-cache-dir --timeout 300 \
    fastapi 'uvicorn[standard]' python-multipart >/tmp/pip-install.log 2>&1 \
    || { tail -n 30 /tmp/pip-install.log >&2; die "pip install fehlgeschlagen."; }
  msg_ok "Python-Umgebung fertig."
}

create_service_user() {
  if id -u "$APP_ID" >/dev/null 2>&1; then
    msg_ok "Dienstbenutzer '${APP_ID}' existiert bereits."
    return 0
  fi
  useradd --system --home-dir /var/lib/diktierbox --shell /usr/sbin/nologin "$APP_ID"
  msg_ok "Dienstbenutzer '${APP_ID}' angelegt."
}

write_data_dirs() {
  msg_info "Lege Datenverzeichnisse an (/var/lib/diktierbox) …"
  install -d -o diktierbox -g diktierbox -m 0750 \
    /var/lib/diktierbox /var/lib/diktierbox/models \
    /var/lib/diktierbox/tmp /var/lib/diktierbox/history
  chown -R diktierbox:diktierbox /opt/diktierbox
  msg_ok "Datenverzeichnisse angelegt."
}

preload_model() {
  # Lädt das erste Modell direkt bei der Installation (die Web-UI kann später
  # weitere nachladen). Modelle stammen aus Handys öffentlichem Blob-Store.
  if [[ -z "$PRELOAD_MODEL" ]]; then
    msg_info "Kein PRELOAD_MODEL gesetzt – Modelle werden später über die Web-UI geladen."
    return 0
  fi
  # Modell-Quellen mit automatischem Fallback: primär Handys öffentlicher
  # Blob-Store, alternativ die offiziellen whisper.cpp-Modelle auf HuggingFace
  # (identische GGML-Dateien für dieselbe Engine).
  local -A model_urls=(
    [ggml-small.bin]="https://blob.handy.computer/ggml-small.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
    [ggml-medium-q5_0.bin]="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"
    [ggml-large-v3-turbo.bin]="https://blob.handy.computer/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    [ggml-large-v3-q5_0.bin]="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"
  )
  local -A model_min_mb=(
    [ggml-small.bin]=462
    [ggml-medium-q5_0.bin]=488
    [ggml-large-v3-turbo.bin]=1520
    [ggml-large-v3-q5_0.bin]=1045
  )
  local url="${model_urls[$PRELOAD_MODEL]:-}"
  [[ -n "$url" ]] || die "Unbekanntes PRELOAD_MODEL: ${PRELOAD_MODEL} (erlaubt: ${!model_urls[*]})"
  local dest="/var/lib/diktierbox/models/${PRELOAD_MODEL}"
  if [[ -s "$dest" ]] && [[ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -ge $(( model_min_mb[$PRELOAD_MODEL] * 1024 * 1024 )) ]]; then
    msg_ok "Whisper-Modell bereits vorhanden: ${PRELOAD_MODEL} ($(( $(stat -c%s "$dest") / 1024 / 1024 )) MB)"
  else
    msg_info "Lade Modell ${PRELOAD_MODEL} (~${model_min_mb[$PRELOAD_MODEL]}+ MB, mehrere Quellen möglich, 1-5 Min) …"
    install -o diktierbox -g diktierbox -m 0644 /dev/null "${dest}.part"
    local dl_ok=0 dl_url
    for dl_url in $url; do
      rm -f "${dest}.part"
      msg_info "  Quelle: ${dl_url}"
      if runuser -u diktierbox -- curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 \
          -o "${dest}.part" "$dl_url"; then
        dl_ok=1
        break
      fi
      msg_warn "  Quelle fehlgeschlagen – probiere nächste (falls vorhanden)."
    done
    if (( dl_ok == 0 )); then
      rm -f "${dest}.part"
      die "Modell-Download von allen Quellen fehlgeschlagen (Netz/DNS prüfen; später per Web-UI erneut versuchen)."
    fi
    chown diktierbox:diktierbox "${dest}.part"
    local size_mb
    size_mb="$(( $(stat -c%s "${dest}.part") / 1024 / 1024 ))"
    (( size_mb >= model_min_mb[$PRELOAD_MODEL] )) || { rm -f "${dest}.part"; die "Modell-Datei verdächtig klein (${size_mb} MB) – Download abgebrochen."; }
    mv "${dest}.part" "$dest"
    chown diktierbox:diktierbox "$dest"
    msg_ok "Modell ${PRELOAD_MODEL} geladen (${size_mb} MB)."
  fi

  # Silero-VAD-Modell (~0.9 MB) für Stille-Filterung wie bei Handy; ohne dieses
  # läuft whisper-cli mit --vad in einen Fehler (Exit 10).
  local vad_dest="/var/lib/diktierbox/models/ggml-silero-v5.1.2.bin"
  if [[ ! -s "$vad_dest" ]]; then
    msg_info "Lade Silero-VAD-Modell (ggml-org/whisper-vad, ~1 MB) …"
    install -o diktierbox -g diktierbox -m 0644 /dev/null "${vad_dest}.part"
    if ! runuser -u diktierbox -- curl -fsSL --retry 3 --retry-delay 2 \
        -o "${vad_dest}.part" "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"; then
      rm -f "${vad_dest}.part"
      msg_warn "VAD-Modell-Download fehlgeschlagen – Diktierbox läuft ohne VAD (Stille-Filterung)."
      return 0
    fi
    mv "${vad_dest}.part" "$vad_dest"
    chown diktierbox:diktierbox "$vad_dest"
    msg_ok "Silero-VAD-Modell geladen."
  else
    msg_ok "Silero-VAD-Modell bereits vorhanden."
  fi
}

start_service() {
  write_systemd_unit
  systemctl daemon-reload
  systemctl enable ${APP_ID} >/dev/null 2>&1 || true
  msg_ok "${APP_ID}.service aktiviert (Autostart beim Boot, Restart=always)."
  msg_info "(Re)starte Service …"
  systemctl restart ${APP_ID}
}

write_systemd_unit() {
  local unit_src="/root/${APP_ID}.service"
  if [[ ! -s "$unit_src" ]]; then
    # Fallback: Unit aus dem Repo ziehen (identischer Stand)
    unit_src="/tmp/${APP_ID}.service"
    fetch_to "https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/install/diktierbox.service" "$unit_src"
  fi
  msg_info "Installiere systemd-Unit ${APP_ID}.service …"
  # Port dynamisch einsetzen, falls vom Default abweichend
  sed "s/--port 8080/--port ${WEB_PORT}/" "$unit_src" > /etc/systemd/system/${APP_ID}.service
  chmod 644 /etc/systemd/system/${APP_ID}.service
  msg_ok "systemd-Unit installiert (bind 0.0.0.0:${WEB_PORT}, Restart=always)."
}

verify_service_and_web() {
  require_active_unit "${APP_ID}" || die "${APP_ID}-Service läuft nicht – Diagnose siehe oben."

  msg_info "Warte auf Web-UI unter 127.0.0.1:${WEB_PORT} (max. 90 s) …"
  wait_for_http "http://127.0.0.1:${WEB_PORT}/api/health" 90 || {
    journalctl --no-pager -n 40 -u ${APP_ID} 2>&1 || true
    die "Web-UI antwortet nicht auf Port ${WEB_PORT}."
  }
  msg_ok "Web-UI antwortet auf 127.0.0.1:${WEB_PORT}/api/health (HTTP 200)."

  msg_info "Prüfe Bind-Adresse (muss 0.0.0.0:${WEB_PORT} sein, nicht nur 127.0.0.1) …"
  local bind_line
  bind_line="$(ss -tlnp 2>/dev/null | grep ":${WEB_PORT} " || true)"
  if [[ -z "$bind_line" ]]; then
    ss -tlnp || true
    die "Kein Listener auf Port ${WEB_PORT} gefunden!"
  fi
  if echo "$bind_line" | grep -q "127.0.0.1:${WEB_PORT}"; then
    echo "$bind_line"
    die "Dienst lauscht nur auf 127.0.0.1 -> von außerhalb NICHT erreichbar!"
  fi
  msg_ok "Dienst lauscht korrekt: $(echo "$bind_line" | awk '{print $4}')"
}

print_guest_summary() {
  local ip="${CT_IP:-127.0.0.1}"
  cat <<SUMMARY

=========================================================
  ${APP_NAME} wurde erfolgreich installiert ✔
=========================================================
  Web-UI      :  http://${ip}:${WEB_PORT}
  Engine      :  whisper-cli $(/usr/local/bin/whisper-cli --version 2>&1 | head -n1 || echo '') (CPU)
  Modell      :  $(find /var/lib/diktierbox/models -maxdepth 1 -type f -printf '%f ' 2>/dev/null)
  Container   :  unprivileged LXC, onboot=1
  Daten       :  /var/lib/diktierbox (Modelle, Historie)
  Dienst      :  systemctl status ${APP_ID}
  Logs        :  ${GUEST_LOG_FILE} · journalctl -u ${APP_ID}

  Update      :  Einzeiler auf dem Proxmox-Host erneut ausführen
                 (erkennt den Container automatisch) oder:
                 ./diktierbox.sh --update
  Deinstall   :  Auf dem Proxmox-Host: ./diktierbox.sh --uninstall
=========================================================

SUMMARY
}

guest_main() {
  msg_info "${APP_NAME} – Gast-Phase (MODE=${MODE}) auf $(hostname), Start: $(date -Is)."
  [[ $EUID -eq 0 ]] || die "Gast-Phase muss als root laufen."
  apt_install ca-certificates curl

  install_app
  verify_service_and_web

  print_guest_summary
}

#==============================
# HOST-PHASE: Proxmox-Node
#==============================
check_host_prereqs() {
  [[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen (sudo su -)."
  [[ -d /etc/pve ]] || die "Dies ist kein Proxmox-VE-Host (/etc/pve fehlt). Script auf dem PVE-Node starten."
  local cmd
  for cmd in pct pvesm pveam pvesh curl openssl jq; do
    have "$cmd" || die "Benötigtes Werkzeug nicht gefunden: $cmd – nur auf Proxmox VE ausführen."
  done
}

check_upstream_reachable() {
  # GitHub ist Pflicht (App-Code/whisper.cpp kommen von dort). Die Modell-
  # Quellen werden NICHT fatal geprüft: blob.handy.computer ist immer wieder
  # mal nicht erreichbar; dann weicht der Download automatisch auf die
  # offiziellen whisper.cpp-Modelle (HuggingFace) aus.
  if ! curl -fsSL --max-time 15 --retry 2 "https://api.github.com/repos/${UPSTREAM_WHISPER_REPO}" >/dev/null; then
    die "GitHub (${UPSTREAM_WHISPER_REPO}) nicht erreichbar – Verbindung prüfen."
  fi
  msg_ok "GitHub erreichbar (whisper.cpp-Quelle)."
  if curl -fsSL --max-time 10 --retry 1 -r 0-0 "https://blob.handy.computer/ggml-small.bin" >/dev/null 2>&1; then
    msg_ok "blob.handy.computer erreichbar (Modell-Primärquelle)."
  else
    msg_warn "blob.handy.computer NICHT erreichbar – Modell-Download nutzt automatisch"
    msg_warn "den HuggingFace-Fallback (ggerganov/whisper.cpp, identische GGML-Dateien)."
  fi
}

find_ct_by_name() {
  local vmid hostname
  while read -r vmid; do
    hostname="$(pct config "$vmid" 2>/dev/null | awk '/^hostname:/{print $2}')"
    if [[ "$hostname" == "$APP_ID" ]]; then
      printf '%s\n' "$vmid"
    fi
  done < <(pct list 2>/dev/null | awk 'NR>1{print $1}')
}

next_free_ctid() {
  pvesh get /cluster/nextid 2>/dev/null || printf '999\n'
}

storage_rootdir_list() {
  local json=""
  json="$(pvesm status -content rootdir --output-format json 2>/dev/null || true)"
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    json="$(pvesm status -content rootdir -json 2>/dev/null || true)"
  fi
  if [[ -n "$json" ]] && printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '
      .[]
      | select(.active == 1)
      | select(((.content // "") | tostring) | contains("rootdir"))
      | [(.storage // .name), (.avail // 0)]
      | @tsv'
    return 0
  fi
  msg_warn "pvesm liefert kein gültiges JSON – nutze Tabellenausgabe mit Einheiten-Erkennung."
  pvesm status -content rootdir 2>/dev/null | awk '
    NR > 1 && $3 == "active" && NF >= 6 {
      n++; names[n] = $1; avail[n] = $6 + 0
      if (avail[n] > max) max = avail[n]
    }
    END {
      mult = (max >= 8589934592) ? 1 : 1024
      for (i = 1; i <= n; i++) printf "%s\t%d\n", names[i], avail[i] * mult
    }'
}

fmt_gib() { # fmt_gib <Bytes> → "123.4"
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'
}

storage_avail_bytes() { # storage_avail_bytes <Name>
  storage_rootdir_list | awk -v s="$1" '$1 == s { print $2; found = 1 } END { exit !found }'
}

select_storage() {
  local -a names=() frees=()
  local name avail

  if [[ -n "$STORAGE" ]] && storage_avail_bytes "$STORAGE" >/dev/null; then
    msg_info "Storage per Env vorgegeben und gültig: ${STORAGE} (frei: $(fmt_gib "$(storage_avail_bytes "$STORAGE")") GB)"
    return 0
  fi
  [[ -z "$STORAGE" ]] || msg_warn "Vorgegebener STORAGE '${STORAGE}' ist nicht aktiv/verfügbar – wähle neu."
  STORAGE=""

  while IFS=$'\t' read -r name avail; do
    names+=("$name")
    frees+=("$avail")
  done < <(storage_rootdir_list)

  ((${#names[@]})) || die "Kein aktiver Storage mit Inhaltstyp 'rootdir' gefunden ('pvesm status' prüfen)."

  if (( ${#names[@]} == 1 )) || [[ ! -t 0 ]]; then
    local best=0 i
    for i in "${!frees[@]}"; do
      (( ${frees[$i]} > ${frees[$best]} )) && best=$i
    done
    STORAGE="${names[$best]}"
    msg_info "Storage automatisch gewählt: ${STORAGE} (frei: $(fmt_gib "${frees[$best]}") GB)"
    return 0
  fi

  local i choice
  msg_info "Verfügbare Storages (rootdir):"
  for i in "${!names[@]}"; do
    printf '  %2d) %-20s frei: %s GB\n' "$((i+1))" "${names[$i]}" "$(fmt_gib "${frees[$i]}")" >&2
  done
  choice="$(ask_default "Welchen Storage verwenden?" "1")"
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
    STORAGE="${names[$((choice-1))]}"
  else
    die "Ungültige Storage-Auswahl: ${choice}"
  fi
}

ensure_capacity() {
  local need_bytes=$(( VAR_DISK * 1073741824 ))
  local avail_bytes
  avail_bytes="$(storage_avail_bytes "$STORAGE" 2>/dev/null || true)"
  [[ -n "$avail_bytes" ]] || { msg_warn "Freier Speicher von '${STORAGE}' nicht ermittelbar – Kapazitätscheck übersprungen."; return 0; }
  if (( avail_bytes < need_bytes )); then
    die "Storage '${STORAGE}' hat nur $(fmt_gib "$avail_bytes") GB frei – ${VAR_DISK} GB angefordert (VAR_DISK reduzieren oder anderen Storage wählen)."
  fi
  msg_ok "Kapazität ausreichend: $(fmt_gib "$avail_bytes") GB frei ≥ ${VAR_DISK} GB angefordert."
}

ensure_debian_template() {
  local tmpl
  msg_info "Suche neuestes ${VAR_OS}-${VAR_VERSION}-Standard-Template …"
  pveam update >/dev/null 2>&1 || true
  tmpl="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | sort -rV | head -n1)"
  [[ -n "$tmpl" ]] || die "Kein debian-12-Template gefunden ('pveam available' manuell prüfen)."
  if ! pveam list local 2>/dev/null | grep -qF "local:vztmpl/${tmpl}"; then
    msg_info "Lade Template herunter: ${tmpl} …"
    pveam download local "$tmpl"
  else
    msg_info "Template bereits vorhanden: ${tmpl}"
  fi
  TEMPLATE="$tmpl"
}

validate_settings() {
  if ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || (( WEB_PORT < 1024 || WEB_PORT > 65535 )); then
    die "WEB_PORT muss zwischen 1024 und 65535 liegen (ist: ${WEB_PORT})."
  fi
  [[ "$NET_MODE" == "dhcp" || "$NET_MODE" == "static" ]] || die "NET_MODE muss 'dhcp' oder 'static' sein."
}

resolve_self() {
  local cand="${BASH_SOURCE[0]:-}"
  if [[ -z "$cand" || "$cand" == "bash" || ! -f "$cand" || ! -r "$cand" ]]; then
    cand="$0"
  fi
  if [[ -f "$cand" && -r "$cand" && "$(head -c 2 "$cand" 2>/dev/null)" == "#!" ]]; then
    readlink -f "$cand"
    return 0
  fi
  msg_warn "Script wurde gepipe't (kein lesbares Dateiobjekt) – lade Kopie für den Container-Transfer …"
  fetch_to "${SCRIPT_URL:-$SCRIPT_URL_DEFAULT}" "${TMPDIR_INSTALL}/${APP_ID}-install.sh"
  local path
  path="$(readlink -f "${TMPDIR_INSTALL}/${APP_ID}-install.sh")"
  [[ -s "$path" ]] || die "Heruntergeladene Installer-Kopie fehlt/ist leer: ${path}"
  printf '%s\n' "$path"
}

create_container() {
  msg_info "Erstelle LXC ${APP_ID} (ID ${CTID}, ${VAR_CPU} vCPU / ${VAR_RAM} MB RAM / ${VAR_DISK} GB Disk, unprivileged) …"
  local ct_password
  ct_password="$(openssl rand -hex 8)"
  local tz_args=()
  if [[ -n "${TIMEZONE_OVERRIDE:-}" ]]; then
    tz_args=(--timezone "$TIMEZONE_OVERRIDE")
  elif [[ -r /etc/timezone ]]; then
    tz_args=(--timezone "$(tr -d '[:space:]' </etc/timezone)")
  fi

  pct create "$CTID" "local:vztmpl/${TEMPLATE}" \
    --hostname "$APP_ID" \
    --password "$ct_password" \
    --unprivileged "$CT_TYPE" \
    --cores "$VAR_CPU" \
    --memory "$VAR_RAM" \
    --swap "$VAR_SWAP" \
    --rootfs "${STORAGE}:${VAR_DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},${NET_CFG},firewall=0" \
    --onboot 1 \
    --tags "community-scripts,${APP_ID}" \
    --description "${APP_NAME} – lokale Spracherkennung. Web-UI: http://<CT-IP>:${WEB_PORT} · Installer: bash -c \$(wget -qLO - ${SCRIPT_URL:-$SCRIPT_URL_DEFAULT})" \
    "${tz_args[@]+"${tz_args[@]}"}" \
    --start 1

  msg_ok "Container erstellt (Konsolen-Passwort einmalig: ${ct_password} – ändern oder 'pct enter ${CTID}' nutzen)."
}

wait_for_ct_ip() {
  local attempts=45 ip="" i
  msg_info "Warte auf Netzwerk im Container …"
  for ((i = 1; i <= attempts; i++)); do
    ip="$(pct exec "$CTID" -- sh -c 'hostname -I 2>/dev/null' 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$ip" ]]; then
      break
    fi
    sleep 2
  done
  [[ -n "$ip" ]] || die "Container hat keine IP erhalten (DHCP/Netzwerk prüfen: pct enter ${CTID})."
  CT_IP="$ip"
  msg_ok "Container-IP: ${CT_IP}"
}

run_guest_phase() {
  local self_path
  self_path="$(resolve_self)"
  [[ "$self_path" != *$'\n'* && -s "$self_path" ]] ||
    die "Interner Fehler: Installer-Pfad ungültig (${self_path@Q})."

  msg_info "Übertrage Installer in den Container (Quelle: ${self_path}) …"
  if ! pct push "$CTID" "$self_path" "/root/${APP_ID}-install.sh" >/dev/null; then
    die "pct push konnte ${self_path} nicht in CT ${CTID} übertragen."
  fi
  if ! pct exec "$CTID" -- test -s "/root/${APP_ID}-install.sh"; then
    die "Installer nach pct push im Container nicht vorhanden/leer (/root/${APP_ID}-install.sh)."
  fi
  # Auch die systemd-Unit mit übertragen (install/diktierbox.service), damit
  # der Gast sie nicht aus dem Netz nachladen muss, falls offline.
  local unit_local="${TMPDIR_INSTALL}/${APP_ID}.service"
  local script_dir
  script_dir="$(dirname "$self_path")"
  if [[ -s "${script_dir}/${APP_ID}.service" ]]; then
    pct push "$CTID" "${script_dir}/${APP_ID}.service" "/root/${APP_ID}.service" >/dev/null \
      || msg_warn "Konnte Unit-Datei nicht übertragen – Gast lädt sie aus dem Repo."
  fi
  rm -f "$unit_local"

  msg_info "Führe Gast-Installation aus (Live-Ausgabe unten; Log im Container: tail -f ${GUEST_LOG_FILE}) …"
  if ! pct exec "$CTID" -- env \
      DB_PHASE=guest \
      MODE="$MODE" \
      WEB_PORT="$WEB_PORT" \
      PRELOAD_MODEL="$PRELOAD_MODEL" \
      CT_IP="$CT_IP" \
      DEBUG="$DEBUG" \
      DEBIAN_FRONTEND=noninteractive \
      LC_ALL=C.UTF-8 LANG=C.UTF-8 \
      bash "/root/${APP_ID}-install.sh"; then
    msg_error "Gast-Phase fehlgeschlagen – Container-Logauszug:"
    pct exec "$CTID" -- tail -n 80 "$GUEST_LOG_FILE" 2>/dev/null || true
    die "Installation im Container fehlgeschlagen (siehe Auszug oben sowie $LOG_FILE)."
  fi
}

do_uninstall() {
  local target="${TARGET_CTID}"
  if [[ -z "$target" ]]; then
    target="$(find_ct_by_name | head -n1 || true)"
  fi
  [[ -n "$target" ]] || die "Kein ${APP_NAME}-Container gefunden (pct list)."
  msg_warn "Deinstalliert ${APP_NAME} inklusive ALLER Daten aus CT ${target}!"
  confirm_or_die "Wirklich löschen? (pct stop + pct destroy ${target})"
  pct stop "$target" >/dev/null 2>&1 || true
  pct destroy --purge "$target"
  msg_ok "Container ${target} entfernt."
}

show_help() {
  cat <<HELP
${APP_NAME} – Proxmox-Installer (Community-Scripts-Stil)

Aufruf:
  bash diktierbox.sh [Optionen]

Optionen:
  --update       Neueste Version im vorhandenen Container installieren
  --uninstall    Container inkl. Daten entfernen (interaktive Bestätigung)
  --ctid N       Vorhandene/vorgesehene CT-ID verwenden bzw. aktualisieren
  --port N       Web-UI-Port (Default: ${WEB_PORT})
  --debug        Volles bash -x-Tracing
  -h | --help    Diese Hilfe

Env-Variablen (Auswahl): CTID VAR_DISK VAR_CPU VAR_RAM VAR_SWAP BRIDGE
  NET_MODE NET_CIDR NET_GW WEB_PORT PRELOAD_MODEL STORAGE DEBUG
  (Defaults stehen im Kopfteil des Scripts.)

Ressourcen-Hinweis: Defaults (${VAR_CPU} vCPU / ${VAR_RAM} MB RAM /
${VAR_DISK} GB Disk) reichen für das small-Modell (487 MB, wie Handy-Standard).
Für large-v3-turbo (per Web-UI nachladbar) werden 4 GB RAM empfohlen
(VAR_RAM=4096 beim Installieren).
HELP
}

parse_args() {
  while (($#)); do
    case "$1" in
      --update) MODE="update" ;;
      --uninstall) MODE="uninstall" ;;
      --debug) DEBUG=1; enable_debug ;;
      --ctid) TARGET_CTID="$(ask_required_value "$1" "${2:-}")"; shift ;;
      --port) WEB_PORT="$(ask_required_value "$1" "${2:-}")"; shift ;;
      -h|--help) show_help; exit 0 ;;
      *) die "Unbekannte Option: $1 (--help anzeigen)" ;;
    esac
    shift
  done
}

host_main() {
  parse_args "$@"
  check_host_prereqs
  validate_settings
  check_upstream_reachable

  if [[ "$MODE" == "uninstall" ]]; then
    do_uninstall
    return 0
  fi

  cat <<'BANNER'
  ____  _ _   _           ____
 |  _ \(_| | | |_ _   _  / ___|  ___  ____  _ __ __      _
 | | | | | | | | | | | | \___ \ / _ \| _ \| '__/ _` |   | |
 | |_| | | |_| | | |_| |  ___) | (_) | |_| | | | (_| |   |_|
 |____/|_|\__,_|_|\__, | |____/ \___/| __/|_|  \__,_|  |(_)
                  |___/             |_|
  Diktierbox – Proxmox-LXC-Installer (Community-Scripts-Stil)
  Lokale Spracherkennung über whisper.cpp + Handys öffentliche Modelle
BANNER

  # Existierenden Container erkennen → idempotent in den Update-Pfad schwenken
  local existing
  existing="$(find_ct_by_name | head -n1 || true)"
  if [[ -n "${TARGET_CTID}" ]]; then
    CTID="$TARGET_CTID"
    if [[ -n "$existing" && "$existing" != "$CTID" ]]; then
      msg_warn "Gefundener ${APP_ID}-Container hat ID ${existing}, gewünscht ist ${CTID}."
    fi
  elif [[ -n "$existing" ]]; then
    CTID="$existing"
  fi

  if [[ -n "$existing" && "$MODE" == "install" ]]; then
    MODE="update"
    msg_info "Vorhandener Container erkannt (ID ${existing}) – wechsle in den Update-Modus."
  fi

  if [[ "$MODE" == "update" ]]; then
    CTID="${CTID:?Keine CT-ID für Update ermittelbar (--ctid angeben)}"
    pct status "$CTID" >/dev/null 2>&1 || die "CT ${CTID} nicht gefunden (pct list)."
    if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
      msg_info "Starte gestoppten Container ${CTID} …"
      pct start "$CTID"
    fi
    wait_for_ct_ip
    run_guest_phase
    msg_ok "Update abgeschlossen → http://${CT_IP}:${WEB_PORT}"
    return 0
  fi

  # Frische Installation: Parameter erfragen
  CTID="${CTID:-$(next_free_ctid)}"
  CTID="$(ask_default "CT-ID" "$CTID")"
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige CT-ID: ${CTID}"
  if pct status "$CTID" >/dev/null 2>&1; then
    die "CT-ID ${CTID} ist bereits vergeben (pct list)."
  fi
  select_storage
  ensure_debian_template
  ensure_capacity

  if [[ "$NET_MODE" == "static" ]]; then
    [[ -n "$NET_CIDR" && -n "$NET_GW" ]] || die "NET_MODE=static benötigt NET_CIDR und NET_GW."
    NET_CFG="ip=${NET_CIDR},gw=${NET_GW}"
  fi

  VAR_DISK="$(ask_default "Disk (GB)" "$VAR_DISK")"
  VAR_CPU="$(ask_default "vCPU-Kerne" "$VAR_CPU")"
  VAR_RAM="$(ask_default "RAM (MB)" "$VAR_RAM")"
  PRELOAD_MODEL="$(ask_default "Modell beim Install laden (leer = nur per Web-UI)" "$PRELOAD_MODEL")"

  create_container
  wait_for_ct_ip
  run_guest_phase

  # Verifikation von außen (vom Proxmox-Host aus)
  msg_info "Verifikation von außen: ${APP_NAME} wirklich erreichbar?"
  local external_ok=0 http_code="" curl_rc=0 health_url="http://${CT_IP}:${WEB_PORT}/api/health"
  local attempt
  for attempt in 1 2 3 4 5; do
    # --noproxy: ein auf dem Host gesetzter http_proxy würde LAN-Requests verfälschen
    http_code="$(curl --noproxy '*' -s -m 5 -o /dev/null -w '%{http_code}' "$health_url" 2>/dev/null)"
    curl_rc=$?
    if [[ "$http_code" == "200" ]]; then
      external_ok=1
      break
    fi
    sleep 2
  done

  cat <<SUCCESS

========================================================================
  Installation abgeschlossen ✔   —   Diktierbox: Diktieren. Lokal. Fertig.
------------------------------------------------------------------------
  Web-UI   :  http://${CT_IP}:${WEB_PORT}
  Container:  ${APP_ID} (ID ${CTID}, unprivileged, onboot=1)
  Einstieg :  pct enter ${CTID}
  Update   :  Einzeiler erneut ausführen (erkennt den Container automatisch)
               oder: bash diktierbox.sh --update
  Deinstall:  bash diktierbox.sh --uninstall
========================================================================

SUCCESS

  if (( external_ok == 0 )); then
    msg_warn "Web-UI war vom Host aus nach ${attempt} Versuchen noch nicht erreichbar"
    msg_warn "(letzter HTTP-Code: ${http_code:-keiner}, curl-rc: ${curl_rc})."
    msg_warn "Diagnose:"
    msg_warn "  pct exec ${CTID} -- systemctl status diktierbox"
    msg_warn "  pct exec ${CTID} -- journalctl -u diktierbox -n 60 --no-pager"
    msg_warn "  pct exec ${CTID} -- ss -tlnp | grep ${WEB_PORT}"
    exit 1
  fi
  msg_ok "Web-UI vom Host aus erreichbar (HTTP 200)."
}

#==============================
# Einstiegspunkt
#==============================
if [[ "$PHASE" == "guest" ]]; then
  # Live auf Konsole UND ins Gast-Log (pct exec Stream).
  exec > >(tee -a "$GUEST_LOG_FILE") 2>&1
  guest_main
else
  SCRIPT_URL="${SCRIPT_URL:-$SCRIPT_URL_DEFAULT}"
  host_main "$@"
fi
