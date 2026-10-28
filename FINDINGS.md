# Technical Findings

How Divinity: Original Sin 2 – Definitive Edition positions its HUD, and how this mod moves two pieces of it. Measured on a 5120x1440 display, UI scale 1.333 (flash units to pixels), Epip v1075.

## 1. Goal

On 32:9 the party portraits sit at the far left edge and the minimap at the far right. Epip already remembers the positions of draggable windows (character sheet, party inventory) through its `Features.UILayout`, but only once a window has been dragged, and neither the portraits nor the minimap can be dragged in vanilla. So this mod adds hotkeys to pick each one up, follow the mouse, drop it, and save the position.

## 2. Runtime environment

- Mod logic runs in Norbyte's Script Extender (SE) Lua, client context, from `Story/RawFiles/Lua/BootstrapClient.lua`.
- Keys come straight from `Ext.Events.RawInput`, which carries `ev.Input.Input.InputId` (for example `"p"`, `"lctrl"`, `"left2"` for left-click) and `ev.Input.Value.State` (`"Pressed"`/`"Released"`). The mod tracks which keys are held to read Ctrl/Shift/Alt, and ignores key repeats.
- **Blocking a key from the game:** rewrite `ev.Input.Input.InputId` to an unbound ID (`"item7"`). This is the technique Epip's InputLib uses for its preventable events. The mod blocks the press, any repeats and the release of a consumed key, so the game never sees half of a key press.
- The mod first shipped as an Epip add-on built on Epip's InputLib. It became standalone once it was clear InputLib is a layer over `RawInput`. Each mod gets its own global table, so Epip's notification UI is still used opportunistically via `Mods.EpipEncounters.Client.UI.Notification` when present.
- `Ext.IO.SaveFile/LoadFile` read and write `Documents\...\Osiris Data\`.
- Logs: set `"LogRuntime": true` in `<game>\DefEd\bin\OsirisExtenderSettings.json`. Console output then also goes to `Documents\...\Extender Logs\Extender Runtime *.log`.

## 3. How vanilla UIs are positioned

Each vanilla UI is a Flash (Iggy/Scaleform) movie. During `onEventInit` it registers itself and asks the engine to pin it to the screen, for example from Epip's decompiled `playerInfo` ActionScript:

```as3
ExternalInterface.call("registerAnchorId", "playerInfo");
ExternalInterface.call("setAnchor", "topleft", "screen", "topleft");
```

The engine then keeps the UIObject at that anchor. `UIObject:SetPosition()` from Lua is overridden straight away for anchored UIs: the minimap's position read back as unchanged after every attempt. Draggable windows behave differently because their drag (`startMoveWindow`) takes them off the anchor, which is why Epip's UILayout can use `SetPosition` for them.

Diagnostic values for the two UIs, as logged by the mod:

| UI | `GetPosition()` | `FlashMovieSize` (flash units) | `FlashSize` (px) | Anchor |
|---|---|---|---|---|
| `playerInfo` (portraits) | 0, 0 | 1920 x 2000 | 2560 x 2666 | topleft |
| `minimap` | 4560, 0 | 420 x 2000 | 560 x 2666 | topright |

Anything drawn outside a UI's `FlashSize` rectangle is clipped.

## 4. Party portraits: offset the flash root

`playerInfo` covers a large area from the top-left corner, so its contents can move freely inside it. The mod sets `root.x` / `root.y` on the movie's MainTimeline, in flash units. Epip's `Features.ScrollablePlayerInfo` uses the same idea: it scrolls by moving `root.container_mc.y`. Moving the root rather than `container_mc` leaves Epip's scrolling intact.

Limit: the portrait UI area ends at 2560 px. The portraits can be offset right only until they reach that edge.

## 5. Minimap: re-anchor, widen, then offset

Three attempts, in order:

1. **Offset the flash root** as for the portraits. The minimap moved, but everything outside its 560 px area at x = 4560 was clipped, so the left part of the minimap disappeared.
2. **`UIObject:SetPosition()`.** No effect: the engine re-applies the top-right anchor.
3. **`ui:Resize()` to the viewport width.** `FlashSize` became 5120 px wide, but the UI stayed anchored at x = 4560, so the extra width ran off the right edge of the screen. `Resize()` doesn't scale the contents. It changes `FlashSize` while `FlashMovieSize` stays at 420, so flash units still convert to pixels at the UI scale, not at `FlashSize / FlashMovieSize`.

What works: call the same anchor function the movie uses, re-pinning it to the top-left, then widen it to cover the whole screen:

```lua
ui:ExternalInterfaceCall("setAnchor", "topleft", "screen", "topleft")
ui:Resize(math.ceil(viewportWidth / uiScale), movieHeight, uiScale)
```

The UI now sits at 0, 0 and is 5120 px wide, so the root can be offset anywhere on screen without clipping. Minimap positions are saved in screen pixels (root origin = UI position + root offset × UI scale), so they don't depend on the UI's own position. Reset reverses it: root back to 0, 0, `Resize` back to `FlashMovieSize`, and `setAnchor` back to `topright`.

### The hidden ring: `hackIcon_mc`

Widening the minimap revealed a ring-with-dots graphic to its right. Listing `minimap.swf`'s placements with `tools/swfinspect.py` (vanilla file from `Game.pak` → `Public/Game/GUI/minimap.swf`):

```
pingButton_mc   x=106  y=136
homestead_mc    x=111  y=94
north_mc        x=268  y=158
tension_mc      x=254  y=294
hackIcon_mc     x=581  y=129   <- beyond the 420-wide movie
```

Everything else sits inside the movie; `hackIcon_mc` (containing a single `track_mc`) is the only element outside it, so vanilla never shows it. It has no tooltip or handler, and its name appears only where it is placed. The game seems to hide it simply by placing it outside the drawn area. The mod hides it with `visible = false` while the minimap is widened, and makes it visible again on reset. My guess is that it keeps a tracking-marker graphic loaded off-screen, but that is unconfirmed.

## 6. Packaging

- DOS2 DE uses **LSPK v13**. The header sits at the *end* of the file: the header struct, then `uint32 headerSize`, then `"LSPK"`. The file list is an LZ4 block of 280-byte entries (name[256], offset, sizeOnDisk, uncompressedSize, archivePart, flags, crc). `tools/lspk.py` was checked by listing and extracting Epip's own 77 MB package.
- Every non-empty file in Epip's package uses compression flags `0x11` (zlib, default level), so `lspk.py` writes the same. The file list is stored as a literal-only LZ4 block, which is valid LZ4 and needs no compressor.
- **PublishVersion matters.** With `PublishVersion` 1.0.0.0, the game listed the mod as *"Incompatible mod! A mod published using the Classic Edition is not compatible with the Definitive Edition"*. Copying Epip's value, `909321303` (3.6.51.9303), fixed it. `build.py` refuses anything below that.
- Version fields are packed as `major<<28 | minor<<24 | revision<<16 | build`.

## 7. Input notes

- Ctrl+Shift+O never reached the mod on the test machine, while P and M did, presumably because another program captures that combination. Ctrl+Shift+Backspace was added as a reset alternative, and every Ctrl+Shift key the mod receives is logged to make this kind of problem visible.
- `Ext.Events.SessionLoaded` fires on every load. In the Epip add-on version, subscribing to Epip's input event there had to be guarded to happen once; otherwise a duplicated handler picked up and dropped a panel on the same keypress. The standalone version subscribes to `RawInput` once at file load, which avoids the problem.
