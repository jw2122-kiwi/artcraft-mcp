"""ArtCraft MCP Gateway.

Die Craft-Apps (github.com/storytold) liefern jedes ein eigenes CLI, das den
MCP-Server ueber stdio anbietet. Dieses Gateway nimmt die stdio-Server hinter
einer Streamable-HTTP-Schnittstelle zusammen, damit ein MCP-Client (OpenCode,
Claude, ...) ueber eine URL darauf zugreifen kann.

Pro App wird das CLI als eigener Subprozess gestartet. Der Prozess haelt den
Zustand des Dokuments (offenes Dokument, Undo-Historie, Auswahl). Deshalb
bekommt jeder MCP-Client-Session einen eigenen Satz von Subprozessen: sonst
wuerden sich zwei Clients gegenseitig in die Dokumente schreiben.

Werkzeugnamen werden mit dem App-Namen praefigiert, damit die Apps sich nicht
gegenseitig ueberschreiben: word_new_document, deck_new_presentation, ...
"""

from __future__ import annotations

import logging
import os
import secrets
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from fastmcp import FastMCP
from fastmcp.client.transports import StdioTransport
from fastmcp.server.proxy import FastMCPProxy, StatefulProxyClient
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

logger = logging.getLogger("artcraft-gateway")

APPS_DIR = Path(os.environ.get("CRAFT_APPS_DIR", "/opt/craft"))
WORK_DIR = Path(os.environ.get("CRAFT_WORK_DIR", "/work"))
MANIFEST = APPS_DIR / "manifest.txt"

# Praefix, unter dem die Werkzeuge einer App erscheinen. Kurz genug, um
# lesbar zu bleiben, aber eindeutig genug, um Verwechslungen auszuschliessen.
PREFIXES = {
    "wordcraft": "word",
    "deckcraft": "deck",
    "gridcraft": "grid",
    "photocraft": "photo",
    "pdfcraft": "pdf",
    "vectorcraft": "vector",
    "lightcraft": "light",
    "filmcraft": "film",
    "designcraft": "design",
    "effectcraft": "effect",
    "cadcraft": "cad",
    "soundcraft": "sound",
    "figcraft": "fig",
}


@dataclass(frozen=True)
class CraftApp:
    """Eine installierte Craft-App."""

    name: str
    version: str
    # True, wenn das CLI --automation-read-root/--automation-write-root kennt.
    # Ohne diese Flags kann die App nicht auf ein Verzeichnis eingesperrt
    # werden; die Container-Grenze bleibt dann die einzige Schranke.
    confined: bool

    @property
    def prefix(self) -> str:
        return PREFIXES.get(self.name, self.name)

    @property
    def binary(self) -> Path:
        return APPS_DIR / self.name / f"{self.name}-cli"

    def mcp_args(self) -> list[str]:
        args = ["mcp"]
        if self.confined:
            # Die App darf nur innerhalb des Arbeitsverzeichnisses lesen und
            # schreiben. Ohne gesetzte Roots fehlt der App diese Berechtigung
            # vollstaendig, deshalb sind beide Roots Pflicht.
            args += [
                "--automation-read-root",
                str(WORK_DIR),
                "--automation-write-root",
                str(WORK_DIR),
            ]
        return args

    def mcp_cwd(self) -> str | None:
        """Das Arbeitsverzeichnis als Startverzeichnis der CLI.

        Die Apps legen dort ihre Hilfsdateien ab. Ist das Verzeichnis fuer
        den Container-User nicht betretbar (z.B. weil es dem Host-User mit
        Modus 700 gehoert), laeuft die App ohne Startverzeichnis - der
        Gateway meldet das beim Start, statt still zu scheitern.
        """
        try:
            if os.access(WORK_DIR, os.R_OK | os.X_OK):
                return str(WORK_DIR)
        except OSError:
            pass
        return None


def load_apps() -> list[CraftApp]:
    """Liest das Manifest, das der Installer beim Image-Bau geschrieben hat."""
    if not MANIFEST.exists():
        logger.warning("kein Manifest unter %s - keine Apps verfuegbar", MANIFEST)
        return []

    apps: list[CraftApp] = []
    for line in MANIFEST.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(":")
        if len(parts) != 3:
            logger.warning("Manifest-Zeile uebersprungen: %r", line)
            continue
        name, version, confined = parts
        app = CraftApp(name=name, version=version, confined=confined == "yes")
        if not app.binary.exists():
            logger.warning("%s: CLI fehlt unter %s - App wird uebersprungen", name, app.binary)
            continue
        apps.append(app)
    return apps


