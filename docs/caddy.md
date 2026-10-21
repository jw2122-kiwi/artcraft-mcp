# Caddy reverse proxy

The gateway listens on port 8000 inside the container. To reach it from the
network over HTTPS, put Caddy in front of it.

## 1. Join the network

The Caddy stack and the gateway need a shared network. Add it to
`deploy/compose.yaml`:

```yaml
services:
  gateway:
    # ...
    networks:
      - caddy-net
      - default

networks:
  caddy-net:
    external: true
```

Create the network once if it does not exist yet:

```sh
docker network create caddy-net
```

## 2. Add the site

In the Caddy stack's `conf/Caddyfile`:

```
artcraft.mcp.jw2122.dedyn.io {
  # Shared-secret gate: MCP clients must send "Authorization: Bearer <secret>"
  @mcp_unauthorized not header_regexp Authorization "^Bearer {$ARTCRAFT_MCP_CLIENT_SECRET}$"
  respond @mcp_unauthorized "Unauthorized" 401
  reverse_proxy artcraft-mcp:8000
}
```

The secret goes into the Caddy stack's `.env` as
`ARTCRAFT_MCP_CLIENT_SECRET`; it must not be committed.

The Caddy service needs the `ARTCRAFT_MCP_CLIENT_SECRET` variable in its
environment (the stack already forwards `PAPRA_MCP_CLIENT_SECRET` the same
way - add the new one in `caddy/compose.yaml`).

## 3. Bind the container port

The shipped compose file binds the port to `127.0.0.1` on purpose, so the
endpoint is not reachable except through the proxy. If you want Caddy to
reach it, either keep that binding (Caddy connects over the docker network
anyway, using the container port directly) or change it to `8896:8000`.

## 4. Point the client at it

```json
{
  "mcp": {
    "servers": {
      "artcraft": {
        "type": "remote",
        "url": "https://artcraft.mcp.jw2122.dedyn.io/mcp",
        "oauth": false,
        "headers": {
          "Authorization": "Bearer {env:ARTCRAFT_MCP_CLIENT_SECRET}"
        }
      }
    }
  }
}
```

The gateway's own `MCP_BEARER_TOKEN` can stay empty in that case - the proxy
does the authentication. Setting both is fine too; the client then needs to
send the same token twice, which only works if both use the same value.
