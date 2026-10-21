# artcraft-mcp

A Docker image that turns the [ArtCraft Crafting Apps](https://getartcraft.com/apps)
into a single MCP server you can point any MCP client at.

The Crafting Apps are free, clean-room implementations of Word, PowerPoint,
Excel, Photoshop, Illustrator, Acrobat, Lightroom, Premiere Pro, InDesign,
After Effects, AutoCAD, Pro Tools and Figma, written in Rust by the
[ArtCraft Team](https://github.com/storytold).

Each app ships a command-line tool that speaks the Model Context Protocol
**over stdio**. This project bundles them behind one **Streamable HTTP**
endpoint, so clients that talk HTTP - OpenCode, Claude, Cursor, anything with
an MCP client - can use them.

```
MCP client  ──HTTP──▶  gateway  ──stdio──▶  wordcraft-cli mcp
                              ──stdio──▶  deckcraft-cli mcp
                              ──stdio──▶  photocraft-cli mcp
                              ──stdio──▶  …  (13 apps in total)
```

**795 tools** across all 13 apps, namespaced per app (`word_*`, `deck_*`,
`photo_*`, …).

> This is an independent, unofficial packaging. It is not affiliated with,
> endorsed by or supported by the ArtCraft Team. See [Trademarks](#trademarks).

## Quick start

```sh
docker run -d --name artcraft-mcp \
  -p 127.0.0.1:8896:8000 \
  -v "$PWD/work:/work" \
  ghcr.io/jw2122-kiwi/artcraft-mcp:latest
```

The MCP endpoint is now at `http://127.0.0.1:8896/mcp`.

Files the apps create land in `./work` on the host.

### With Docker Compose

```sh
git clone https://github.com/jw2122-kiwi/artcraft-mcp
cd artcraft-mcp/deploy
cp .env.example .env
docker compose up -d
```

### Client setup

OpenCode (`~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
    "servers": {
      "artcraft": {
        "type": "remote",
        "url": "http://127.0.0.1:8896/mcp"
      }
    }
  }
}
```

Claude Code:

```sh
claude mcp add --transport http artcraft http://127.0.0.1:8896/mcp
```

## Choosing which apps to install

By default all 13 apps are installed. To install a subset, build the image
yourself:

```sh
docker build \
  --build-arg CRAFT_APPS=wordcraft,deckcraft,photocraft \
  -t artcraft-mcp:custom \
  ./gateway
```

| App | Tool prefix | Clone of | Tools |
| --- | --- | --- | --- |
| `wordcraft` | `word_` | Word | 16 |
| `deckcraft` | `deck_` | PowerPoint | 25 |
| `gridcraft` | `grid_` | Excel | 21 |
| `photocraft` | `photo_` | Photoshop | 25 |
| `pdfcraft` | `pdf_` | Acrobat | 171 |
| `vectorcraft` | `vector_` | Illustrator | 32 |
| `lightcraft` | `light_` | Lightroom | 388 |
| `filmcraft` | `film_` | Premiere Pro | 17 |
| `designcraft` | `design_` | InDesign | 26 |
| `effectcraft` | `effect_` | After Effects | 27 |
| `cadcraft` | `cad_` | AutoCAD | 12 |
| `soundcraft` | `sound_` | Pro Tools | 17 |
| `figcraft` | `fig_` | Figma | 18 |

## Architecture

```
MCP client
    │  HTTP POST /mcp  (Streamable HTTP)
    ▼
┌──────────────────────────────────────┐
│ gateway (Python + FastMCP)          │
│                                      │
│  per client session:                 │
│    wordcraft-cli mcp   ─┐            │
│    deckcraft-cli mcp    │  stdio     │
│    photocraft-cli mcp  ─┘            │
└──────────────────────────────────────┘
    │
    ▼
/work  (bind mount, the only writable path)
```

### State between tool calls

The apps are stateful: the open document, the undo history and the text
selection live inside the CLI process. A naive proxy opens a fresh backend
session per tool call, so every call would see an empty document.

The gateway therefore keeps **one set of CLI processes per MCP client
session**. Within a session the usual flow works:

```
open document → edit → inspect/render → save
```

Two clients never see each other's documents.

### Why one container and not one per app?

Fewer moving parts: one image, one port, one volume, one health check. The
isolation that matters is the container boundary plus the per-app filesystem
confinement described in [docs/security.md](docs/security.md).

## Security

### Filesystem confinement

Nine of the thirteen apps support `--automation-read-root` and
`--automation-write-root`. For those, the gateway sets both to `/work`, and
the app itself rejects absolute paths outside that root and `../` traversal:

```
automation path rejected: outside the write root /work: /tmp/escape.docx
```

The remaining four - `gridcraft`, `lightcraft`, `filmcraft`, `cadcraft` - do
not have those flags in their released versions, so their file access is
bounded **only by the container**. The container is hardened accordingly:

- no Docker socket
- no mounts other than `./work`
- `cap_drop: ALL`
- `no-new-privileges`
- unprivileged user, read-only root filesystem available via `read_only: true`

If you do not need those four apps, leave them out of `CRAFT_APPS`.

### Authentication

The endpoint is unauthenticated by default, which is only reasonable while it
is bound to `127.0.0.1`. To require a token:

```sh
docker run -d --name artcraft-mcp \
  -p 127.0.0.1:8896:8000 \
  -e MCP_BEARER_TOKEN="$(openssl rand -hex 24)" \
  -v "$PWD/work:/work" \
  ghcr.io/jw2122-kiwi/artcraft-mcp:latest
```

Clients then send `Authorization: Bearer <token>`.

For remote access, put Caddy in front - see [docs/caddy.md](docs/caddy.md).

## Reproducibility

- The base images are pinned to a digest-free but explicit tag
  (`python:3.12.15-slim-bookworm`); the Python dependencies are pinned with
  SHA-256 hashes in [`gateway/requirements.txt`](gateway/requirements.txt)
  and installed with `--require-hashes`. The same package versions are
  installed on every architecture.
- Every Craft app is downloaded from its official GitHub release and its
  SHA-256 checksum is verified against the release's `SHA256SUMS.txt`. A
  mismatch aborts the build.
- The build is a multi-stage build; the final image contains no compiler, no
  pip and no build cache.

Regenerate the lock file after changing `gateway/requirements.in`:

```sh
pip-compile --generate-hashes --output-file=gateway/requirements.txt gateway/requirements.in
```

## Image size

| | |
| --- | --- |
| Compressed (pull size) | ~460 MB |
| Uncompressed (on disk) | ~1.5 GB |

Most of it is the 13 statically linked Rust binaries (~733 MB) - they are
already stripped and there is no smaller build upstream. The Python gateway
is ~75 MB.

Alpine/musl is **not** possible: the Craft CLIs are built against glibc
(GLIBC_2.35) and the suite publishes no musl builds.

## Supported platforms

- `linux/amd64`
- `linux/arm64`

## License

The gateway code in this repository is licensed under the
[Apache License 2.0](LICENSE).

The Crafting App binaries redistributed inside the image are licensed by the
ArtCraft Team under **MIT OR Apache-2.0**, at your option. Their full license
texts are in [`third-party/`](third-party/) and are also installed in the
image under `/opt/craft/<app>/licenses/`. See [NOTICE](NOTICE) for the full
attribution.

## Trademarks

The ArtCraft name, wordmark and logos are trademarks of the ArtCraft Team.
They are not open source and are not covered by the licenses of the bundled
apps. This project does not redistribute them and does not use them in its
own name, logo, icon or domain. It refers to the apps by their own names in
order to identify the software it packages and to link to the upstream
project.

## Links

- Crafting Apps: <https://getartcraft.com/apps>
- Upstream source: <https://github.com/storytold>
- MCP specification: <https://modelcontextprotocol.io>
