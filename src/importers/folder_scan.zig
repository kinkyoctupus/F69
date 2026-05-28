// Folder-scan importer — sweeps a directory of installed games and
// emits one `ImportedGame` per top-level subdir whose tree contains
// a recognised engine fingerprint (`renpy/bootstrap.py`,
// `UnityPlayer.so`, `www/js/rpg_managers.js`, etc.). The folder that
// contains the fingerprint is the install root.
//
// **No F95 thread id is known up front.** The folder names don't
// carry the thread id, and we don't hit F95Zone search at scan
// time (slow + flaky on hundreds of folders). Each entry gets a
// synthetic id with the high bit set so it can't collide with a
// real F95 thread id (those are < 2^32 in practice) — the UI's
// "Sync this game" flow later resolves the synthetic against the
// real thread, OR the user explicitly links the row to an existing
// library game from the preview screen.
//
// Walk strategy:
//   1. List the scanned dir's immediate children.
//   2. For each child that is a directory, run `detectEngineDeep`
//      — fingerprint check at that level, then one level deeper,
//      bounded at `MAX_FINGERPRINT_DEPTH` to keep the cost bounded
//      for users whose collection lives on an external HDD with
//      thousands of folders.
//   3. On a hit: parse the top-level folder name for a best-effort
//      `(name, version)` and record:
//        - `name` / `version` — the editable defaults the preview
//          row shows. The UI can override before commit.
//        - `engine` — what we found, the trust anchor.
//        - `install_executable_rel = "<top>/<rel-to-fingerprint>"` —
//          the migrator copies the first path segment (the top-
//          level wrapper), so this preserves the nested layout on
//          import.
//   4. On no hit: skip silently. Companion files (PDFs, archive
//      parts) are filtered by `looksLikeCompanionFile` for logging
//      but they wouldn't fingerprint anyway, so the engine probe
//      is the source of truth here.

const std = @import("std");
const importers = @import("importers.zig");
const Engine = importers.Engine;

const log = std.log.scoped(.importers_folder);

/// Max nesting under each top-level child the scanner descends into
/// when looking for an engine fingerprint. Real-world layouts:
///   - top/                                     → depth 0
///   - top/EngineGame-1.2/                      → depth 1 (common)
///   - top/Linux/EngineGame-1.2/                → depth 2 (rare, multi-platform bundles)
///   - top/Linux/EngineGame-1.2/inner/          → depth 3 (very rare)
/// Cap at 3 — anything deeper is almost certainly noise (extracted
/// archives, leftover renpy SDKs, etc).
const MAX_FINGERPRINT_DEPTH: u8 = 3;

/// One `(engine, relpath)` pair. Reused at every dir we probe.
const Fingerprint = struct { engine: Engine, relpath: []const u8 };

