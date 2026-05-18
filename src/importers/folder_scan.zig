// Folder-scan importer — sweeps a directory of installed games and
// pulls name + version out of each subfolder's filename. Output
// shape is the same `ImportedGame` the F95Checker / xLibrary
// importers produce, so the downstream migrate + upsert flow doesn't
// care which source the bundle came from.
//
// **No F95 thread id is known up front.** The folder names don't
// carry the thread id, and we don't hit F95Zone search at scan
// time (slow + flaky on hundreds of folders). Each entry gets a
// synthetic id with the high bit set so it can't collide with a
// real F95 thread id (those are < 2^32 in practice) — the UI's
// "Sync this game" flow later resolves the synthetic against the
// real thread.
//
// Filename heuristics — extraction strategy in priority order:
//   1. Skip non-directories AND directories that look like
//      companion files (`*_walkthrough.*`, `*Cheats*.pdf`, `*.sh`,
//      `*.zip.part01`, `*.exe`, etc.). The folder list contains
//      both real game dirs and helper files dropped alongside.
//   2. Tokenize the name on `-`, `_`, and space. Bracketed bits
//      `[v1.2]` or `(PC)` are unwrapped first.
//   3. Find the first token that matches `looksLikeVersion`. The
//      tokens before it form the name; tokens after are the tail
//      (drop platform/final/steam/etc. tags from the tail).
//   4. If no version token is found, accept the name verbatim and
//      leave `version = null`. The library will show it as
//      version-unknown.

const std = @import("std");
const f95 = @import("f95");
const importers = @import("importers.zig");

const log = std.log.scoped(.importers_folder);

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

/// Scan `dir_path` and return one `ImportedGame` per subdirectory
/// whose name parses cleanly. Skipped entries (companion files,
/// unparseable names) are logged but don't fail the scan.
///
/// Each game's synthetic `thread_id` is the low 63 bits of
/// Wyhash(folder_name) plus the high bit set — guarantees no
/// collision with real F95 thread ids in any realistic future.
/// The user's "Sync this game" flow later resolves the synthetic
/// id to a real one via F95Zone search and merges the row.
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
    var skipped: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) {
            skipped += 1;
            continue;
        }
        // Parse the folder name. `parse_buf` is plenty for any
        // reasonable folder name; bigger names are rejected so we
        // don't truncate.
        var parse_buf: [1024]u8 = undefined;
        const parsed = parseFolderName(&parse_buf, entry.name) orelse {
            skipped += 1;
            log.debug("skip (unparseable): {s}", .{entry.name});
            continue;
        };

        const name_dup = a.dupe(u8, parsed.name) catch return importers.Error.OutOfMemory;
        const version_dup: ?[]const u8 = if (parsed.version) |v|
            (a.dupe(u8, v) catch return importers.Error.OutOfMemory)
        else
            null;
        // install_executable_rel: the importer downstream uses
        // `installDirRel` to pick the directory name. Give it
        // `<folder>/`; downstream will trim the trailing slash.
        const install_path = std.fmt.allocPrint(a, "{s}/", .{entry.name}) catch
            return importers.Error.OutOfMemory;

        games.append(a, .{
            .thread_id = syntheticThreadId(name_dup),
            .name = name_dup,
            .version = version_dup,
            .install_executable_rel = install_path,
        }) catch return importers.Error.OutOfMemory;
    }

    const out = games.toOwnedSlice(a) catch return importers.Error.OutOfMemory;
    log.info("folder scan: parsed {d}, skipped {d}", .{ out.len, skipped });
    return .{ .arena = arena_ptr, .games = out };
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
