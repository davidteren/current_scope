# CurrentScope Showcase

A standalone, deployable Rails 8.1 host app that validates the
[`current_scope`](../) engine end to end — the RBAC matrix, the separation-of-duties
veto, scoped roles, and the management UI. It depends on the engine via a local
path gem (`gem "current_scope", path: ".."`).

## Run it locally

```bash
git clone https://github.com/davidteren/current_scope
cd current_scope/showcase
bin/setup   # bundle, create + seed the database, then start the server
            # (bin/setup ends with `exec bin/dev` — pass --skip-server to
            #  set up without booting)
```

Then open http://localhost:3000.

`bin/setup` seeds the primary sign-in accounts below (password `password` for
all); the multi-domain gallery adds a preparer / approver / scoped-approver per
domain on top of these:

| Email | What it demonstrates |
|---|---|
| `owner@example.com`    | Owner (full access) — sees everything, manages roles |
| `reviewer@example.com` | can view and approve reports, but never their own (SoD veto) |
| `member@example.com`   | can view + create reports; no approve, no destroy |
| `scoped@example.com`   | a scoped Viewer role granting `reports#show` on ONE report only |

No `RAILS_MASTER_KEY` is needed for local development — the app boots and
`db:prepare` runs without one (nothing reads encrypted credentials at boot).

Manage authorization at `/current_scope` (full-access accounts only).

## Deploy with Kamal (volume-backed SQLite)

The showcase deploys as a single container with all four SQLite databases
(primary/cache/queue/cable) and Active Storage uploads on one persistent named
volume. Solid Queue runs inside Puma (`SOLID_QUEUE_IN_PUMA=true`), so there is
one server, one container, one process — SQLite is single-writer, so **do not
scale the web role**.

### The one non-obvious thing: build from the repo root

The engine is a path gem *above* `showcase/`, so a `showcase/`-scoped Docker
build can't resolve it. The build context is the **repo root**, with the
Dockerfile at `showcase/Dockerfile`. `config/deploy.yml` already encodes this
(`builder.context: ..`), and the image lays the app out as:

```
/rails            engine (gem) root — app/ config/ db/ lib/ + gemspec
/rails/showcase   the Rails app (Rails.root); path ".." resolves here
/rails/showcase/storage   <- the named volume mount (all durable state)
```

Run kamal **from this `showcase/` directory** so `context: ..` points at the
repo root:

```bash
cd showcase
kamal setup     # first deploy: provision + boot
kamal deploy    # subsequent deploys
```

Before the first deploy, edit `config/deploy.yml` and replace the placeholders:
`image`, the `servers.web` host, `proxy.host`, and the `registry` username.

### RAILS_MASTER_KEY (secret, never in the image)

`config/master.key` is gitignored and is **never** baked into an image layer
(assets precompile with `SECRET_KEY_BASE_DUMMY=1`; `/.dockerignore` excludes the
key). Provide it to the running container as a Kamal secret. Kamal reads secrets
from `.kamal/secrets` (create it with `kamal init`; it is gitignored). For
example that file can contain:

```bash
RAILS_MASTER_KEY=$(cat config/master.key)
KAMAL_REGISTRY_PASSWORD=$YOUR_REGISTRY_TOKEN
```

Never commit `config/master.key` or the resolved `.kamal/secrets`.

## Same image on Render or Fly (notes, not shipped config)

The same `showcase/Dockerfile` (built from the repo root) runs on Render or Fly.
Both need a persistent disk at the app's storage path and the master key as a
secret env var.

**Render** (Docker, build context = repo root, Dockerfile path
`showcase/Dockerfile`):
- Add a **Disk** mounted at `/rails/showcase/storage` (the volume path — all
  SQLite DBs + uploads live there).
- Env: `RAILS_MASTER_KEY` (secret), `SOLID_QUEUE_IN_PUMA=true`, and
  `HTTP_PORT=$PORT` so Thruster listens on the port Render assigns.
- One instance only (SQLite single-writer).

**Fly** (`fly.toml`):
- `[build] dockerfile = "showcase/Dockerfile"` and build from the repo root.
- `internal_port = 80` (Thruster/`EXPOSE 80`).
- `[mounts] source = "current_scope_storage"` `destination = "/rails/showcase/storage"`.
- `RAILS_MASTER_KEY` via `fly secrets set`; `SOLID_QUEUE_IN_PUMA=true` in `[env]`.
- One machine only, and disable auto-scaling (single writer).