/// Fingerprint table. Order = priority — earlier entries win on a tie
/// (currently only matters if a host carries both a `.so` and a `.dll`
/// for Unity, which would just yield two rows otherwise).
///
/// Notes on the less-obvious ones:
///   - GameMaker Studio: `data.win` is the runtime data archive on
///     Windows builds (e.g. `Dating Amy`).
///   - RPGM VX Ace: `Game.rgss3a` is the RGSS3 archive (e.g.
///     `Milfs_Control`, `The Artifact`).
///   - RPGM VX (older): `Game.rgssad` is the RGSS2 archive.
///   - HTML/Electron games: `index.html` at root catches things like
///     `Just one more chance` (a raw HTML5 build). Slightly broad —
///     a folder whose entry point is `index.html` is almost always a
///     game in this directory layout.
const ENGINE_FINGERPRINTS = [_]Fingerprint{
    .{ .engine = .renpy,   .relpath = "renpy/bootstrap.py" },
    .{ .engine = .rpgm_mv, .relpath = "www/js/rpg_managers.js" },
    .{ .engine = .rpgm_mz, .relpath = "js/rmmz_managers.js" },
    .{ .engine = .unity,   .relpath = "UnityPlayer.so" },
    .{ .engine = .unity,   .relpath = "UnityPlayer.dll" },
    // RPG Maker VX Ace / VX — the archive is the trust anchor; we
    // could also probe `Game.exe` but that's too generic.
    .{ .engine = .rpgm_vx, .relpath = "Game.rgss3a" },
    .{ .engine = .rpgm_vx, .relpath = "Game.rgssad" },
    // GameMaker Studio runtime archive.
    .{ .engine = .other,   .relpath = "data.win" },
    // Unreal Engine packaged build — the `Engine/Binaries` directory
    // is the canonical marker (every shipped Unreal game has it).
    // `access()` succeeds for directories too, so we can use the
    // file-probe machinery for this.
    .{ .engine = .unreal,  .relpath = "Engine/Binaries" },
    // Electron-wrapped game (e.g. Long Story Short uses
    // `resources/app/package.json` for its bundled JS app). NW.js
    // games also have a top-level `package.json` but with `www/`
    // alongside — they're caught by the rpgm_mv probe earlier.
    .{ .engine = .html,    .relpath = "resources/app/package.json" },
    // HTML5 / Electron entry point. Last so renpy/rpgm/unity win
    // when they're also present (rare but possible — e.g. a renpy
    // game packaged with an `index.html` redirect).
    .{ .engine = .html,    .relpath = "index.html" },
};

/// Parser output. Doesn't borrow from the input slice — caller can
/// drop the original buffer once this is filled.
pub const ParsedName = struct {
    name: []const u8, // cleaned, no underscores, no platform tail
    version: ?[]const u8, // raw token, with `v` prefix stripped
};

// ---- name parser ---------------------------------------------

/// Lowercase suffixes that signal "platform / build flavour / mod
/// of an unrelated kind" — when we see one of these tail tokens we
/// drop it from both the name candidate AND the version candidate.
const TAIL_NOISE = [_][]const u8{
    "pc",      "linux",   "win",     "windows", "mac",  "macos", "android",
    "ios",     "final",   "market",  "steam",   "wip",  "eng",   "rus",
    "jpn",     "multi5",  "premium", "ver",     "beta", "alpha", "demo",
    "complete",  "completed",
};

fn isTailNoise(tok: []const u8) bool {
    for (TAIL_NOISE) |s| if (std.ascii.eqlIgnoreCase(tok, s)) return true;
    return false;
}

/// File-extension / companion-file filter. Used before we even
/// consider parsing — many entries in the games dir are PDFs,
/// scripts, or multi-volume archive parts.
pub fn looksLikeCompanionFile(name: []const u8) bool {
    const lower_exts = [_][]const u8{
        ".pdf", ".txt", ".sh", ".exe", ".zip", ".rar", ".7z", ".tar", ".gz",
        ".part01", ".part02", ".part03",
    };
    // case-insensitive endswith check.
    for (lower_exts) |ext| {
        if (name.len < ext.len) continue;
        const tail = name[name.len - ext.len ..];
        if (std.ascii.eqlIgnoreCase(tail, ext)) return true;
    }
    // companion keywords anywhere in the name.
    const companion_keywords = [_][]const u8{ "walkthrough", "cheat", "guide", "scrappymod" };
    for (companion_keywords) |kw| {
        if (asciiContainsIgnoreCase(name, kw)) return true;
    }
    return false;
}

