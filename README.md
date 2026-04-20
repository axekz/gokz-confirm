# GOKZ Rules Confirmation

This repository packages the `gokz-confirm` SourceMod addon for GOKZ servers.

The plugin blocks timer starts for players who have not accepted the server
rules yet. Unconfirmed players are shown the rules panel and must type the
exact confirmation phrase in chat before they can start.

## Included Files

- `addons/sourcemod/scripting/gokz-confirm.sp` — plugin source
- `addons/sourcemod/translations/gokz-confirm.phrases.txt` — localized rules text
- `addons/sourcemod/plugins/gokz-confirm.smx` — compiled plugin binary
- `addons/sourcemod/scripting/include/gokz/` — minimal GOKZ compile shim

## Features

- Blocks `GOKZ_OnTimerStart` for unconfirmed players
- Shows the rules again on spawn until confirmation
- Supports HUD and menu display modes
- Adds `sm_rules`, `sm_confirm`, and `sm_rulesview`
- Persists confirmations in SQLite at `addons/sourcemod/data/sqlite/gokz_confirm.sq3`

## Requirements

- CS:GO server
- SourceMod `1.11`
- Existing GOKZ installation providing `gokz-core`

This repository includes a minimal `include/gokz/core.inc` shim so the plugin
can compile in isolation. Runtime support still comes from the real GOKZ
plugins on the server.

## Local Compile

One simple local compile flow is:

1. Download SourceMod `1.11`.
2. Copy this repository’s `addons` directory into the SourceMod package.
3. Run `spcomp` from `addons/sourcemod/scripting`:

```sh
./spcomp gokz-confirm.sp
```

If you prefer, the GitHub Actions workflow in `.github/workflows/main.yml` can
be used as the reference build pipeline.

## Release Tags

Pushes to `main` or `master` automatically create a release tag before
compiling:

- if no numeric SemVer tag exists, the first tag is `1.0.0`
- if any pushed commit subject matches Conventional Commit `feat:` or `feat(scope):`, the workflow bumps the minor version
- otherwise the workflow bumps the patch version
- pull requests compile with the short commit SHA instead of creating tags
- manually pushed tags compile with the tag name as the plugin version
- every non-PR release build publishes a GitHub Release with full and upgrade zip assets for `GOKZ_VERSION`
