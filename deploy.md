# Deploying GPSView

The published site is `https://murmrapp.github.io/GPSView/`. It's a static
bundle (HTML / CSS / JS / pre-rendered JSON) generated from the local
SQLite DB by `mix gpsview.static_export` and served from the `docs/`
folder on the `main` branch.

There are two reasons to redeploy: **data updates** (most common) and
**code updates** (rare). Both end with `git push`.

---

## Updating data

Use this when a new tracker CSV arrives or you want to refresh an
existing tracker with new fixes.

```bash
# 1. Import the CSV (idempotent on device_id+ts; safe to re-run)
mix gpsview.import_fixes path/to/new.csv --device <id>

# 2. Optional: fill flight gaps (Auckland-Tahiti style interpolation)
mix gpsview.reconstruct_gaps --device <id>

# 3. Bake the static bundle into docs/
mix gpsview.static_export

# 4. Commit + push (GitHub Pages auto-deploys in ~30s)
git add docs/
git commit -m "data update: <id>"
git push
```

After the push:

- Watch the build at https://github.com/murmrapp/GPSView/actions
- Verify by reloading `https://murmrapp.github.io/GPSView/?device=<id>`

### Adding a brand-new tracker

Same flow. `mix gpsview.import_fixes` auto-creates the device row if
the `--device <id>` doesn't exist yet. After running the export, the new
tracker shows up as a button in the header on the live site.

### Removing a tracker

```bash
sqlite3 gpsview_dev.db <<'SQL'
DELETE FROM fixes   WHERE device_id = '<id>';
DELETE FROM devices WHERE id        = '<id>';
SQL
mix gpsview.static_export
git add docs/ && git commit -m "remove tracker <id>" && git push
```

---

## Updating application code

Use this when you change UI files (`priv/static/{js,css,index.html}`),
controllers, or the export task itself.

```bash
# 1. Make your edits, then sanity-check the live mode locally
mix phx.server          # http://localhost:4000
# Iterate. Phoenix reloads .ex changes; static asset changes need a hard
# browser refresh (Cmd+Shift+R).

# 2. Once it works against the live API, regenerate the static bundle
mix gpsview.static_export

# 3. (Recommended) Preview the static version locally before pushing
cd docs && python3 -m http.server 8765
# open http://localhost:8765/?device=Bluey  → should look identical
# Watch the Network tab — fetches should hit data/*.json, not /api/*.

# 4. Compile gate, commit, push
mix compile --warnings-as-errors
git add -A
git commit -m "<what changed>"
git push
```

Code changes implicitly bring fresh data along (the export reads the
current DB), so a code update + data update is one push.

---

## Verifying the live site

```bash
curl -sI https://murmrapp.github.io/GPSView/ | head -3
# expect: HTTP/2 200
```

Or just reload `https://murmrapp.github.io/GPSView/?device=<id>` and
check the browser DevTools console for errors and the Network tab for
404s on `data/*.json`.

---

## Sharing links with friends

The site is technically public on GitHub Pages free tier. Privacy is by
obscurity — share the deep link, don't share the bare site URL or repo:

```
https://murmrapp.github.io/GPSView/?device=<id>
```

Use unguessable IDs (e.g. random slugs) when registering new trackers if
you want to make the URL hard to guess. The header shows one button per
tracker in the DB, so anyone who lands on the site can switch between
all known devices — only the URL controls discovery, not access.

---

## One-time setup (reference, already done on this machine)

Skip this; it's documented for clean-machine reproduction.

```bash
# 1. Clone
git clone git@github.com:murmrapp/GPSView.git && cd GPSView

# 2. Elixir / Erlang via your favourite version manager (asdf, mise, brew)
mix deps.get

# 3. Local SQLite DB
mix ecto.setup

# 4. SSH key for pushes
# Either a personal account-wide key at github.com/settings/keys
# OR a per-repo deploy key with "Allow write access" checked.
# See ~/.ssh/config for which key SSH uses for github.com.

# 5. GitHub Pages source
# https://github.com/murmrapp/GPSView/settings/pages
# Branch: main / Folder: /docs
```

---

## Common stumbles

- **`error: src refspec main does not match any`** — no commits yet on
  `main`. Run `git commit` first, then `git push -u origin main`.
- **`Permission denied (publickey)` on push** — SSH is offering the wrong
  key. `ssh -T git@github.com` should reply `Hi murmrapp/GPSView!`
  (deploy key) or `Hi murmrapp!` (personal key). If it's a different
  repo's deploy key, fix `~/.ssh/config` to point `Host github.com` at
  the right `IdentityFile` and add `IdentitiesOnly yes`.
- **404 on the live site right after first push** — Pages takes a minute
  for the first build. Check the Actions tab.
- **Map renders but no points / wrong tracker** — usually a stale cache.
  Hard-refresh (Cmd+Shift+R). If still wrong, verify
  `https://murmrapp.github.io/GPSView/data/<id>.json` is up to date.
- **Repo is bloating from large `docs/data/<id>.json` commits** — each
  full-resolution device JSON is ~16 MB. Reach for
  `mix gpsview.static_export --decimate 5000` to keep dumps under 1 MB,
  or commit the `docs/data/` files via Git LFS.
