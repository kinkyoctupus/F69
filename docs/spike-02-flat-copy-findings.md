# spike-02-flat-copy — findings

PoC code: `spikes/spike-02-flat-copy.zig`. Run via `zig build spike-flat-copy -- apply <base> <mod> <dest>` or `... rollback <dest>`.

Goal: validate the flat-copy + file-tracker design before committing it to `installer/{apply,tracker}.zig`.

## Synthetic test — ✅ tested 2026-05-08

**Setup:** two synthetic trees:

```
/tmp/f69-base/
  game/scripts/event.rpy   "v1 base content"
  game/scripts/main.rpy    "ren'py setup"

/tmp/f69-mod/
  game/scripts/event.rpy   "MODDED event content"   ← overwrites base
  game/cheat/menu.rpy      "new mod-only file"      ← added
```

### Apply

```
$ zig build spike-flat-copy -- apply /tmp/f69-base /tmp/f69-mod /tmp/f69-dest
[spike] done: 2 from base, 1 added by mod, 1 overwritten by mod
[spike] log:    /tmp/f69-dest/.install.log
[spike] trash:  /tmp/f69-dest/.f69-trash/  (1 pre-images)
```

`dest` ends up with `event.rpy` from the mod, `main.rpy` from base, `cheat/menu.rpy` from mod. `.install.log` is line-delimited JSON:

```
{"kind":"from_base","path":"game/scripts/event.rpy"}
{"kind":"from_base","path":"game/scripts/main.rpy"}
{"kind":"overwritten","path":"game/scripts/event.rpy","preimage_sha256":"41b4..."}
{"kind":"added","path":"game/cheat/menu.rpy"}
```

The base's pre-mod event.rpy is preserved at `.f69-trash/<sha256>` — content-addressed, deduplicated by hash.

### Rollback

```
$ zig build spike-flat-copy -- rollback /tmp/f69-dest
[spike] rollback done: 1 mod-added removed, 1 pre-images restored
```

After: `cheat/menu.rpy` deleted, `event.rpy` restored to base v1 content. Trash + log removed. Tree clean.

## What this validated

- **Recursive walk** with `Io.Dir.walker` works for the base + mod trees.
- **Pre-image preservation** via rename-into-trash works on same-fs paths (atomic, no extra IO).
- **Cross-fs fallback** path (copy + delete) is wired but not yet hit in this spike. Worth a real test where dest is on a different mount than the trash.
- **Content-addressed dedup**: trash key is sha256 hex, so two mods overwriting the same base file with the same pre-image only store one copy. Fine for v1.
- **Reverse-order rollback** correctly undoes mods without disturbing base files.

## Carry-forward to phase-7 implementation

When porting into `src/installer/`:

1. **Same log format** — JSON line-delimited, kinds `from_base | added | overwritten`. Already final.
2. **Multi-mod ordering**: this spike applies one mod. The real overlay loops through multiple mods in load order (resolver-computed). Each subsequent mod's `from_base` of the previous overlay's file should log as `overwritten`. The mechanism is already correct — just iterate.
3. **Empty dirs** are not currently tracked; only files. That's fine for Ren'Py / RPGM where empty dirs don't matter, but needs a note.
4. **Permissions** — file mode is preserved via `writeFile` (which copies bytes only); explicit `chmod` from recipe runs separately. Symlinks are NOT preserved by this naive copy — needs handling for Ren'Py games that ship some `lib/python -> python3.11` symlinks.
5. **Large files** — current copy is `readFileAlloc` + `writeFile`, all in memory. Real impl needs streaming for >100MB game archives. Use `File.Reader.streamRemaining(File.Writer)` pattern.
6. **Concurrent UI updates** — phase-1 concurrency design (worker thread + SPSC ring) needs apply/rollback to emit progress events. Today the spike is silent until completion.

## Open questions for the real impl

- **Trash retention policy?** Currently rollback wipes the trash. But for "uninstall mod, reinstall later" we'd want to keep pre-images. Lean: trash is per-install, lives until the install dir is deleted entirely. Mod uninstall restores from trash but doesn't remove other mods' pre-images.
- **Re-apply idempotency:** apply of an already-applied state currently wipes dest and starts over. Faster path: hash compare each file, skip writes when already correct. Defer to later optimization.

## Next spike

`spike-03-renpy-convert` — port a slice of `fix-linux-games.sh`'s Ren'Py path into Zig. Detect Ren'Py version from `renpy/__init__.py`, fetch matching SDK, copy `lib/py3-linux-x86_64` into target. Throwaway code; informs `convert/renpy.zig`.
