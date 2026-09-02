# Diktierbox – Lokale Spracherkennung als Web-App für Proxmox LXC

**Diktierbox** bringt die Kernfunktion von [Handy](https://github.com/cjpais/Handy)
(freie, offline Speech-to-Text-App) als **serverbasierte Web-App** auf jeden
Proxmox-Host: Audio aufnehmen oder hochladen → Transkript – überall im LAN
nutzbar, ohne Cloud, ohne Installation auf den Geräten.

- **Engine:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (CPU) – dieselbe
  Engine-Familie, die auch Handy nutzt (`transcribe-cpp`)
- **Modelle:** Handys öffentliche Whisper-Modelle von `blob.handy.computer`
  (small 487 MB · medium 492 MB · large-v3-turbo 1,6 GB · large-v3-q5_0 1,1 GB)
  – weitere jederzeit per Web-UI nachladbar
- **Stille-Filterung:** Silero-VAD wie bei Handy (wird automatisch mitinstalliert)
- **Komplett lokal:** Kein Account, keine Cloud, Audio bleibt im Container

> **Hinweis:** Handy selbst ist eine Desktop-Anwendung (globaler Hotkey, GTK/WebView)
> und kann nicht als Web-Server laufen. Diktierbox ist eine eigenständige Web-App,
> die dieselben öffentlichen Modelle und dieselbe Engine-Familie nutzt –
> kein offizieller Teil des Handy-Projekts. Der Name „Handy" wird nicht verwendet
> (Brandings-Rechte bleiben beim Upstream-Projekt).

---

## Installation (Proxmox VE, Einzeiler)

Auf dem **Proxmox-Host** als root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/install/diktierbox.sh)"
```

Der Installer (Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE)):

1. erstellt automatisch einen **unprivilegierten LXC** (Debian 12, `onboot=1`,
   Standard: 2 vCPU / 2 GB RAM / 12 GB Disk, alles per Dialog/Env anpassbar)
2. kompiliert **whisper.cpp** im Container (~2–5 min)
3. installiert Python/FastAPI-App + **systemd-Service** (`Restart=always`,
   `After=network-online.target`, gehärtet: kein Root, Schreibrechte nur auf `/var/lib/diktierbox`)
4. lädt das **small-Modell (487 MB)** + Silero-VAD-Modell vor
5. verifiziert selbst: Service aktiv, HTTP 200 auf `/api/health`, Listener auf `0.0.0.0`

Am Ende erscheint die fertige URL: **`http://<LXC-IP>:8080`**

### Debug-Installation (volles bash-x-Log)

```bash
DEBUG=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/install/diktierbox.sh)"
```

Bei Fehlern gibt das Script **immer die komplette Fehlermeldungskette** aus:
Exit-Code, fehlgeschlagener Befehl, Aufruf-Stack (`caller`), `systemctl status`,
`journalctl`-Auszug, offene Ports, RAM/Disk, Host- **und** Gast-Log – und zeigt
den Pfad zum mitgeschriebenen Log (`/tmp/diktierbox-install-*.log` auf dem Host,
`/var/log/diktierbox-install.log` im Container).

### Installation anpassen (Env-Variablen)

```bash
# Beispiele – alle Defaults stehen im Kopf von install/diktierbox.sh
CTID=210 VAR_CPU=4 VAR_RAM=4096 VAR_DISK=20 \
PRELOAD_MODEL=ggml-large-v3-turbo.bin \
WEB_PORT=8080 \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/install/diktierbox.sh)"
```

| Variable | Default | Bedeutung |
|---|---|---|
| `CTID` | nächste freie ID | Container-ID |
| `VAR_CPU` / `VAR_RAM` / `VAR_DISK` | 2 / 2048 / 12 | vCPU / MB RAM / GB Disk |
| `PRELOAD_MODEL` | `ggml-small.bin` | Erstdownload (leer = nur per Web-UI laden) |
| `WEB_PORT` | `8080` | Web-UI-Port |
| `STORAGE` | automatisch | Storage mit `rootdir`-Inhalt |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `NET_MODE`/`NET_CIDR`/`NET_GW` | `dhcp` | statische IP statt DHCP |
| `DEBUG` | `0` | `1` = bash-x-Trace |

**Ressourcen-Empfehlung:** small/medium laufen in 2 GB RAM. Für
`ggml-large-v3-turbo.bin` (per Web-UI nachladbar) → `VAR_RAM=4096` (oder mehr)
beim Installieren mitgeben.

---

## Nach der Installation

### Web-UI öffnen

```
http://<LXC-IP>:8080
```

Funktionen der Web-UI (deutsch):

- **Audiodatei hochladen & transkribieren** (webm/opus, mp3, m4a, wav, flac, …) –
  funktioniert von jedem Gerät im LAN
- **Mikrofon-Aufnahme** – nur bei HTTPS oder `http://localhost` (Browser-Regel,
  siehe unten)
- **Transkript** mit Zeitstempel-Segmenten, Copy-Button, Modell- und Sprachauswahl
- **Modell-Verwaltung**: Download (mit Fortschritt), Löschen, RAM-Hinweise
- **Historie** (letzte 200 Einträge, Tag-Dateien unter `/var/lib/diktierbox/history`)

### API (für Automatisierung, Shortcuts, andere Geräte)