/// Best-effort parse of a folder name. Returns null when the input
/// looks like a companion file (PDF / script / archive part) or is
/// too short to be a real entry. On success, `name` points into
/// `out_buf` (caller-owned scratch) — copy out before reusing the
/// buffer.
pub fn parseFolderName(out_buf: []u8, raw: []const u8) ?ParsedName {
    if (raw.len < 3) return null;
    if (looksLikeCompanionFile(raw)) return null;
    // Skip a couple of obvious placeholders.
    if (std.ascii.eqlIgnoreCase(raw, "tbd") or std.ascii.eqlIgnoreCase(raw, "nlt")) return null;

    // Strip leading/trailing whitespace and tilde decoration the
    // upstream uses for emphasis (`~What We Found That Summer~`).
    var work = std.mem.trim(u8, raw, " \t\n\r~");
    if (work.len == 0) return null;

    // Unwrap [bracketed v1.2] and (PC) and similar — replace `[`
    // and `]` and `(` and `)` with spaces so the tokenizer below
    // treats their contents as ordinary tokens.
    if (out_buf.len < work.len) return null;
    var i: usize = 0;
    while (i < work.len) : (i += 1) {
        const c = work[i];
        out_buf[i] = switch (c) {
            '[', ']', '(', ')' => ' ',
            '_' => ' ', // underscores are word separators in folder names
            else => c,
        };
    }
    work = out_buf[0..work.len];

    // Tokenize on the union of `-` and ` `. We need original
    // positions so we can rebuild the name slice, so iterate by
    // hand rather than splitScalar.
    var tokens: [32][]const u8 = undefined;
    var token_count: usize = 0;
    {
        var t_start: usize = 0;
        var j: usize = 0;
        while (j <= work.len) : (j += 1) {
            const at_end = j == work.len;
            const sep = !at_end and (work[j] == '-' or work[j] == ' ');
            if (sep or at_end) {
                if (j > t_start) {
                    if (token_count == tokens.len) break;
                    tokens[token_count] = work[t_start..j];
                    token_count += 1;
                }
                t_start = j + 1;
            }
        }
    }
    if (token_count == 0) return null;

    // Walk tokens left → right. First version-looking token splits
    // the name from the tail. Tail noise tokens come off the name
    // tail too (e.g. `Last Hope-final` → name="Last Hope", v=null).
    var version_idx: ?usize = null;
    for (tokens[0..token_count], 0..) |t, ti| {
        if (looksLikeVersionToken(t)) {
            version_idx = ti;
            break;
        }
    }

    // Build the name from leading tokens that aren't tail-noise.
    var name_end: usize = if (version_idx) |v| v else token_count;
    while (name_end > 0 and isTailNoise(tokens[name_end - 1])) : (name_end -= 1) {}
    if (name_end == 0) return null;
    // Stitch the name back together as `tok[0] tok[1] ... tok[N-1]`
    // separated by a single space. We can reuse `out_buf` for this
    // — but careful, the tokens point INTO out_buf. Build into a
    // temporary at the end of out_buf, then memmove forward.
    var name_len: usize = 0;
    for (tokens[0..name_end]) |t| {
        name_len += t.len;
    }
    // Account for one space between each adjacent pair of tokens.
    if (name_end > 0) name_len += name_end - 1;
    if (name_end == 0) return null;
    // Scratch region: place at the END of out_buf so it doesn't
    // overlap the source tokens (which are at the start).
    const scratch_start = if (out_buf.len > name_len + name_end)
        out_buf.len - (name_len + name_end)
    else
        return null;
    var pos: usize = scratch_start;
    for (tokens[0..name_end], 0..) |t, ti| {
        if (ti > 0) {
            out_buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(out_buf[pos .. pos + t.len], t);
        pos += t.len;
    }
    const name_slice = out_buf[scratch_start..pos];

    // Version, with the leading `v`/`V` stripped if present.
    var version_slice: ?[]const u8 = null;
    if (version_idx) |vi| {
        var v = tokens[vi];
        if (v.len >= 2 and (v[0] == 'v' or v[0] == 'V') and std.ascii.isDigit(v[1])) {
            v = v[1..];
        }
        // Trim a trailing `.` that some folders carry
        // (e.g. `Babysitter-0.2.2b.-linux`).
        while (v.len > 0 and v[v.len - 1] == '.') v.len -= 1;
        if (v.len > 0) version_slice = v;
    }

    return .{ .name = name_slice, .version = version_slice };
}

/// Same shape as `f95.thread.looksLikeVersion` but local — the f95
/// module's helper is private. Recognises `1.0`, `v0.8.09r1`,
/// `1.0premium`, `0145`, `Final`, etc. Strict enough not to match
/// short tokens like `2` or words like `JK` or single chars.
fn looksLikeVersionToken(t: []const u8) bool {
    if (t.len == 0) return false;
    // v-prefixed.
    if (t.len >= 2 and (t[0] == 'v' or t[0] == 'V') and std.ascii.isDigit(t[1])) return true;
    // pure-digit start AND at least one `.` OR alpha suffix OR
    // length >= 3 — guards against the "Z" in "Mission Z" or a
    // single-digit chapter number.
    if (std.ascii.isDigit(t[0])) {
        var has_dot = false;
        var has_alpha = false;
        for (t) |c| {
            if (c == '.') has_dot = true;
            if (std.ascii.isAlphabetic(c)) has_alpha = true;
        }
        if (has_dot or has_alpha or t.len >= 3) return true;
    }
    // Bare words that map to versions.
    const end_states = [_][]const u8{ "Final", "Demo", "Beta", "Alpha", "Complete", "Completed" };
    for (end_states) |s| if (std.ascii.eqlIgnoreCase(t, s)) return true;
    return false;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, k| {
            if (std.ascii.toLower(haystack[i + k]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

// ---- directory walker ----------------------------------------

/// Scan `dir_path` and return one `ImportedGame` per top-level
/// subdirectory that contains a recognised engine fingerprint
/// anywhere up to `MAX_FINGERPRINT_DEPTH` levels deep. The folder
/// name (parsed for a best-effort `name` + `version` via
/// `parseFolderName`) decorates the row but is not the trust anchor
/// — the engine fingerprint is. Folders without any fingerprint are
/// skipped silently.
///
/// Each game's synthetic `thread_id` is the low 63 bits of
/// Wyhash(folder_name) plus the high bit set — guarantees no
/// collision with real F95 thread ids in any realistic future. The
/// preview screen's "Link" field lets the user attach the row to an
/// existing library game (real thread id) before commit; on commit
/// only the linked thread id is recorded.
pub fn scan(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) importers.Error!importers.Bundle {
    const arena_ptr = alloc.create(std.heap.ArenaAllocator) catch return importers.Error.OutOfMemory;
    errdefer alloc.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(alloc);
    errdefer arena_ptr.deinit();
    const a = arena_ptr.allocator();

    var games: std.ArrayList(importers.ImportedGame) = .empty;
    errdefer games.deinit(a);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return importers.Error.OpenFailed;
    defer dir.close(io);

    var it = dir.iterate();
    var skipped_companion: usize = 0;
    var skipped_no_engine: usize = 0;
    while (it.next(io) catch null) |entry| {
        // FUSE / NTFS mounts surface every entry as `.unknown` (no
        // d_type in their readdir). Accept that alongside
        // `.directory`; the engine probe below short-circuits if the
        // entry isn't actually walkable.
        if (entry.kind != .directory and entry.kind != .unknown) continue;

        // Drop obvious companion files BEFORE the fingerprint walk.
        // `parseFolderName` already does this for naming, but doing
        // it here too avoids one openDir attempt per `*.pdf`.
        if (looksLikeCompanionFile(entry.name)) {
            skipped_companion += 1;
            log.debug("skip (companion): {s}", .{entry.name});
            continue;
        }

        // Build "<scan_dir>/<top_level>" once, reuse for the walk.
        var top_path_buf: [1024]u8 = undefined;
        const top_path = std.fmt.bufPrint(&top_path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch {
            skipped_no_engine += 1;
            continue;
        };

        // Engine fingerprint walk. Returns the relative path FROM
        // `<scan_dir>/<top_level>` to the fingerprint file. Null
        // when no engine matched anywhere within the depth budget.
        var rel_buf: [1024]u8 = undefined;
        const hit = detectEngineDeep(io, top_path, &rel_buf) orelse {
            skipped_no_engine += 1;
            log.debug("skip (no engine fingerprint): {s}", .{entry.name});
            continue;
        };

        // Parse the *top-level* folder name for name/version. The
        // engine fingerprint guarantees this isn't a companion file,
        // so we don't gate the row on `parseFolderName` returning
        // non-null — even an unparseable name still produces a row
        // (the user can edit name + version in the preview).
        var parse_buf: [1024]u8 = undefined;
        const parsed = parseFolderName(&parse_buf, entry.name);
        const parsed_name: []const u8 = if (parsed) |p| p.name else entry.name;
        const parsed_version: ?[]const u8 = if (parsed) |p| p.version else null;

        const name_dup = a.dupe(u8, parsed_name) catch return importers.Error.OutOfMemory;
        const version_dup: ?[]const u8 = if (parsed_version) |v|
            (a.dupe(u8, v) catch return importers.Error.OutOfMemory)
        else
            null;

        // install_executable_rel:
        //   "<top_level>/<rel-from-top-to-fingerprint>"
        // The migrator uses `installDirRel` (first path segment) to
        // decide what to copy — always `<top_level>`. The remainder
        // is informational (preserves the nested layout on disk).
        const install_path = std.fmt.allocPrint(a, "{s}/{s}", .{ entry.name, hit.fingerprint_rel }) catch
            return importers.Error.OutOfMemory;

        games.append(a, .{
            .thread_id = syntheticThreadId(name_dup),
            .name = name_dup,
            .version = version_dup,
            .engine = hit.engine,
            .install_executable_rel = install_path,
        }) catch return importers.Error.OutOfMemory;
    }

    const out = games.toOwnedSlice(a) catch return importers.Error.OutOfMemory;
    log.info("folder scan: found {d} game(s) ({d} companion, {d} non-engine skipped)", .{ out.len, skipped_companion, skipped_no_engine });
    return .{ .arena = arena_ptr, .games = out };
}

// ---- engine fingerprint walker -------------------------------

/// Result of a successful fingerprint probe.
pub const FingerprintHit = struct {
    engine: Engine,
    /// Relative path from the searched base down to the fingerprint
    /// file (e.g. `"renpy/bootstrap.py"` for a top-level Ren'Py
    /// install, or `"AboveTheClouds-0.8/renpy/bootstrap.py"` for a
    /// wrapper-folder layout).
    fingerprint_rel: []const u8,
};

/// Check whether `<base>/<fp.relpath>` exists for any fingerprint in
/// the table; on hit, write the matching `relpath` into `out_buf` and
/// return the `(engine, slice)` pair. The slice points into `out_buf`.
fn detectEngineAt(io: std.Io, base: []const u8, out_buf: []u8) ?FingerprintHit {
    for (ENGINE_FINGERPRINTS) |fp| {
        var probe_buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&probe_buf, "{s}/{s}", .{ base, fp.relpath }) catch continue;
        std.Io.Dir.cwd().access(io, full, .{}) catch |e| {
            std.log.scoped(.importers_folder).debug("  probe miss {s} ({s})", .{ full, @errorName(e) });
            continue;
        };
        std.log.scoped(.importers_folder).info("  probe HIT  {s}", .{full});
        if (fp.relpath.len > out_buf.len) continue;
        @memcpy(out_buf[0..fp.relpath.len], fp.relpath);
        return .{ .engine = fp.engine, .fingerprint_rel = out_buf[0..fp.relpath.len] };
    }
    // Fallback: any `*.exe` in this directory. The vast majority of
    // F95 "single .exe in a folder" distributions are older RPG
    // Maker games (2000 / 2003 / VX / VX Ace) whose runtime archive
    // got missed by the named probes. Default-assume RPGM VX —
    // it's the most common older-RPGM engine and the user can fix
    // it on the preview row if it's actually something else
    // (Wolf RPG, custom engine, etc.).
    return findExeFingerprint(io, base, out_buf);
}

fn findExeFingerprint(io: std.Io, base: []const u8, out_buf: []u8) ?FingerprintHit {
    var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        // FUSE NTFS returns `.unknown` for everything — accept it
        // alongside `.file` so the fallback still fires there.
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (entry.name.len < 5) continue; // need ".exe" + 1 char
        const tail = entry.name[entry.name.len - 4 ..];
        if (!std.ascii.eqlIgnoreCase(tail, ".exe")) continue;
        if (entry.name.len > out_buf.len) continue;
        @memcpy(out_buf[0..entry.name.len], entry.name);
        std.log.scoped(.importers_folder).info("  probe HIT (exe fallback) {s}/{s}", .{ base, entry.name });
        return .{ .engine = .rpgm_vx, .fingerprint_rel = out_buf[0..entry.name.len] };
    }
    return null;
}

/// Engine probe at `base`, then up to `MAX_FINGERPRINT_DEPTH-1` levels
/// deeper. Returns the FIRST hit (depth-first, alphabetical iteration
/// order). The `fingerprint_rel` field on the result is rooted at
/// `base` — e.g. for a hit at `<base>/Wrapper/renpy/bootstrap.py` the
/// returned `fingerprint_rel` is `"Wrapper/renpy/bootstrap.py"`.
pub fn detectEngineDeep(io: std.Io, base: []const u8, out_buf: []u8) ?FingerprintHit {
    return detectEngineDeepImpl(io, base, "", out_buf, 0);
}

fn detectEngineDeepImpl(
    io: std.Io,
    base: []const u8,
    rel_prefix: []const u8,
    out_buf: []u8,
    depth: u8,
) ?FingerprintHit {
    // 1. Probe at this level. On hit, prepend the running prefix and
    //    return.
    {
        var hit_buf: [1024]u8 = undefined;
        if (detectEngineAt(io, base, &hit_buf)) |hit| {
            if (rel_prefix.len + hit.fingerprint_rel.len > out_buf.len) return null;
            if (rel_prefix.len == 0) {
                @memcpy(out_buf[0..hit.fingerprint_rel.len], hit.fingerprint_rel);
                return .{ .engine = hit.engine, .fingerprint_rel = out_buf[0..hit.fingerprint_rel.len] };
            }
            // "<rel_prefix>/<hit.fingerprint_rel>"
            const total = rel_prefix.len + 1 + hit.fingerprint_rel.len;
            if (total > out_buf.len) return null;
            @memcpy(out_buf[0..rel_prefix.len], rel_prefix);
            out_buf[rel_prefix.len] = '/';
            @memcpy(out_buf[rel_prefix.len + 1 .. total], hit.fingerprint_rel);
            return .{ .engine = hit.engine, .fingerprint_rel = out_buf[0..total] };
        }
    }

    // 2. Descend one level if we still have budget.
    if (depth + 1 >= MAX_FINGERPRINT_DEPTH) return null;

    var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .unknown) continue;

        // child base = "<base>/<entry.name>"
        var child_base_buf: [1024]u8 = undefined;
        const child_base = std.fmt.bufPrint(&child_base_buf, "{s}/{s}", .{ base, entry.name }) catch continue;

        // running rel prefix = "<rel_prefix>/<entry.name>" or "<entry.name>"
        var child_prefix_buf: [1024]u8 = undefined;
        const child_prefix = if (rel_prefix.len == 0)
            (std.fmt.bufPrint(&child_prefix_buf, "{s}", .{entry.name}) catch continue)
        else
            (std.fmt.bufPrint(&child_prefix_buf, "{s}/{s}", .{ rel_prefix, entry.name }) catch continue);

        if (detectEngineDeepImpl(io, child_base, child_prefix, out_buf, depth + 1)) |hit| return hit;
    }
    return null;
}

/// Synthetic thread-id strategy: hash the cleaned folder name and
/// set the high bit. The library's primary key is a `u64` and real
/// F95 thread ids are < 2^32, so the high-bit-set range is empty
/// in practice. We use that range for "this row hasn't been
/// resolved to a real F95 thread yet". When the user later runs
/// Sync on such a row, the workflow will: (1) search F95Zone for
/// the name, (2) on a hit, swap the synthetic id for the real one.
pub fn syntheticThreadId(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0xF01DE2, name) | (@as(u64, 1) << 63);
}

/// True iff a thread id was produced by `syntheticThreadId`.
/// UI uses this to label rows "(unresolved)" and offer a Sync
/// button that searches F95Zone for the name.
pub fn isSyntheticThreadId(tid: u64) bool {
    return (tid & (@as(u64, 1) << 63)) != 0;
}

// ---- tests against the user's actual folder list -------------

test "parseFolderName: name-version-platform" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "AHouseInTheRift-0.8.09r1-pc").?;
    try std.testing.expectEqualStrings("AHouseInTheRift", p.name);
    try std.testing.expectEqualStrings("0.8.09r1", p.version.?);
}

