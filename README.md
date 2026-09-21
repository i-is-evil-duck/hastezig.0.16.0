# HasteZig  <br />  <img alt="Stargazers" src="https://img.shields.io/github/stars/i-is-evil-duck/hastezig.0.16.0?style=for-the-badge&logo=starship&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41">


## HasteZig
A tiny pastebin written in Zig. Client-side syntax highlighting, SQLite storage,
no expiry, no accounts.

Two containers: an API-only Zig backend and an nginx static frontend that ships
two themes on separate ports.

## Features

- 5-character alphanumeric paste IDs (base62, 916M combinations)
- Multiple blobs per paste, each with its own language, rendered in separate
  boxes on one page with line numbers
- Language auto-detection (per blob) via highlight.js in the browser
- Edit a paste and save it as a new paste
- All syntax highlighting happens in the browser via highlight.js
- SQLite storage (WAL mode), pastes never expire
- API backend runs in a scratch Docker image, frontend served by nginx
- Max paste size: 256 KB, max 20 blobs

## Ports

| Port | Service     |
|------|-------------|
| 960  | API backend (hastezig) |
| 961  | Frontend, dark theme   |
| 962  | Frontend, light theme  |

The light theme (port 962) and dark theme (port 961) link to each other via the
`MAIN_ORIGIN` / `LIGHT_ORIGIN` env vars consumed by the nginx template
(`frontend/nginx/default.conf.template`).

## Build the backend

Requires Zig 0.16.0.

```
zig build -Doptimize=ReleaseSafe
zig-out/bin/hastezig 0.0.0.0 960 hastezig.db
```

Arguments: `host port db_path` (defaults: `0.0.0.0 960 hastezig.db`).

## Run with Docker

```
docker compose -f docker/docker-compose.yml up --build
```

- API: http://localhost:960
- Dark theme: http://localhost:961
- Light theme: http://localhost:962

The frontend nginx proxies `/api/` and `/raw/` to the API container, so the
browser talks to one origin per port. Data is stored in the named volume
`hastezig-data` (mounted at `/data`).

## API

Create a paste (multiple blobs, each with its own language):

```
curl -X POST http://localhost:960/api/paste \
  -H "content-type: application/json" \
  -d '{"blobs":[{"content":"const x = 1;","lang":"javascript"},{"content":"import os","lang":"python"}]}'
```

Use `"lang":"auto"` to auto-detect a blob's language on the view page. A single
blob may also be sent in the legacy form `{"content":"...","lang":"..."}`.

Response: `{"id":"aBcDe","url":"/aBcDe"}`

Get a paste as JSON:

```
curl http://localhost:960/api/paste/aBcDe
```

Response: `{"id":"aBcDe","created_at":1785913610,"blobs":[{"lang":"javascript","content":"const x = 1;"}]}`

Get raw content:

```
curl http://localhost:960/raw/aBcDe
```

## Layout

- `src/main.zig` – entry point, args parsing
- `src/server.zig` – HTTP API, routing, JSON handling, CORS
- `src/db.zig` – SQLite wrapper
- `src/vendor/` – vendored SQLite amalgamation
- `frontend/main/` – dark theme (index.html, view.html, app.js, style.css, vendor files)
- `frontend/light/` – light theme (self-contained light.html)
- `frontend/nginx/` – nginx config template (ports 961/962, `/api` + `/raw` proxy)
- `docker/` – Dockerfile (API) and docker-compose.yml

## Downloads

Download the pre-built executables from the [releases](https://github.com/i-is-evil-duck/hastezig.0.16.0/releases) page.

| Platform | File |
|----------|------|
| Linux | `hastezig` |
| Docker | `docker compose -f docker/docker-compose.yml up --build` |

## Views

<img src="https://count.getloli.com/get/@Hastezig?theme=rule34" />
