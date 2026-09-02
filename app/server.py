#!/usr/bin/env python3
"""Diktierbox – lokale Speech-to-Text-Web-App (whisper.cpp-Engine).

Nachbau der Handy-Kernfunktion (cjpais/Handy) als Server-Web-App:
Transkription per Mikrofon (Web-UI, POST /api/transcribe) oder Datei-
Upload, vollständig lokal im LXC. Verwendet dieselbe Engine-Familie
(transcribe-cpp/whisper.cpp) und Handys öffentliche Whisper-Modelle
(blob.handy.computer).

Endpunkte:
  GET  /                     Web-UI
  GET  /api/health           Health-Check (vom Installer verifiziert)
  GET  /api/models           Modelle: verfügbar/fehlt + Download-Status
  POST /api/models/download  {name}  → Modell im Hintergrund laden
  POST /api/models/{name}/delete  → Modell löschen
  GET  /api/config           Aktuelle Konfiguration (Modell/Sprache/…)
  POST /api/config           {model, language, vad} setzen
  POST /api/transcribe       audio/wav|webm|mp3|… → {text, segments, …}
  GET  /api/history          Letzte Transkriptionen (Tag-Datei)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import signal
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ---------------------------------------------------------------------------
# Konfiguration (Environment, vom systemd-Service gesetzt)
# ---------------------------------------------------------------------------
APP_ROOT = Path(os.environ.get("DIKTIERBOX_APP_ROOT", "/opt/diktierbox"))
STATIC_DIR = Path(os.environ.get("DIKTIERBOX_STATIC_DIR", APP_ROOT / "static"))
DATA_DIR = Path(os.environ.get("DIKTIERBOX_DATA_DIR", "/var/lib/diktierbox"))
MODELS_DIR = Path(os.environ.get("DIKTIERBOX_MODELS_DIR", DATA_DIR / "models"))
TMP_DIR = Path(os.environ.get("DIKTIERBOX_TMP_DIR", DATA_DIR / "tmp"))
HISTORY_DIR = Path(os.environ.get("DIKTIERBOX_HISTORY_DIR", DATA_DIR / "history"))
HISTORY_MAX_ENTRIES = int(os.environ.get("DIKTIERBOX_HISTORY_MAX", "200"))
WHISPER_BIN = os.environ.get("DIKTIERBOX_WHISPER_BIN", "/usr/local/bin/whisper-cli")
VAD_MODEL = os.environ.get("DIKTIERBOX_VAD_MODEL", "")  # leer → ohne VAD laufen
FFMPEG_BIN = os.environ.get("DIKTIERBOX_FFMPEG_BIN", "/usr/bin/ffmpeg")
DEFAULT_MODEL = os.environ.get("DIKTIERBOX_DEFAULT_MODEL", "ggml-small.bin")
DEFAULT_LANGUAGE = os.environ.get("DIKTIERBOX_LANGUAGE", "auto")
ALLOW_UNSAFE_WHISPER = os.environ.get("DIKTIERBOX_ALLOW_UNSAFE", "1") == "1"

# Modell-Quellen: primär Handys öffentliche Whisper-Modelle (blob.handy.computer),
# Fallback die offiziellen whisper.cpp-Modelle auf HuggingFace (gggerganov/whisper.cpp)
# – identische GGML-Dateien, werden von derselben Engine gelesen.
# Schlüssel = Dateiname im models/-Ordner.
MODELS: dict[str, dict[str, Any]] = {
    "ggml-small.bin": {
        "label": "Whisper Small",
        "urls": [
            "https://blob.handy.computer/ggml-small.bin",
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        ],
        "size_mb": 487,
        "ram_mb": 900,
    },
    "ggml-medium-q5_0.bin": {
        "label": "Whisper Medium (q5_0)",
        "urls": [
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin",
        ],
        "size_mb": 514,
        "ram_mb": 1700,
    },
    "ggml-large-v3-turbo.bin": {
        "label": "Whisper Large v3 Turbo",
        "urls": [
            "https://blob.handy.computer/ggml-large-v3-turbo.bin",
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        ],
        "size_mb": 1600,
        "ram_mb": 3600,
    },
    "ggml-large-v3-q5_0.bin": {
        "label": "Whisper Large v3 (q5_0)",
        "urls": [
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin",
        ],
        "size_mb": 1100,
        "ram_mb": 2800,
    },
}

DOWNLOADS: dict[str, dict[str, Any]] = {}  # name -> {state, progress, error}
_downloads_lock = threading.Lock()
_transcribe_lock = threading.Lock()  # nur 1 Inferenz gleichzeitig (RAM-Schutz)

CONFIG_FILE = DATA_DIR / "config.json"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
log = logging.getLogger("diktierbox")

app = FastAPI(title="Diktierbox", docs_url="/api/docs", openapi_url="/api/openapi.json")

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
def mkdirs() -> None:
    for d in (DATA_DIR, MODELS_DIR, TMP_DIR, HISTORY_DIR):
        d.mkdir(parents=True, exist_ok=True)


def load_config() -> dict[str, Any]:
    cfg: dict[str, Any] = {"model": DEFAULT_MODEL, "language": DEFAULT_LANGUAGE, "vad": True}
    if CONFIG_FILE.exists():
        try:
            cfg.update(json.loads(CONFIG_FILE.read_text(encoding="utf-8")))
        except Exception as exc:  # noqa: BLE001 – defekte Config darf App nicht killen
            log.warning("config.json unlesbar (%s) – nutze Defaults", exc)
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    CONFIG_FILE.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")


mkdirs()
CONFIG = load_config()


def model_path(name: str) -> Path:
    return MODELS_DIR / name


def model_exists(name: str) -> bool:
    return name in MODELS and model_path(name).is_file()


def require_model(name: str) -> Path:
    if not model_exists(name):
        raise HTTPException(status_code=409, detail=f"Modell '{name}' nicht vorhanden – bitte zuerst herunterladen.")
    return model_path(name)


def check_whisper_binary() -> None:
    if not Path(WHISPER_BIN).is_file():
        raise HTTPException(status_code=503, detail=f"whisper-cli fehlt unter {WHISPER_BIN} (Installation prüfen).")


def fmt_ts(ts: float) -> str:
    mins, secs = divmod(int(ts), 60)
    hours, mins = divmod(mins, 60)
    return f"{hours:02d}:{mins:02d}:{secs:02d}"


def is_probably_valid_model(path: Path, expected_mb: int) -> bool:
    try:
        size = path.stat().st_size
    except OSError:
        return False
    return size >= max(expected_mb * 1024 * 1024 * 0.95, 1024)


def sanitize_audio_file(suffix: str) -> tuple[Path, Path]:
    """Erzeugt Eingabe-/Ziel-Pfade für einen Upload mit sicherem Namen."""
    if suffix and len(suffix) <= 10 and all(c.isalnum() or c in ".-_" for c in suffix):
        raw_name = f"upload-{uuid.uuid4().hex}{suffix}"
    else:
        raw_name = f"upload-{uuid.uuid4().hex}.bin"
    src = TMP_DIR / raw_name
    dst = TMP_DIR / f"{uuid.uuid4().hex}.wav"
    return src, dst


# ---------------------------------------------------------------------------
# Modell-Downloads (Hintergrund-Threads, Fortschritt via /api/models)
# ---------------------------------------------------------------------------
def download_model(name: str) -> None:
    info = MODELS.get(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Unbekanntes Modell: {name}")

    with _downloads_lock:
        state = DOWNLOADS.get(name, {}).get("state")
        if state == "running":
            raise HTTPException(status_code=409, detail="Download läuft bereits.")
        DOWNLOADS[name] = {"state": "running", "progress": 0.0, "error": None}

    def worker() -> None:
        dest = model_path(name)
        part = Path(f"{dest}.part")
        total = info["size_mb"] * 1024 * 1024
        errors: list[str] = []
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            # curl statt urllib/requests: robuster bei großen Dateilen, zeigt
            # Fortschritt über stderr und unterstützt Retry.
            # Nacheinander alle Quellen probieren (primär blob.handy.computer,
            # Fallback HuggingFace), bis eine liefert.
            for url in info["urls"]:
                if part.exists():
                    part.unlink()
                cmd = [
                    "curl", "-fsSL", "--retry", "2", "--retry-delay", "2",
                    "--connect-timeout", "15", "-o", str(part), url,
                ]
                proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                while proc.poll() is None:
                    try:
                        cur = part.stat().st_size
                    except OSError:
                        cur = 0
                    with _downloads_lock:
                        DOWNLOADS[name]["progress"] = round(min(cur / total, 1.0) * 100, 1)
                    time.sleep(0.5)
                stderr = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
                if proc.returncode == 0 and is_probably_valid_model(part, info["size_mb"]):
                    break  # erfolgreich
                errors.append(f"{url} → curl rc={proc.returncode}: {stderr.strip()[:200] or 'Datei zu klein/ungültig'}")
                log.warning("Modell-Download von %s fehlgeschlagen, probiere nächste Quelle: %s", url, errors[-1])
            else:
                raise RuntimeError("Alle Quellen fehlgeschlagen: " + " | ".join(errors[:3]))
            part.replace(dest)
            with _downloads_lock:
                DOWNLOADS[name] = {"state": "done", "progress": 100.0, "error": None}
            log.info("Modell %s geladen (%s MB)", name, info["size_mb"])
        except Exception as exc:  # noqa: BLE001 – Fehler dem User zeigen, nicht crashen
            part.unlink(missing_ok=True)
            with _downloads_lock:
                DOWNLOADS[name] = {"state": "error", "progress": 0.0, "error": str(exc)}
            log.error("Modell-Download %s fehlgeschlagen: %s", name, exc)

    threading.Thread(target=worker, daemon=True).start()


# ---------------------------------------------------------------------------
# Transkription
# ---------------------------------------------------------------------------
@dataclass
class TranscribeResult:
    text: str
    segments: list[dict[str, Any]]
    language: str
    model: str
    duration_audio_s: float
    elapsed_s: float


def convert_to_wav(src: Path, dst: Path) -> float:
    """ffmpeg: beliebiges Browser/Audio-Format → 16-kHz-Mono-WAV."""
    cmd = [
        FFMPEG_BIN, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src), "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(dst),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise HTTPException(
            status_code=400,
            detail=f"ffmpeg konnte Audio nicht konvertieren (rc={proc.returncode}): {proc.stderr.strip()[:800]}",
        )
    try:
        probe = subprocess.run(
            [FFMPEG_BIN, "-hide_banner", "-i", str(dst)],
            capture_output=True, text=True, timeout=30,
        )
        for line in probe.stderr.splitlines():
            if "Duration" in line and ":" in line:
                parts = line.split("Duration:")[1].split(",")[0].strip().split(":")
                return float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
    except Exception as exc:  # noqa: BLE001
        log.warning("Duration-Erkennung fehlgeschlagen: %s", exc)
    return 0.0


def run_whisper(wav: Path, model: str, language: str, vad: bool) -> TranscribeResult:
    check_whisper_binary()
    mpath = require_model(model)
    out_base = TMP_DIR / f"whisper-out-{uuid.uuid4().hex}"
    cmd = [WHISPER_BIN, "-m", str(mpath), "-f", str(wav), "-otxt", "-oj", "-of", str(out_base)]
    if language and language != "auto":
        cmd += ["-l", language]
    if vad:
        if VAD_MODEL and Path(VAD_MODEL).is_file():
            cmd += ["--vad", "--vad-model", VAD_MODEL]
        else:
            log.info("VAD angefordert, aber kein VAD-Modell vorhanden – transskribiere ohne VAD.")
    if ALLOW_UNSAFE_WHISPER:
        cmd += ["--no-gpu"]

    # Inferenz serialisieren: 2 parallele Whisper-Prozesse würden den RAM des
    # kleinen LXC sprengen. Gesundheit/Downloads bleiben nebenbei erreichbar.
    t_wait_start = time.monotonic()
    while not _transcribe_lock.acquire(blocking=False):
        if time.monotonic() - t_wait_start > 7200:
            raise HTTPException(status_code=503, detail="Server ausgelastet – bitte später erneut versuchen.")
        time.sleep(0.5)

    t0 = time.monotonic()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=504, detail=f"whisper-cli Timeout nach {exc.timeout}s") from exc
    finally:
        _transcribe_lock.release()
    elapsed = time.monotonic() - t0

    if proc.returncode != 0:
        # Vollständige Fehlermeldungskette ins Log + API-Antwort
        log.error(
            "whisper-cli rc=%d | cmd=%s | stderr=%s | stdout(tail)=%s",
            proc.returncode, " ".join(cmd), proc.stderr[-2000:], proc.stdout[-2000:],
        )
        raise HTTPException(
            status_code=500,
            detail={
                "error": "whisper-cli fehlgeschlagen",
                "exit_code": proc.returncode,
                "command": cmd,
                "stderr": proc.stderr[-2000:],
                "stdout_tail": proc.stdout[-2000:],
            },
        )

    text_file = out_base.with_suffix(".txt")
    json_file = out_base.with_suffix(".json")
    try:
        text = text_file.read_text(encoding="utf-8").strip() if text_file.exists() else ""
        segments: list[dict[str, Any]] = []
        lang = language
        if json_file.exists():
            try:
                data = json.loads(json_file.read_text(encoding="utf-8"))
                # whisper.cpp JSON: {transcription:[...], result:{language:...}}
                src_segments = data.get("transcription") or data.get("segments") or []
                for seg in src_segments:
                    if "offsets" in seg:
                        segments.append({
                            "start": seg["offsets"]["from"] / 100.0,
                            "end": seg["offsets"]["to"] / 100.0,
                            "text": (seg.get("text") or "").strip(),
                            "timestamps": seg.get("timestamps", ""),
                        })
                lang = data.get("result", {}).get("language", language)
            except Exception as exc:  # noqa: BLE001
                log.warning("whisper-JSON unlesbar: %s", exc)
    finally:
        for f in (text_file, json_file):
            f.unlink(missing_ok=True)

    return TranscribeResult(
        text=text,
        segments=segments,
        language=lang,
        model=model,
        duration_audio_s=0.0,
        elapsed_s=elapsed,
    )


def append_history(entry: dict[str, Any]) -> None:
    day = datetime.now().strftime("%Y-%m-%d")
    path = HISTORY_DIR / f"{day}.jsonl"
    entry["ts"] = datetime.now().isoformat(timespec="seconds")
    try:
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
        # Rotation: nur die letzten N Einträge pro Tag behalten
        lines = path.read_text(encoding="utf-8").splitlines()
        if len(lines) > HISTORY_MAX_ENTRIES:
            path.write_text("\n".join(lines[-HISTORY_MAX_ENTRIES:]) + "\n", encoding="utf-8")
    except Exception as exc:  # noqa: BLE001 – Historie darf Kernfunktion nicht blockieren
        log.warning("Historie nicht schreibbar: %s", exc)


def cleanup_tmp() -> None:
    for p in TMP_DIR.iterdir():
        try:
            if p.is_file() and p.stat().st_mtime < time.time() - 3600:
                p.unlink()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# API-Routen
# ---------------------------------------------------------------------------
@app.get("/api/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "app": "diktierbox",
        "whisper_bin": Path(WHISPER_BIN).is_file(),
        "ffmpeg": Path(FFMPEG_BIN).is_file(),
        "model": CONFIG.get("model"),
        "model_ready": model_exists(str(CONFIG.get("model"))),
        "models_dir": str(MODELS_DIR),
    }


@app.get("/api/models")
def list_models() -> dict[str, Any]:
    out = []
    for name, info in MODELS.items():
        present = model_exists(name)
        valid = present and is_probably_valid_model(model_path(name), int(info["size_mb"]))
        entry = {
            "name": name,
            "label": info["label"],
            "size_mb": info["size_mb"],
            "ram_mb": info["ram_mb"],
            "urls": info["urls"],
            "present": present,
            "valid": valid,
            **DOWNLOADS.get(name, {"state": "idle", "progress": 0.0, "error": None}),
        }
        out.append(entry)
    return {"models": out, "active_model": CONFIG.get("model")}


@app.post("/api/models/download")
def start_download(body: dict[str, Any]) -> dict[str, Any]:
    name = str(body.get("name") or "")
    if name not in MODELS:
        raise HTTPException(status_code=404, detail=f"Unbekanntes Modell: {name}")
    if model_exists(name) and is_probably_valid_model(model_path(name), int(MODELS[name]["size_mb"])):
        return {"ok": True, "already_present": True}
    download_model(name)
    return {"ok": True, "started": True}


@app.delete("/api/models/{name}")
def delete_model(name: str) -> dict[str, Any]:
    if name not in MODELS:
        raise HTTPException(status_code=404, detail=f"Unbekanntes Modell: {name}")
    if not model_exists(name):
        return {"ok": True, "already_absent": True}
    if str(CONFIG.get("model")) == name:
        raise HTTPException(status_code=409, detail="Aktives Modell kann nicht gelöscht werden – erst anderes Modell wählen.")
    model_path(name).unlink()
    log.info("Modell gelöscht: %s", name)
    return {"ok": True}


@app.get("/api/config")
def get_config() -> dict[str, Any]:
    return {
        **CONFIG,
        "available_models": {k: v["label"] for k, v in MODELS.items()},
    }


@app.post("/api/config")
def set_config(body: dict[str, Any]) -> dict[str, Any]:
    global CONFIG
    model = body.get("model")
    if model is not None:
        if model not in MODELS:
            raise HTTPException(status_code=400, detail=f"Unbekanntes Modell: {model}")
        if not model_exists(str(model)):
            raise HTTPException(status_code=409, detail=f"Modell '{model}' ist nicht heruntergeladen.")
    language = body.get("language")
    if language is not None and not isinstance(language, str):
        raise HTTPException(status_code=400, detail="language muss ein String sein.")
    vad = body.get("vad")
    if vad is not None and not isinstance(vad, bool):
        raise HTTPException(status_code=400, detail="vad muss boolean sein.")

    if model is not None:
        CONFIG["model"] = model
    if language is not None:
        CONFIG["language"] = language or "auto"
    if vad is not None:
        CONFIG["vad"] = vad
    save_config(CONFIG)
    return {"ok": True, "config": CONFIG}


@app.post("/api/transcribe")
async def transcribe(file: UploadFile) -> JSONResponse:
    allowed = {
        "audio/webm", "audio/ogg", "audio/mpeg", "audio/mp3", "audio/mp4",
        "audio/x-m4a", "audio/m4a", "audio/wav", "audio/x-wav", "audio/wave",
        "audio/flac", "audio/x-flac", "audio/aac", "video/webm", "video/mp4",
        "application/ogg",
    }
    ctype = (file.content_type or "").lower()
    suffix = Path(file.filename or "").suffix.lower()
    if ctype and ctype not in allowed and not suffix:
        raise HTTPException(status_code=400, detail=f"Nicht unterstützter Typ: {ctype}")
    if suffix not in {".webm", ".ogg", ".mp3", ".mp4", ".m4a", ".wav", ".flac", ".aac", ".opus", ".weba", ".bin"}:
        suffix = ""  # ffmpeg-sniffed über content oder .bin

    src, dst = sanitize_audio_file(suffix or ".bin")
    try:
        with src.open("wb") as fh:
            while chunk := await file.read(1024 * 1024):
                fh.write(chunk)
        if src.stat().st_size == 0:
            raise HTTPException(status_code=400, detail="Leere Audiodatei empfangen.")
        cleanup_tmp()
        # ffmpeg + whisper-cli sind CPU-blockierend → in Threadpool ausführen,
        # damit /api/health & Co. während der Inferenz erreichbar bleiben.
        loop = asyncio.get_running_loop()
        duration = await loop.run_in_executor(None, lambda: convert_to_wav(src, dst))
        cfg_snapshot = dict(CONFIG)
        result = await loop.run_in_executor(
            None,
            lambda: run_whisper(dst, str(cfg_snapshot.get("model")), str(cfg_snapshot.get("language")), bool(cfg_snapshot.get("vad"))),
        )
        entry = {
            "text": result.text,
            "model": result.model,
            "language": result.language,
            "audio_seconds": round(duration, 1),
            "elapsed_seconds": round(result.elapsed_s, 1),
            "filename": file.filename,
        }
        append_history(entry)
        return JSONResponse({
            **entry,
            "segments": result.segments,
        })
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001 – volle Kette nach außen tragen
        log.exception("Transkription fehlgeschlagen: %s", exc)
        raise HTTPException(status_code=500, detail=f"{type(exc).__name__}: {exc}") from exc
    finally:
        src.unlink(missing_ok=True)
        dst.unlink(missing_ok=True)


@app.get("/api/history")
def get_history() -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    files = sorted(HISTORY_DIR.glob("*.jsonl"), reverse=True)
    for path in files:
        try:
            for line in reversed(path.read_text(encoding="utf-8").splitlines()):
                if not line.strip():
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
                if len(entries) >= HISTORY_MAX_ENTRIES:
                    break
        except OSError:
            continue
        if len(entries) >= HISTORY_MAX_ENTRIES:
            break
    return {"entries": entries}


@app.on_event("shutdown")
def _shutdown() -> None:
    log.info("Diktierbox fährt herunter.")


# Static UI zuletzt mounten – überschattet keine API-Route.
app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("DIKTIERBOX_PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
