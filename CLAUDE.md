# DivinityCenteredHUD

## What This Repo Is

Source for **Divinity Centered HUD** (folder and mod table `CenteredHUD`), a standalone, client-side Lua mod for Divinity: Original Sin 2 – Definitive Edition. It lets the user move the party portraits and the minimap, which the engine pins to the screen edges, toward the centre on ultrawide displays. Its only requirement is Norbyte's Script Extender. Epip is optional: its notification UI is used when present. `FINDINGS.md` holds the full technical investigation; read it before changing how panels are moved.

## Layout

- `src/` is the package root; its contents become the .pak unchanged. The mod is a single file: `src/Mods/CenteredHUD_<uuid>/Story/RawFiles/Lua/BootstrapClient.lua`.
- Never change the mod folder name or UUID in `meta.lsx` again: users' load orders and GM campaigns reference them. (It was renamed once, from `EpipPanelMover_d87cf544-…`, before the first public release.)
- `tools/build.py` → `dist/CenteredHUD.pak` (git-ignored). `tools/lspk.py` is the package reader/writer and has no dependencies.

## Key Paths

- **Mods folder** (packages only, no loose files): `Documents\Larian Studios\Divinity Original Sin 2 Definitive Edition\Mods\`
- **Saved positions**: `...\Osiris Data\CenteredHUD.json`. The old `EpipPanelMover.json` is read only when the new file doesn't exist yet.
- **SE logs** (needs `"LogRuntime": true` in `<game>\DefEd\bin\OsirisExtenderSettings.json`): `...\Extender Logs\Extender Runtime *.log`. Grep for `[CenteredHUD]`.
- **Game**: `C:\Program Files (x86)\Steam\steamapps\common\Divinity Original Sin 2\DefEd`. Vanilla UI movies are in `Data\Game.pak` under `Public/Game/GUI/`.

## Deploy Loop

1. Edit `BootstrapClient.lua`.
2. Close the game. It locks loaded .pak files, and `deploy.ps1` refuses to run while `EoCApp.exe` is up.
3. `.\tools\deploy.ps1` builds, verifies and copies the package. It also removes a leftover `EpipPanelMover.pak`; that legacy package would load alongside and fight over the same panels.
4. Start the game, load in, test, then read the SE log.

## Code Rules

- All log lines are prefixed `[CenteredHUD]`.
- Pickup and drop log a diagnostic line (`LogDiagnostics`). Keep it; it's how layout problems get diagnosed without a debugger.
- Everything is re-applied from `Ext.Events.Tick` and must be idempotent: a tick where the panel is already in place does nothing.
- Never move anchored vanilla UIs with `UIObject:SetPosition()`; the engine overrides it. See FINDINGS.md §3–5.
- Input goes through `Ext.Events.RawInput` only. Block a key by rewriting its `InputId`, and block its repeats and release too (`_BlockedKeys`).
- Never add a hard dependency on Epip. Anything Epip-specific must be optional and nil-safe (`Mods.EpipEncounters` may not exist).
- Saved data is versioned (`SAVE_VERSION`) and each position records the mode it was saved in. Bump the version or mode when units change, so old positions are discarded instead of misapplied.

## Versioning

`local VERSION` in `BootstrapClient.lua` and the ModuleInfo `Version` in `meta.lsx` must match (`major<<28|minor<<24|revision<<16|build`). `build.py` enforces this, and also enforces `PublishVersion >= 909321303`; below that the game flags the mod as Classic Edition. Bump both on every release.

## Releasing

`.github/workflows/release.yml` builds on every push and PR. Pushes to `main` refresh the `latest` pre-release; a `vX.Y.Z` tag publishes a versioned release, and the build fails unless the tag matches the version.

## Testing

No automated tests; verification is in-game at 5120x1440, with Epip both enabled and disabled. `build.py` round-trips every packaged file, so a package that builds is byte-identical to `src/`.
