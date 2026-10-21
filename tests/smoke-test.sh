#!/usr/bin/env bash
# smoke-test.sh - prueft das gebaute Image.
#
# Startet den Container, fragt die Werkzeugliste ab und testet einen echten
# Dokument-Durchlauf: anlegen, Text tippen, zuruecklesen, speichern. Danach
# wird geprueft, dass ein Schreibversuch ausserhalb des Arbeitsverzeichnisses
# abgelehnt wird.
#
# Aufruf: ./tests/smoke-test.sh [image] [platform]

set -uo pipefail

IMAGE="${1:-ghcr.io/jw2122-kiwi/artcraft-mcp:latest}"
PLATFORM="${2:-linux/amd64}"
PORT="${PORT:-8897}"
WORK_DIR="$(mktemp -d)"
CONTAINER="artcraft-smoke-$$"

# Der Container laeuft als uid 1000. mktemp erzeugt ein Verzeichnis mit
# Modus 700 im Besitz des Host-Users - da kann der Container nicht
# hineinwechseln. Der Test laeuft deshalb mit der UID des Host-Users.
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  echo "FEHLER: $*" >&2
  exit 1
}

ok() {
  echo "  ok: $*"
}

echo "== Image: $IMAGE ($PLATFORM) =="

docker run --rm --platform "$PLATFORM" "$IMAGE" sh -c \
  'uname -m; for c in /opt/craft/*/; do n=$(basename "$c"); "$c$n-cli" --version 2>/dev/null | head -1; done' \
  || fail "Container startet nicht"

docker run -d --name "$CONTAINER" --platform "$PLATFORM" \
  -p "127.0.0.1:${PORT}:8000" \
  --user "${HOST_UID}:${HOST_GID}" \
  -v "${WORK_DIR}:/work" \
  "$IMAGE" >/dev/null || fail "Container startet nicht"

echo "-- warte auf den Gateway --"
# Unter QEMU-Emulation braucht der Gateway deutlich laenger als auf nativem
# Hardware. Deshalb wird gewartet, bis eine echte initialize-Antwort kommt.
ready=0
for _ in $(seq 1 90); do
  if curl -fsS -o /dev/null -X POST "http://127.0.0.1:${PORT}/mcp" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
      2>/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "--- Container-Log ---" >&2
  docker logs "$CONTAINER" >&2 || true
  fail "Gateway antwortet nicht auf $PORT"
fi
echo "  ok: Gateway antwortet"

python3 - "$PORT" "$WORK_DIR" <<'PY' || exit 1
import json
import os
import sys
import urllib.request

port, work_dir = sys.argv[1], sys.argv[2]

# Der Streamable-HTTP-Transport vergibt eine Session-ID; alle weiteren
# Anfragen einer Session muessen sie mitschicken.
session_id = None


def rpc(method, params, request_id):
    global session_id
    body = json.dumps(
        {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    ).encode()
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session_id:
        headers["mcp-session-id"] = session_id
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/mcp", data=body, headers=headers
    )
    with urllib.request.urlopen(req, timeout=180) as response:
        if not session_id:
            session_id = response.headers.get("mcp-session-id")
        raw = response.read().decode()
    # Der Server darf entweder JSON oder ein SSE-Event zurueckgeben. Die
    # SSE-Zeilen enden auf \r\n, deshalb muss vor dem Vergleich das \r weg.
    if raw.startswith("event:") or raw.startswith("data:"):
        raw = "".join(
            line[len("data: "):]
            for line in raw.replace("\r\n", "\n").splitlines()
            if line.startswith("data: ")
        )
    payload = json.loads(raw)
    if "error" in payload:
        raise SystemExit(f"RPC-Fehler {method}: {payload['error']}")
    return payload.get("result", {})


def call(tool, arguments, request_id):
    return rpc("tools/call", {"name": tool, "arguments": arguments}, request_id)


rpc("initialize", {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "smoke", "version": "1"},
}, 1)

tools = rpc("tools/list", {}, 2)["tools"]
names = {t["name"] for t in tools}
print(f"  ok: {len(tools)} Werkzeuge")

if not any(n.startswith("word_") for n in names):
    raise SystemExit("FEHLER: keine word_*-Werkzeuge")
print("  ok: word_*-Werkzeuge vorhanden")

# Echter Dokument-Durchlauf
call("word_new_document", {"template": "blank"}, 10)
call("word_type_text", {"text": "smoke test"}, 11)
text = call("word_get_text", {}, 12)
content = text["content"][0]["text"]
if "smoke test" not in content:
    raise SystemExit(f"FEHLER: Text nicht lesbar: {content[:200]!r}")
print("  ok: Dokument erstellt, Text geschrieben und gelesen")

saved = call("word_save_document", {"path": "smoke.docx"}, 13)
if "saved" not in saved["content"][0]["text"]:
    raise SystemExit("FEHLER: Speichern fehlgeschlagen")
print("  ok: Dokument gespeichert")

# Confinement: ein Schreibversuch ausserhalb des Arbeitsverzeichnisses muss
# abgelehnt werden. Die App meldet das als Ergebnis mit isError - nicht als
# Protokollfehler.
escape = call("word_save_document", {"path": "/tmp/escape.docx"}, 14)
if not escape.get("isError"):
    raise SystemExit("FEHLER: Schreibversuch ausserhalb des Roots wurde erlaubt")
if "outside the write root" not in escape["content"][0]["text"]:
    raise SystemExit(
        f"FEHLER: unerwartete Fehlermeldung: {escape['content'][0]['text'][:200]!r}"
    )
print("  ok: Schreibversuch ausserhalb des Roots abgelehnt")

# Datei muss auf dem Host liegen
if not os.path.exists(os.path.join(work_dir, "smoke.docx")):
    raise SystemExit("FEHLER: smoke.docx liegt nicht im Arbeitsverzeichnis")
print("  ok: Ausgabedatei im gemounteten Verzeichnis")
PY

echo "== alle Pruefungen bestanden =="
