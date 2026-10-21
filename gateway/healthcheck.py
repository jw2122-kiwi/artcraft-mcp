"""Healthcheck fuer den ArtCraft-Gateway.

Prueft, ob der HTTP-Endpunkt antwortet. Ein regulaeres GET auf /mcp liefert
406 (der MCP-Transport akzeptiert nur die richtigen Accept-Header), deshalb
wird ein minimales initialize gesendet.

Der Check akzeptiert bewusst auch 401: mit gesetztem Bearer-Token antwortet
der Gateway korrekt mit "Unauthorized" - das Gateway laeuft dann, der Check
darf es aber nicht als ungesund melden.
"""

import json
import os
import sys
import urllib.error
import urllib.request

PORT = os.environ.get("MCP_PORT", "8000")
URL = f"http://127.0.0.1:{PORT}/mcp"

PAYLOAD = json.dumps(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "healthcheck", "version": "1"},
        },
    }
).encode()

request = urllib.request.Request(
    URL,
    data=PAYLOAD,
    headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read(4096).decode("utf-8", "replace")
        if response.status != 200:
            sys.exit(1)
        if "serverInfo" not in body and "result" not in body:
            print(f"unerwartete Antwort: {body[:200]}", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
except urllib.error.HTTPError as exc:
    if exc.code == 401:
        # Auth ist aktiv - das Gateway laeuft.
        sys.exit(0)
    print(f"HTTP {exc.code}", file=sys.stderr)
    sys.exit(1)
except Exception as exc:  # noqa: BLE001 - der Check meldet jeden Fehler
    print(f"Fehler: {type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(1)