```bash
# Transkribieren (z. B. Sprachmemo von einem Telefon/Blob-Speicher)
curl -s -F "file=@sprachmemo.webm" http://LXC-IP:8080/api/transcribe | jq -r .text

# Health-Check
curl -s http://LXC-IP:8080/api/health

# Modelle + Download-Status
curl -s http://LXC-IP:8080/api/models | jq

# Weiteres Modell im Hintergrund laden (erscheint dann in der Web-UI)
curl -X POST -H 'Content-Type: application/json' \
     -d '{"name":"ggml-large-v3-turbo.bin"}' http://LXC-IP:8080/api/models/download
```

Weboberfläche + OpenAPI-Doku: `http://LXC-IP:8080/api/docs`

### Mikrofon über HTTP nutzen (Browser-Regel)

Browser erlauben `getUserMedia` nur bei **HTTPS** oder **`http://localhost`**.
Drei Möglichkeiten ohne HTTPS-Zertifikat:

1. **SSH-Tunnel** (empfohlen, Mikrofon läuft dann lokal im Browser):
   ```bash
   ssh -L 8080:localhost:8080 root@<LXC-IP>
   # dann im Browser: http://localhost:8080
   ```
2. **Datei-Upload** statt Mikrofon (funktioniert überall, auch übers LAN)
3. **API** aus eigenen Skripten/Shortcuts (z. B. iOS-Shortcut → WebDAV → curl)

---

## Reboot-Sicherheit testen (Beleg für die Doku)

```bash
# 1. Service-Status im Container
pct exec <CTID> -- systemctl is-active diktierbox        # → active
pct exec <CTID> -- systemctl is-enabled diktierbox       # → enabled

# 2. Container neu starten (simuliert Proxmox-Host-Reboot)
pct reboot <CTID> && sleep 20

# 3. Wieder erreichbar?
pct exec <CTID> -- systemctl is-active diktierbox        # → active
curl -s http://<LXC-IP>:8080/api/health                   # → {"status":"ok",...}

# 4. Logs, falls etwas nicht kommt
pct exec <CTID> -- journalctl -u diktierbox -n 40 --no-pager
```

**Warum reboot-sicher:**
- Container: `onboot=1` (startet beim Proxmox-Boot automatisch)
- Service: `systemctl enable` (unit aktiviert) + `Restart=always` + `RestartSec=5`
- Unit: `After=network-online.target` + `Wants=network-online.target`
- Modelle/Historie liegen persistent unter `/var/lib/diktierbox` (nicht im tmpfs)

---

## Update & Deinstallation

```bash
# Update: Einzeiler erneut ausführen – der Installer erkennt den vorhandenen
# Container (Hostname diktierbox) automatisch und aktualisiert idempotent:
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DiktierBoxProxmox/main/install/diktierbox.sh)"

# oder klassisch:
./diktierbox.sh --update

# Deinstallation (Container inkl. aller Daten, mit Bestätigung):
./diktierbox.sh --uninstall
# bzw. manuell: pct stop <CTID> && pct destroy <CTID> --purge
```

Update-Verhalten: App-Code, venv, systemd-Unit und VAD-Modell werden erneuert;
**Modelle, Historie und config.json bleiben erhalten.** whisper-cli wird nur
neu gebaut, wenn es fehlt.

---

## Projektstruktur

```
install/diktierbox.sh      # Proxmox-Installer (Community-Scripts-Stil, Host-+Gast-Phase)
install/diktierbox.service # systemd-Unit (identischer Stand wird installiert)
app/server.py              # FastAPI-Backend (ffmpeg → whisper-cli, Modelle, Historie)
app/static/index.html      # Web-UI (vanilla HTML/CSS/JS, deutsch)
```

Dauerhafte Pfade im Container: App `/opt/diktierbox` · Daten `/var/lib/diktierbox`
(Modelle, tmp, Historie, config.json) · Logs `journalctl -u diktierbox` +
`/var/log/diktierbox-install.log` (Installation).

---

## Testnachweis (Sandbox-E2E, Debian-artige Umgebung)

| Prüfung | Ergebnis |
|---|---|
| `bash -n` + `shellcheck -x` Installer | 0 Findings |
| `py_compile` server.py | OK |
| whisper.cpp 1.9.3-dev Build (cmake, CPU) | OK |
| Modell-Download ggml-small.bin (487 MB, blob.handy.computer) | OK |
| `GET /api/health` | `{"status":"ok",...}` HTTP 200 |
| `POST /api/transcribe` (jfk.wav, 16 kHz WAV) | korrektes Transkript, HTTP 200 |
| `POST /api/transcribe` (jfk.webm, opus – Browser-Mikrofonformat) | korrektes Transkript, HTTP 200 |
| Health/Models **während** laufender Inferenz | 200 in ~3 ms (Event-Loop blockiert nicht) |
| Ungültige Audiodatei | HTTP 400 + vollständige ffmpeg-Fehlermeldung |
| Nicht geladenes Modell aktivieren | HTTP 409 mit klaren Detailtext |
| Zeitstempel-Segmente aus whisper-JSON | korrekt geparst |

*Hinweis zu den Zeiten: Die Sandbox-CPU ist stark gedrosselt (11 s Audio ≈ 6–7 min
Inferenz). Auf normaler Server-Hardware liegt small typischerweise nahe oder
über Echtzeitgeschwindigkeit.*

---

## Lizenz / Credits

- Diese Sammlung (Installer, Web-App, UI): MIT
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) · Silero-VAD-Modelle
  (ggml-org/whisper-vad) · Whisper-Modelle via `blob.handy.computer`
  (bereitgestellt vom [Handy](https://github.com/cjpais/Handy)-Projekt, MIT)
- Diktierbox ist **kein offizielles** Handy-Derivat; Brandings von Handy bleiben
  unberührt. Siehe README von Handy zu Marken/Logos.