test "parseFolderName: name-version-platform-final" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "DepravedAwakening-1.0-pc-final").?;
    try std.testing.expectEqualStrings("DepravedAwakening", p.name);
    try std.testing.expectEqualStrings("1.0", p.version.?);
}

test "parseFolderName: underscore + v-prefix" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "Adventure_with_Mother_RPG_v1.0").?;
    try std.testing.expectEqualStrings("Adventure with Mother RPG", p.name);
    try std.testing.expectEqualStrings("1.0", p.version.?);
}

test "parseFolderName: spaces + dotted version" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "Beauty and the Thug 0.4.5").?;
    try std.testing.expectEqualStrings("Beauty and the Thug", p.name);
    try std.testing.expectEqualStrings("0.4.5", p.version.?);
}

test "parseFolderName: bracketed version + extra suffix" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "Bones' Tales The Manor [v0.30.3]").?;
    try std.testing.expectEqualStrings("Bones' Tales The Manor", p.name);
    try std.testing.expectEqualStrings("0.30.3", p.version.?);
}

test "parseFolderName: trailing dot stripped" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "Babysitter-0.2.2b.-linux").?;
    try std.testing.expectEqualStrings("Babysitter", p.name);
    try std.testing.expectEqualStrings("0.2.2b", p.version.?);
}

