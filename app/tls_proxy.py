#!/usr/bin/env python3
"""Minimaler HTTPS-Terminator für Diktierbox (Python stdlib, keine Abhängigkeiten).

Beendet TLS mit dem selbstsignierten Zertifikat und leitet alles an den
lokalen HTTP-uvicorn weiter. Grund: Browser erlauben getUserMedia (Mikrofon)
nur in einem Secure Context (HTTPS oder http://localhost) – auch im privaten
Heimnetz gilt das ohne Ausnahme.

Aufruf:
  tls_proxy.py --listen 0.0.0.0:8443 --upstream http://127.0.0.1:8080 \
               --cert cert.pem --key key.pem
"""

from __future__ import annotations

import argparse
import http.client
import socket
import ssl
import sys
import threading


def log(msg: str) -> None:
    print(f"[tls_proxy] {msg}", flush=True)


def handle(client: socket.socket, upstream_host: str, upstream_port: int) -> None:
    try:
        conn = http.client.HTTPConnection(upstream_host, upstream_port, timeout=600)
        # 1. Request-Zeile + Headers lesen
        request_line = b""
        while not request_line.endswith(b"\r\n"):
            chunk = client.recv(4096)
            if not chunk:
                return
            request_line += chunk
            if len(request_line) > 64 * 1024:
                client.sendall(b"HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n")
                return

        head, _, body_start = request_line.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        method, path, _ = lines[0].decode("latin-1").split(" ", 2)

        headers: dict[str, str] = {}
        for line in lines[1:]:
            if b":" in line:
                k, v = line.split(b":", 1)
                headers[k.decode("latin-1").strip().lower()] = v.decode("latin-1").strip()

        # 2. Body lesen (Content-Length; Chunked wird von stdlib nicht gestreamt
        #    gelesen – bei Uploads senden Browser fast immer Content-Length)
        body = body_start
        if "content-length" in headers:
            need = int(headers["content-length"])
            while len(body) < need:
                chunk = client.recv(65536)
                if not chunk:
                    break
                body += chunk
            body = body[:need]

        # 3. Anfrage weiterleiten (hop-by-hop-Header entfernen)
        upstream_headers = {k: v for k, v in headers.items()
                            if k not in {"connection", "keep-alive", "transfer-encoding",
                                         "upgrade", "proxy-authorization", "proxy-connection"}}
        upstream_headers["connection"] = "close"
        conn.request(method, path, body=body if body else None, headers=upstream_headers)
        resp = conn.getresponse()
        resp_body = resp.read()
        resp_headers = resp.getheaders()

        # 4. Antwort zurückschreiben
        out = [f"HTTP/1.1 {resp.status} {resp.reason}\r\n"]
        for k, v in resp_headers:
            if k.lower() not in {"connection", "transfer-encoding", "keep-alive"}:
                out.append(f"{k}: {v}\r\n")
        out.append("Connection: close\r\n\r\n")
        client.sendall("".join(out).encode("latin-1") + resp_body)
        conn.close()
    except Exception as exc:  # noqa: BLE001 – Proxy darf nicht sterben
        log(f"Fehler bei Verbindung: {type(exc).__name__}: {exc}")
        try:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        except OSError:
            pass
    finally:
        try:
            client.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        client.close()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, help="z.B. 0.0.0.0:8443")
    ap.add_argument("--upstream", required=True, help="z.B. http://127.0.0.1:8080")
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    args = ap.parse_args()

    listen_host, listen_port = args.listen.rsplit(":", 1)
    upstream = args.upstream.removeprefix("http://")
    upstream_host, upstream_port = upstream.rsplit(":", 1)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)

    raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    raw.bind((listen_host, int(listen_port)))
    raw.listen(64)
    log(f"HTTPS-Proxy lauscht auf {args.listen} → {args.upstream}")

    srv = ctx.wrap_socket(raw, server_side=True)
    while True:
        try:
            client, addr = srv.accept()
        except ssl.SSLError as exc:
            log(f"TLS-Handshake fehlgeschlagen von {addr if 'addr' in dir() else '?'}: {exc}")
            continue
        threading.Thread(
            target=handle, args=(client, upstream_host, int(upstream_port)), daemon=True
        ).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