def build_server(apps: list[CraftApp]) -> FastMCP:
    """Baut den Gateway-Server mit einer App-Mount je Craft-App."""
    mcp = FastMCP(
        "artcraft",
        instructions=(
            "ArtCraft Crafting Apps: freie Rust-Implementierungen von Word, "
            "PowerPoint, Excel, Photoshop, Illustrator, PDF, Lightroom, Premiere, "
            "InDesign, After Effects, AutoCAD, Pro Tools und Figma. Jede App hat "
            "eigene Werkzeuge mit App-Praefix (word_*, deck_*, photo_*). "
            "Die Apps arbeiten headless auf Dateien im Arbeitsverzeichnis."
        ),
    )

    for app in apps:
        # StatefulProxyClient: der Client wird pro Server-Session geteilt, damit
        # der Dokumentzustand zwischen den Werkzeugaufrufen erhalten bleibt.
        # Ohne das wuerde jeder Aufruf ein neues, leeres Dokument sehen.
        transport = StdioTransport(
            command=str(app.binary),
            args=app.mcp_args(),
            cwd=app.mcp_cwd(),
        )
        proxy_client = StatefulProxyClient(transport)
        proxy = FastMCPProxy(client_factory=proxy_client.new_stateful, name=app.name)
        mcp.mount(proxy, prefix=app.prefix)
        logger.info(
            "App %s (%s) eingebunden als %s_* %s",
            app.name,
            app.version,
            app.prefix,
            "confinement: read/write root gesetzt" if app.confined else "kein confinement verfuegbar",
        )

    return mcp


class BearerAuthMiddleware(BaseHTTPMiddleware):
    """Prueft ein optionales Bearer-Token vor allen MCP-Anfragen.

    Ist kein Token gesetzt, laeuft der Gateway ohne Authentifizierung. Das ist
    nur sinnvoll, solange der Port an 127.0.0.1 gebunden ist (Voreinstellung)
    oder Caddy davorsteht. Fuer den Zugriff aus dem Netz sollte immer ein
    Token gesetzt sein.
    """

    def __init__(self, app: Any, token: str) -> None:
        super().__init__(app)
        self._token = token

    async def dispatch(self, request: Request, call_next: Any) -> Any:
        header = request.headers.get("authorization", "")
        expected = f"Bearer {self._token}"
        # compare_digest vermeidet eine zeitbasierte Luecke. Es wirft aber
        # TypeError, wenn eine der Zeichenketten Nicht-ASCII enthaelt - ein
        # manipulierter Header wuerde dann als 500 statt als 401 enden.
        try:
            authorized = secrets.compare_digest(header, expected)
        except TypeError:
            authorized = False
        if not authorized:
            return JSONResponse(
                {"error": "unauthorized"},
                status_code=401,
                headers={"WWW-Authenticate": "Bearer"},
            )
        return await call_next(request)


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    WORK_DIR.mkdir(parents=True, exist_ok=True)

    # Das Arbeitsverzeichnis muss fuer den Container-User betretbar sein.
    # Sonst starten die Apps nicht und der Endpoint liefert eine leere
    # Werkzeugliste - ein Fehler, den man sonst erst beim Aufruf merkt.
    if not os.access(WORK_DIR, os.R_OK | os.X_OK | os.W_OK):
        logger.error(
            "das Arbeitsverzeichnis %s ist fuer uid=%d nicht zugreifbar "
            "(Rechte oder Eigentuemer des Mounts pruefen)",
            WORK_DIR,
            os.getuid(),
        )
        raise SystemExit(1)

    apps = load_apps()
    if not apps:
        logger.error("keine Craft-App installiert - der Gateway hat nichts zu tun")
        # Der Container soll nicht als "gesund" melden, wenn er arbeitslos ist.
        raise SystemExit(1)

    logger.info(
        "Gateway startet mit %d App(s): %s",
        len(apps),
        ", ".join(f"{a.name}->{a.prefix}_*" for a in apps),
    )

    server = build_server(apps)

    host = os.environ.get("MCP_HOST", "0.0.0.0")
    port = int(os.environ.get("MCP_PORT", "8000"))
    path = os.environ.get("MCP_PATH", "/mcp")
    token = os.environ.get("MCP_BEARER_TOKEN", "").strip()

    if token:
        logger.info("Bearer-Token gesetzt - der Endpoint verlangt Authorization")
    else:
        logger.warning(
            "kein MCP_BEARER_TOKEN gesetzt - der Endpoint ist unauthentifiziert. "
            "Nur vertretbar, solange er an 127.0.0.1 gebunden ist."
        )

    # Starlette erwartet hier Middleware-Instanzen, keine Klassen. Das Token
    # wird per partial an den Middleware-Konstruktor gebunden.
    middleware = None
    if token:
        middleware = [Middleware(BearerAuthMiddleware, token=token)]

    app = server.http_app(path=path, middleware=middleware)

    import uvicorn

    uvicorn.run(app, host=host, port=port, log_level=os.environ.get("LOG_LEVEL", "info").lower())


if __name__ == "__main__":
    main()
