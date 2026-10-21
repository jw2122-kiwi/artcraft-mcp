# Security

## Filesystem confinement

The Craft apps are command-line tools that an AI agent drives. The agent can
ask them to open, edit and save files. What keeps that from turning into
"the agent may read or write anything on the host" is the combination of two
mechanisms.

### 1. The app-level root flags

Nine of the thirteen apps accept:

```
--automation-read-root DIR
--automation-write-root DIR
```

With both set, the app confines every file access to those directories. Paths
are relative to the root or absolute beneath it. The apps reject parent
traversal, absolute paths outside the root and symlinks that escape it.

The gateway sets both flags to `/work` for these apps:

| App | Confinement |
| --- | --- |
| `wordcraft` | yes |
| `deckcraft` | yes |
| `photocraft` | yes |
| `pdfcraft` | yes |
| `vectorcraft` | yes |
| `designcraft` | yes |
| `effectcraft` | yes |
| `soundcraft` | yes |
| `figcraft` | yes |
| `gridcraft` | **no** |
| `lightcraft` | **no** |
| `filmcraft` | **no** |
| `cadcraft` | **no** |

For the four apps without the flags, the released versions have no equivalent
option - there is no way to jail them from the outside. Their file access is
bounded only by the container.

Verified behaviour of the confined apps:

```
$ wordcraft-cli mcp --automation-read-root /work --automation-write-root /work
# save to /tmp/escape.docx
automation path rejected: outside the write root /work: /tmp/escape.docx
# save to ../escape.docx
automation path rejected: outside the write root /work: ../escape.docx
```

### 2. The container boundary

For the four unconfined apps, the container is what contains them. The
shipped compose file therefore:

- mounts **only** `./work` into the container,
- has **no** Docker socket,
- drops **all** capabilities (`cap_drop: ALL`),
- sets `no-new-privileges`,
- runs as an unprivileged user (uid/gid configurable, defaults to the host
  user's).

An agent that drives `gridcraft` can therefore read and write anything
*inside the container* - the container's own image, the installed Craft
binaries, the Python environment - but not the host filesystem, and not
anything outside `./work`.

### Hardening further

If you want to run the unconfined apps, take the container further:

```yaml
services:
  gateway:
    read_only: true
    tmpfs:
      - /tmp
    volumes:
      - ./work:/work
```

`read_only: true` makes the whole root filesystem read-only, so an agent
cannot tamper with the installed binaries or the Python environment. Some
apps need a writable temporary directory; `tmpfs` provides one.

Dropping the four unconfined apps from the build is the cleanest option:

```sh
CRAFT_APPS=wordcraft,deckcraft,gridcraft ... docker compose build
```

## Authentication

By default the endpoint accepts unauthenticated requests. That is only
reasonable while it is bound to `127.0.0.1`.

Set `MCP_BEARER_TOKEN` and the gateway requires
`Authorization: Bearer <token>` on every request. The comparison uses
`secrets.compare_digest`, so it does not leak the token through timing. A
header that is not valid ASCII is rejected with 401 rather than raising.

For a reverse proxy setup, see [caddy.md](caddy.md).

## What the gateway does not do

- It does not implement per-tool authorization. Every client that may reach
  the endpoint may call every tool of every mounted app.
- It does not distinguish harmless from destructive tools. The Craft apps
  themselves mark their tools with hints, but hints are not enforcement.
- It does not sandbox the app processes beyond the confinement described
  above.

If you expose the endpoint to a network, put an authenticating reverse proxy
in front of it and keep the container port bound to the loopback interface.
