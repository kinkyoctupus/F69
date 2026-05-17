# spike-04-dvui-busy-screen — findings

PoC code: `spikes/spike-04-dvui-busy-screen.zig`. Run via `zig build spike-dvui -Dgui=true`.

Goal: confirm dvui can carry the project before committing phase-1 to it. Render the busiest screen surface (1500-game grid + game-detail modal with 50-mod list + reorder controls) and watch for show-stoppers.

## Test — ✅ partially tested 2026-05-08

**Setup:** 1500 synthetic game cards (4-column grid, ~280×90), each with `Open` button that pops a floating window with 50 mods (`↑/↓` reorder + enable checkbox). dvui main commit `fa3ce4f`, SDL3GPU backend, NixOS + Wayland.

**Confirmed:**
- dvui builds via `zig fetch --save git+https://github.com/david-vanderson/dvui#main` + `-Dgui=true` + `-Dbackend=sdl3gpu`.
- SDL3GPU backend initializes on NixOS Wayland.
- Window opens (1280×800), backend reports `Transfer buffer created: 16777216 bytes`, dvui logs the embedded fonts and the natural/physical sizes.
- 1500 cards render within the visible viewport.

**Not exercised in this run:**
- Scroll performance over the full 1500 cards (user didn't scroll the whole tree).
- Game-detail modal interaction (clicking `Open` on a card).
- `↑/↓` mod reorder.
- 60-fps frametime measurement (FPS counter was stripped after `std.time.nanoTimestamp` was removed in 0.16; can re-add via `std.time.Timer` later).

**Decision:** good enough to start phase 1. dvui works; if it chokes during real UI work in phase 1, we'll detect it during the first list/grid/detail iteration and either fix or switch.

## What this validated for the project

- **Module wiring:** consumer build.zig must pass `.backend = "sdl3gpu"` to the dvui dep, then import `dvui_sdl3gpu` (the dvui module) and `sdl3` (the backend module, named via `-Dbackend=sdl3gpu`). Without `.backend=`, dvui builds all backends in parallel and modules collide ("file exists in modules 'dvui' and 'dvui0'").
- **Runtime libs needed:** SDL3 dlopens `libwayland-client`, `libxkbcommon`, `libdecor`, `libX11`, `libXrandr`, `libXcursor`, `libXi`, `libGL`, `libvulkan`. flake.nix `shellHook` must export `LD_LIBRARY_PATH` to those for `nix develop` runs (and for direnv). VSCodium-bundled zig won't have this — use the nix shell.
- **dvui API surface (0.5.0-dev):**
  - `dvui.button(@src(), label, .{}, .{})` returns `bool` directly (no `.clicked()`).
  - `dvui.label(@src(), fmt, args, opts)` — Options struct does NOT have `font_style`; styling lives elsewhere (Theme).
  - `dvui.separator()` returns `WidgetData` — must `_ = dvui.separator(...)` it.
  - `dvui.box(@src(), .{ .dir = .vertical }, opts)` then `.deinit()`.
  - `dvui.scrollArea(@src(), .{}, opts)` then `.deinit()`.
  - `dvui.floatingWindow(@src(), .{}, opts)` for modals, `.deinit()`.
  - `dvui.checkbox(@src(), &bool_var, label, opts)`.
  - Drag-to-reorder is not exercised here; native dvui dragging API exists in `Dragging.zig` — defer until phase 7 when mod load-order UI lands.
- **Main-loop pattern:** `pub fn main(init: std.process.Init) !void` → `SDLBackend.initWindow(.{ .io, .allocator, .size, .title, ... })` → `dvui.Window.init(@src(), gpa, backend.backend(), .{...})` → `while (true) { win.beginWait → backend.addAllEvents → guiFrame → win.end → backend.renderPresent → backend.waitEventTimeout }`.

## Carry-forward to phase 1

When wiring `src/ui/ui.zig` for the real f69 catalog UI:

1. **Reuse the main-loop scaffolding** verbatim — proven boilerplate.
2. **Ditch SDL3GPU for SDL3 (renderer)** if any GPU-specific issues come up — `.backend = "sdl3"` (renderer-based, sdl.zig backend). More mature, fewer GPU surprises.
3. **Add a frame-time HUD** to the game-list screen during dev (`std.time.Timer` for elapsed). If render time per frame >16ms with the real DB, we have a perf problem.
4. **Don't lazy-load card images yet** — get the layout right with text-only cards first, add cover thumbnails as a separate pass with an LRU texture cache.
5. **For mod reorder** — when phase 7 hits, look at dvui's `Dragging.zig` (and `examples/sdl3gpu-ontop.zig` which does dragging) before falling back to ↑/↓ buttons.

## Phase-0 status — ALL FOUR SPIKES DONE

| Spike | Goal | Status |
|---|---|---|
| 01 — bwrap | Sandbox arg list across distros | Green on NixOS; per-distro testing deferred |
| 02 — flat-copy | Mod overlay + tracker + rollback | Green end-to-end |
| 03 — Ren'Py convert | Win→Linux conversion | Green end-to-end (network fetch deferred) |
| 04 — dvui busy screen | Pre-phase-1 GUI sanity | Green (window + render); perf check deferred to phase 1 use |

Phase 0 done. Phase 1 starts here.