test "parseFolderName: name only, no version" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "Dating Amy").?;
    try std.testing.expectEqualStrings("Dating Amy", p.name);
    try std.testing.expect(p.version == null);
}

test "parseFolderName: companion file rejected" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(parseFolderName(&buf, "Acting_Lessons_Walkthrough.pdf") == null);
    try std.testing.expect(parseFolderName(&buf, "fix-linux-games.sh") == null);
    try std.testing.expect(parseFolderName(&buf, "Reunion-0.75-pc_zip.part01") == null);
    try std.testing.expect(parseFolderName(&buf, "Beauty_and_the_thug_Walkthrough_0.4.0.pdf") == null);
}

test "parseFolderName: placeholders rejected" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(parseFolderName(&buf, "tbd") == null);
    try std.testing.expect(parseFolderName(&buf, "NLT") == null);
}

test "parseFolderName: 'Steam' suffix dropped from name" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "Survival Mission Z Steam").?;
    // No version found; the "Steam" tail is tail-noise and stripped.
    try std.testing.expectEqualStrings("Survival Mission Z", p.name);
    try std.testing.expect(p.version == null);
}

test "parseFolderName: Karryn's Prison-style with trailer" {
    var buf: [256]u8 = undefined;
    const p = parseFolderName(&buf, "Karryn's Prison v1.3.1.25 SUCCUBUS").?;
    try std.testing.expectEqualStrings("Karryn's Prison", p.name);
    try std.testing.expectEqualStrings("1.3.1.25", p.version.?);
}

