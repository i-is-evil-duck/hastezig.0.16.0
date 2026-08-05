# hastezig

A tiny pastebin written in Zig. Client-side syntax highlighting, SQLite storage,
no expiry, no accounts.

## Features

- 5-character alphanumeric paste IDs (base62, 916M combinations)
- Multiple blobs per paste, each with its own language, rendered in separate
  boxes on one page with line numbers
- Language auto-detection (per blob) via highlight.js in the browser
- Edit a paste and save it as a new paste
- All syntax highlighting happens in the browser via highlight.js
- SQLite storage (WAL mode), pastes never expire
- Single static binary, runs in a scratch Docker image
- Max paste size: 256 KB, max 20 blobs

## Build

Requires Zig 0.16.0.

```
zig build -Doptimize=ReleaseSafe
zig-out/bin/hastezig 0.0.0.0 8080 hastezig.db
```

Arguments: `host port db_path` (defaults: `0.0.0.0 8080 hastezig.db`).

## Run with Docker

```
docker compose -f docker/docker-compose.yml up --build
```

Data is stored in the named volume `hastezig-data` (mounted at `/data`).

## API

Create a paste (multiple blobs, each with its own language):

```
curl -X POST http://localhost:8080/api/paste \
  -H "content-type: application/json" \
  -d '{"blobs":[{"content":"const x = 1;","lang":"javascript"},{"content":"import os","lang":"python"}]}'
```

Use `"lang":"auto"` to auto-detect a blob's language on the view page. A single
blob may also be sent in the legacy form `{"content":"...","lang":"..."}`.

Response: `{"id":"aBcDe","url":"/aBcDe"}`

Get a paste as JSON:

```
curl http://localhost:8080/api/paste/aBcDe
```

Response: `{"id":"aBcDe","created_at":1785913610,"blobs":[{"lang":"javascript","content":"const x = 1;"}]}`

Get raw content:

```
curl http://localhost:8080/raw/aBcDe
```

## Pages

- `/` – create a paste (add blobs, pick a language or auto-detect)
- `/aBcDe` – view a paste with syntax highlighting and line numbers; "edit"
  loads the paste into editable boxes, "save as new paste" creates a new one
- `/static/...` – static assets (app.js, styles, vendor files)

## Layout

- `src/main.zig` – entry point, args parsing
- `src/server.zig` – HTTP server, routing, JSON handling
- `src/db.zig` – SQLite wrapper
- `src/web.zig` – embedded static assets
- `src/web/` – frontend (HTML, CSS, JS) and vendored highlight.js files
- `src/vendor/` – vendored SQLite amalgamation
- `docker/` – Dockerfile and docker-compose.yml
