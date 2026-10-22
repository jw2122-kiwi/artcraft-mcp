# Anbindung an einen Agenten (hermes2)

Ein Agent-Container (hier: der hermes2-Agent aus dem Stack `hermes2`) kann
die Crafting Apps benutzen. Dafuer muss der Gateway aus zwei Gruenden
erreichbar sein:

1. **Netzwerk** - der Agent spricht den Gateway ueber ein gemeinsames
   Docker-Netz an, nicht ueber den Host-Port.
2. **Authentifizierung** - der Gateway verlangt ein Bearer-Token, damit nicht
   jeder Container auf diesem Netz den Agenten benutzen kann.

Dazu kommt ein gemeinsames Arbeitsverzeichnis, damit der Agent die
Dokumente, die er erzeugt, auch wieder einlesen kann.

## 1. Gemeinsames Netzwerk

Am einfachsten ist ein Netz, das mehrere Stacks teilen. Im Repo der
Stacks heisst es `caddy-net` (es wird vom Caddy-Stack erstellt). Wer Caddy
nicht betreibt, legt es einmalig an:

```sh
docker network create craft-net
```

Der artcraft-Stack tritt dem Netz in `deploy/compose.yaml` bei:

```yaml
    networks:
      - craft-net
```

Der Agent erreicht den Gateway danach unter `http://artcraft-mcp:8000/mcp` -
der Containername ist der DNS-Name im Netz.

## 2. Token

Der Gateway laeuft mit einem Bearer-Token. Er steht in **zwei** `.env`-Dateien,
die beide nicht im Git sind:

| Datei | Variable | Bedeutung |
| --- | --- | --- |
| `artcraft-mcp/deploy/.env` | `MCP_BEARER_TOKEN` | Token, das der Gateway verlangt |
| `hermes2/.env` | `ARTCRAFT_MCP_TOKEN` | Token, das der Agent mitsendet |

Beide muessen denselben Wert haben. Ein neues Token erzeugen:

```sh
openssl rand -hex 24
```

Danach beide Dateien anpassen und die Container neu starten:

```sh
cd ../hermes2       && docker compose up -d
cd ../artcraft-mcp/deploy && docker compose up -d
```

## 3. MCP-Server im Agenten registrieren

Die Registrierung gehoert in die versionierte Konfiguration des Agenten
(bei hermes2: `hermes2/configure.sh`). Der Block:

```sh
cfg mcp_servers.artcraft.url "http://artcraft-mcp:8000/mcp"
cfg mcp_servers.artcraft.enabled true
cfg mcp_servers.artcraft.timeout 300
cfg mcp_servers.artcraft.headers.Authorization "Bearer ${ARTCRAFT_MCP_TOKEN}"
```

Das Skript wird im Container ausgefuehrt:

```sh
docker cp configure.sh hermes2:/opt/data/configure.sh
docker exec hermes2 sh -c 'cd /opt/hermes && sh /opt/data/configure.sh'
```

Hinweise:

- Die Referenz muss die POSIX-Form `${VAR}` sein. `${env:VAR}` kann `dash`
  (`sh`) nicht parsen, und das Skript laeuft unter `sh`.
- Beim Schreiben loest `hermes config` die Referenz auf und legt den Token
  im Klartext in der `config.yaml` ab. Die Datei liegt im Datenvolume und
  steht nicht im Git. Nach einer Token-Rotation: `.env` anpassen und das
  Skript erneut ausfuehren.
- Das Timeout ist 300 statt 120, weil PDF-Export und Bild-Rendering laenger
  dauern als ein Listenaufruf.

## 4. Gemeinsames Arbeitsverzeichnis

Der Agent soll die erzeugten Dokumente auch wieder einlesen koennen. Dazu
teilt sich der Agent-Stack das Arbeitsverzeichnis des artcraft-Stacks:

```yaml
      - ../artcraft-mcp/deploy/work:/opt/data/artcraft
```

Der Agent sieht die Dateien dann unter `/opt/data/artcraft/`, der Gateway
schreibt sie nach `artcraft-mcp/deploy/work/`. Beide greifen auf dasselbe
Verzeichnis zu.

## Pruefen

Verbindungstest ueber den MCP-Client des Agenten:

```sh
docker exec hermes2 /opt/hermes/.venv/bin/hermes mcp test artcraft
```

Erwartete Ausgabe:

```
  Testing 'artcraft'...
  Transport: HTTP -> http://artcraft-mcp:8000/mcp
    Authorization: ***
  Connected (2719ms)
  Tools discovered: 795
```

Ein echter Dokument-Durchlauf (im Container):

```sh
docker exec hermes2 bash -c '
  TOKEN=$(env | grep "^ARTCRAFT_MCP_TOKEN=" | cut -d= -f2)
  H1="Content-Type: application/json"; H2="Accept: application/json, text/event-stream"
  call() { curl -s -X POST http://artcraft-mcp:8000/mcp \
    -H "Authorization: Bearer $TOKEN" -H "$H1" -H "$H2" -H "mcp-session-id: $SID" -d "$1" | sed "s/^data: //"; }
  SID=$(curl -s -D - -o /dev/null -X POST http://artcraft-mcp:8000/mcp \
    -H "Authorization: Bearer $TOKEN" -H "$H1" -H "$H2" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}" \
    | grep -i "^mcp-session-id:" | tr -d "\r" | awk "{print \$2}")
  call "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" >/dev/null
  call "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"word_new_document\",\"arguments\":{\"template\":\"blank\"}}}" >/dev/null
  call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"word_type_text\",\"arguments\":{\"text\":\"Hallo\"}}}" >/dev/null
  call "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"word_save_document\",\"arguments\":{\"path\":\"test.docx\"}}}"
'
ls -l artcraft-mcp/deploy/work/test.docx
```

## Was der Agent damit kann

- Dokumente erzeugen und bearbeiten (`word_*`, `deck_*`, `grid_*`)
- Bilder bearbeiten (`photo_*`, `vector_*`, `fig_*`)
- PDFs lesen und schreiben (`pdf_*`)
- Zeichnungen und Videos (`cad_*`, `film_*`)

Die Werkzeugnamen tragen das App-Praefix, im Agenten also z.B.
`word_new_document` statt `new_document`.