test "syntheticThreadId: high bit always set" {
    const a = syntheticThreadId("Acting Lessons");
    const b = syntheticThreadId("Dating Amy");
    try std.testing.expect(isSyntheticThreadId(a));
    try std.testing.expect(isSyntheticThreadId(b));
    try std.testing.expect(a != b);
}

// ---- engine fingerprint walker tests -----------------------

const test_env = @import("util_test_env");

test "detectEngineDeep: Ren'Py at top level" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "scan-renpy-top");
    defer env.deinit();
    try env.touchFile("renpy/bootstrap.py");

    var buf: [256]u8 = undefined;
    const hit = detectEngineDeep(env.io, env.root, &buf).?;
    try std.testing.expectEqual(Engine.renpy, hit.engine);
    try std.testing.expectEqualStrings("renpy/bootstrap.py", hit.fingerprint_rel);
}

test "detectEngineDeep: Ren'Py one wrapper deep" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "scan-renpy-wrap");
    defer env.deinit();
    try env.touchFile("AboveTheClouds-0.8/renpy/bootstrap.py");

    var buf: [256]u8 = undefined;
    const hit = detectEngineDeep(env.io, env.root, &buf).?;
    try std.testing.expectEqual(Engine.renpy, hit.engine);
    try std.testing.expectEqualStrings("AboveTheClouds-0.8/renpy/bootstrap.py", hit.fingerprint_rel);
}

test "detectEngineDeep: Unity .so wins over RPGM in sibling" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "scan-unity");
    defer env.deinit();
    try env.touchFile("inner/UnityPlayer.so");

    var buf: [256]u8 = undefined;
    const hit = detectEngineDeep(env.io, env.root, &buf).?;
    try std.testing.expectEqual(Engine.unity, hit.engine);
    try std.testing.expectEqualStrings("inner/UnityPlayer.so", hit.fingerprint_rel);
}

test "detectEngineDeep: RPGM MZ recognised" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "scan-rpgm-mz");
    defer env.deinit();
    try env.touchFile("game/js/rmmz_managers.js");

    var buf: [256]u8 = undefined;
    const hit = detectEngineDeep(env.io, env.root, &buf).?;
    try std.testing.expectEqual(Engine.rpgm_mz, hit.engine);
}

test "detectEngineDeep: depth budget respected" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "scan-too-deep");
    defer env.deinit();
    // 4 levels deep — beyond MAX_FINGERPRINT_DEPTH = 3 from env.root.
    try env.touchFile("a/b/c/d/renpy/bootstrap.py");

    var buf: [256]u8 = undefined;
    try std.testing.expect(detectEngineDeep(env.io, env.root, &buf) == null);
}

test "scan: emits one game per top-level engine hit" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "scan-mixed");
    defer env.deinit();

    try env.touchFile("AboveTheClouds-0.8/renpy/bootstrap.py");
    try env.touchFile("KarrynsPrison-v1.3/UnityPlayer.so"); // wrong, just need a fingerprint
    try env.touchFile("Notes.pdf"); // companion — ignored
    try env.mkdirP("EmptyFolder"); // no engine — ignored

    var bundle = try scan(ta, env.io, env.root);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(usize, 2), bundle.games.len);
    // Engines should be populated. Order isn't guaranteed across
    // filesystems so check by name.
    var saw_renpy = false;
    var saw_unity = false;
    for (bundle.games) |g| {
        if (g.engine == .renpy and std.mem.eql(u8, g.name, "AboveTheClouds")) saw_renpy = true;
        if (g.engine == .unity and std.mem.eql(u8, g.name, "KarrynsPrison")) saw_unity = true;
    }
    try std.testing.expect(saw_renpy);
    try std.testing.expect(saw_unity);
}
