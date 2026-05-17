// User-supplied mod archive storage — per-game subdir + sidecar index.
//
// Layout under `<data_root>/mod-archives/`:
//
//     <game_thread_id>/
//         index.json         — array of Modfile records
//         <basename>         — verbatim archive copy
//         <basename>-2       — collision-suffix when needed
//
// Lifecycle ownership:
//   - We always COPY from the user-picked source; the original file
//     stays where it was. Explicit "Delete" in the UI is the only
//     way to remove an archive from disk.
//   - Modfile.id == sha256 hex of the content. Dedup is global
//     (across all games) — adding the same archive twice surfaces
//     the existing record's location.
//   - `recipe_id` on the record is null until the wizard authors a
//     mod recipe for this archive; the UI Mods-tab Install button
//     uses `findByRecipe(game_thread, recipe_id)` to resolve back
//     from a recipe to its file at install time.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.mod_archives);
const atomic_io = @import("util_atomic_io");

/// Recognized archive suffixes, longest first so `.tar.gz` matches
/// before `.gz`.
pub const KNOWN_EXTS = [_][]const u8{
    ".tar.gz",
    ".tar.bz2",
    ".tar.xz",
    ".tar.zst",
    ".zip",
    ".7z",
    ".rar",
    ".gz",
    ".bz2",
    ".xz",
    ".zst",
    ".tar",
};

/// Sidecar filename inside each per-game dir.
const INDEX_FILENAME = "index.json";

/// One modfile in a game's store. Persisted as JSON in `index.json`.
pub const Modfile = struct {
    /// sha256 hex (lowercase, 64 chars). Doubles as the stable id.
    id: []const u8,
    /// Original basename as displayed to the user. May differ from
    /// `disk_name` when a collision forced a suffix.
    filename: []const u8,
    /// Actual basename on disk inside the game subdir.
    disk_name: []const u8,
    /// File size, captured at add time.
    size_bytes: u64,
    /// Unix epoch seconds — when this entry was first added.
    added_at: i64,
    /// Recipe ids this modfile is linked to. One archive can back
    /// multiple recipes — same files, different install plans (e.g.
    /// one for game v0.20 + one for v0.21). Empty until the user
    /// authors at least one recipe.
    recipe_ids: []const []const u8 = &.{},
    /// Auto-detected install preset id (e.g. "renpy-overlay"). Set by
    /// `setPresetId` after the add path runs detection. Null until
    /// detection has run, OR when no preset matched. The UI uses it
    /// to pre-fill the install-steps block in the wizard / inline
    /// editor; the user can override.
    preset_id: ?[]const u8 = null,
};

/// Result of an Add call. `duplicate` carries enough info for the UI
/// to show "Already managed as <basename> for game <id>".
pub const AddResult = union(enum) {
    added: Modfile,
    duplicate: struct {
        /// Which game already owns this content.
        game_thread_id: u64,
        existing: Modfile,
    },
};

pub const Error = error{
    NotAnArchive,
    SourceNotFound,
    ReadFailed,
    WriteFailed,
    IndexCorrupt,
    OutOfMemory,
};

// ============================================================
//  Path helpers
// ============================================================

pub fn extOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    for (KNOWN_EXTS) |ext| {
        if (base.len >= ext.len and std.ascii.eqlIgnoreCase(base[base.len - ext.len ..], ext)) {
            return ext;
        }
    }
    return std.fs.path.extension(base);
}

pub fn isArchive(path: []const u8) bool {
    const e = extOf(path);
    for (KNOWN_EXTS) |k| {
        if (std.ascii.eqlIgnoreCase(e, k)) return true;
    }
    return false;
}

fn gameDirAlloc(alloc: std.mem.Allocator, dest_root: []const u8, game_thread_id: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{d}", .{ dest_root, game_thread_id });
}

fn indexPathAlloc(alloc: std.mem.Allocator, dest_root: []const u8, game_thread_id: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{ dest_root, game_thread_id, INDEX_FILENAME });
}

pub fn modfilePathAlloc(alloc: std.mem.Allocator, dest_root: []const u8, game_thread_id: u64, disk_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{ dest_root, game_thread_id, disk_name });
}

/// Wall-clock seconds since the unix epoch. Uses `std.Io.Clock` —
/// `std.time.timestamp` doesn't exist in this Zig version.
fn nowSeconds(io: Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return ts.raw.toSeconds();
}

// ============================================================
//  Hashing
// ============================================================

/// SHA-256 of file contents, returned as 64-char lowercase hex,
/// allocator-owned. Also writes byte count into `out_size` if non-null.
pub fn hashFile(alloc: std.mem.Allocator, io: Io, path: []const u8, out_size: ?*u64) ![]u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return Error.SourceNotFound,
        else => return Error.ReadFailed,
    };
    defer f.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Two distinct buffers: one backs the reader, the other receives
    // each chunk. Sharing them aliases the @memcpy inside
    // `readSliceShort` and trips Zig's safety check.
    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var reader = f.reader(io, &rd_buf);
    var total: u64 = 0;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch return Error.ReadFailed;
        if (n == 0) break;
        hasher.update(chunk[0..n]);
        total += n;
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    if (out_size) |s| s.* = total;

    const hex_arr = std.fmt.bytesToHex(digest, .lower);
    const hex = try alloc.alloc(u8, 64);
    @memcpy(hex, &hex_arr);
    return hex;
}

// ============================================================
//  Index (JSON) load / save
// ============================================================

/// Load the per-game index. Missing file → empty list. Caller takes
/// ownership of returned slice + its strings.
pub fn loadIndex(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
) ![]Modfile {
    const path = try indexPathAlloc(alloc, dest_root, game_thread_id);
    defer alloc.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 * 1024 * 1024)) catch |e| switch (e) {
        // Empty literal, not `alloc.alloc(Modfile, 0)` — keeps the
        // `if (mods.len > 0) alloc.free(mods)` guard in
        // freeModfileList from leaking the zero-length allocation.
        error.FileNotFound => return &[_]Modfile{},
        else => return Error.ReadFailed,
    };
    defer alloc.free(bytes);

    return parseIndex(alloc, bytes);
}

fn parseIndex(alloc: std.mem.Allocator, bytes: []const u8) ![]Modfile {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return Error.IndexCorrupt;
    defer parsed.deinit();

    if (parsed.value != .array) return Error.IndexCorrupt;

    var out: std.ArrayList(Modfile) = .empty;
    errdefer {
        for (out.items) |m| freeModfile(alloc, m);
        out.deinit(alloc);
    }

    for (parsed.value.array.items) |v| {
        if (v != .object) return Error.IndexCorrupt;
        const obj = v.object;
        const id = (obj.get("id") orelse return Error.IndexCorrupt);
        const filename = (obj.get("filename") orelse return Error.IndexCorrupt);
        const disk_name = (obj.get("disk_name") orelse return Error.IndexCorrupt);
        const size_v = (obj.get("size_bytes") orelse return Error.IndexCorrupt);
        const added_v = (obj.get("added_at") orelse return Error.IndexCorrupt);
        if (id != .string or filename != .string or disk_name != .string) return Error.IndexCorrupt;
        if (size_v != .integer or added_v != .integer) return Error.IndexCorrupt;

        // Recipe linkage. Accepts the legacy `recipe_id: <str|null>`
        // field (one-recipe-per-archive) AND the new `recipe_ids: []`
        // form. Either populates the same in-memory slice.
        var recipe_ids_opt: ?[]const []const u8 = null;
        if (obj.get("recipe_ids")) |arr_v| switch (arr_v) {
            .null => {},
            .array => |arr| {
                var collected: std.ArrayList([]const u8) = .empty;
                errdefer collected.deinit(alloc);
                for (arr.items) |el| switch (el) {
                    .string => |s| try collected.append(alloc, s),
                    else => return Error.IndexCorrupt,
                };
                recipe_ids_opt = try collected.toOwnedSlice(alloc);
            },
            else => return Error.IndexCorrupt,
        };
        if (recipe_ids_opt == null) {
            if (obj.get("recipe_id")) |legacy| switch (legacy) {
                .null => {},
                .string => |s| {
                    const single = try alloc.alloc([]const u8, 1);
                    single[0] = s;
                    recipe_ids_opt = single;
                },
                else => return Error.IndexCorrupt,
            };
        }

        // Forward-compat: older indexes don't have `preset_id` at all.
        // `get` → null is fine; a JSON null also degrades cleanly.
        const preset_id_opt: ?[]const u8 = blk: {
            const r = obj.get("preset_id") orelse break :blk null;
            switch (r) {
                .null => break :blk null,
                .string => |s| break :blk s,
                else => return Error.IndexCorrupt,
            }
        };

        // Allocate strings as locals with their own errdefers so a
        // mid-struct OOM doesn't leak the already-duped fields.
        // Errdefers go out of scope at end-of-iteration; on success
        // ownership moves into the appended Modfile.
        const id_dup = try alloc.dupe(u8, id.string);
        errdefer alloc.free(id_dup);
        const filename_dup = try alloc.dupe(u8, filename.string);
        errdefer alloc.free(filename_dup);
        const disk_dup = try alloc.dupe(u8, disk_name.string);
        errdefer alloc.free(disk_dup);
        // Deep-dupe each linked recipe id onto the modfile's own
        // ownership so the parser arena (JSON `parsed`) can be
        // released without dangling the modfile.
        const recipe_ids_dup: [][]const u8 = blk: {
            const src = recipe_ids_opt orelse {
                // Free any scratch slice — recipe_ids_opt was null
                // means we never allocated one.
                break :blk &.{};
            };
            const dup_slice = try alloc.alloc([]const u8, src.len);
            errdefer alloc.free(dup_slice);
            var did: usize = 0;
            errdefer for (dup_slice[0..did]) |s| alloc.free(s);
            while (did < src.len) : (did += 1) {
                dup_slice[did] = try alloc.dupe(u8, src[did]);
            }
            // Source slice was alloc-owned (single[]) or borrowed from
            // the JSON arena — free the slice container; inner strings
            // either alias the arena or were just released via did.
            alloc.free(src);
            break :blk dup_slice;
        };
        errdefer {
            for (recipe_ids_dup) |s| alloc.free(s);
            if (recipe_ids_dup.len > 0) alloc.free(recipe_ids_dup);
        }

        const preset_id_dup: ?[]u8 = if (preset_id_opt) |s| blk: {
            break :blk try alloc.dupe(u8, s);
        } else null;
        errdefer if (preset_id_dup) |r| alloc.free(r);

        try out.append(alloc, .{
            .id = id_dup,
            .filename = filename_dup,
            .disk_name = disk_dup,
            .size_bytes = @intCast(size_v.integer),
            .added_at = added_v.integer,
            .recipe_ids = recipe_ids_dup,
            .preset_id = preset_id_dup,
        });
    }

    return out.toOwnedSlice(alloc) catch return Error.OutOfMemory;
}

pub fn freeModfileList(alloc: std.mem.Allocator, mods: []const Modfile) void {
    for (mods) |m| freeModfile(alloc, m);
    if (mods.len > 0) alloc.free(mods);
}

pub fn freeModfile(alloc: std.mem.Allocator, m: Modfile) void {
    alloc.free(m.id);
    alloc.free(m.filename);
    alloc.free(m.disk_name);
    for (m.recipe_ids) |r| alloc.free(r);
    if (m.recipe_ids.len > 0) alloc.free(m.recipe_ids);
    if (m.preset_id) |p| alloc.free(p);
}

/// Persist the index. Writes to `index.json.tmp` then renames so a
/// crash mid-write can never leave a partial index.
pub fn saveIndex(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
    mods: []const Modfile,
) !void {
    const dir = try gameDirAlloc(alloc, dest_root, game_thread_id);
    defer alloc.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch return Error.WriteFailed;

    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(alloc, 1024) catch return Error.OutOfMemory;
    defer aw.deinit();

    try aw.writer.writeAll("[");
    for (mods, 0..) |m, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.writeAll("\n  {\"id\":");
        try writeJsonString(&aw.writer, m.id);
        try aw.writer.writeAll(",\"filename\":");
        try writeJsonString(&aw.writer, m.filename);
        try aw.writer.writeAll(",\"disk_name\":");
        try writeJsonString(&aw.writer, m.disk_name);
        try aw.writer.print(",\"size_bytes\":{d},\"added_at\":{d},\"recipe_ids\":[", .{ m.size_bytes, m.added_at });
        for (m.recipe_ids, 0..) |r, ri| {
            if (ri > 0) try aw.writer.writeAll(",");
            try writeJsonString(&aw.writer, r);
        }
        try aw.writer.writeAll("]");
        try aw.writer.writeAll(",\"preset_id\":");
        if (m.preset_id) |p| {
            try writeJsonString(&aw.writer, p);
        } else {
            try aw.writer.writeAll("null");
        }
        try aw.writer.writeAll("}");
    }
    try aw.writer.writeAll("\n]\n");

    const path = try indexPathAlloc(alloc, dest_root, game_thread_id);
    defer alloc.free(path);
    atomic_io.writeFileAtomic(io, path, aw.writer.buffered()) catch return Error.WriteFailed;
}

/// Write `s` as a JSON-quoted, escape-correct string. Basenames can
/// legitimately contain `"`, `\`, newlines, etc. on POSIX, so naïve
/// printing into JSON corrupts the index on reload. This emits the
/// surrounding quotes too — callers don't add them.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ============================================================
//  Add — copy + hash + dedup
// ============================================================

/// Hash `src_path`, dedup across all games, and on success copy it
/// into the per-game store with index update. Source file is never
/// deleted — we always copy.
pub fn addForGame(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
    src_path: []const u8,
) !AddResult {
    if (!isArchive(src_path)) return Error.NotAnArchive;

    var size: u64 = 0;
    const sha = try hashFile(alloc, io, src_path, &size);
    errdefer alloc.free(sha);

    // Global dedup: scan every game's index for this hash.
    if (try globalFindBySha(alloc, io, dest_root, sha)) |hit| {
        alloc.free(sha);
        return AddResult{ .duplicate = .{
            .game_thread_id = hit.game_thread_id,
            .existing = hit.modfile,
        } };
    }

    const game_dir = try gameDirAlloc(alloc, dest_root, game_thread_id);
    defer alloc.free(game_dir);
    std.Io.Dir.cwd().createDirPath(io, game_dir) catch return Error.WriteFailed;

    const basename = std.fs.path.basename(src_path);
    const disk_name = try pickAvailableDiskName(alloc, io, game_dir, basename);
    errdefer alloc.free(disk_name);

    const dest = try modfilePathAlloc(alloc, dest_root, game_thread_id, disk_name);
    defer alloc.free(dest);

    try copyFile(io, src_path, dest);
    errdefer std.Io.Dir.cwd().deleteFile(io, dest) catch {};

    const current = try loadIndex(alloc, io, dest_root, game_thread_id);
    defer freeModfileList(alloc, current);

    var next: std.ArrayList(Modfile) = .empty;
    defer next.deinit(alloc);
    try next.appendSlice(alloc, current);

    const now = nowSeconds(io);
    try next.append(alloc, .{
        .id = sha,
        .filename = basename,
        .disk_name = disk_name,
        .size_bytes = size,
        .added_at = now,
        .recipe_ids = &.{},
    });

    try saveIndex(alloc, io, dest_root, game_thread_id, next.items);

    // Return a deep copy so caller's lifetime is independent of the
    // strings we own locally. Allocate the dupes as locals first so
    // a mid-construction OOM cleans up the earlier dupes rather than
    // leaking them under a half-built struct literal.
    const out_id = try alloc.dupe(u8, sha);
    errdefer alloc.free(out_id);
    const out_filename = try alloc.dupe(u8, basename);
    errdefer alloc.free(out_filename);
    const out_disk = try alloc.dupe(u8, disk_name);
    errdefer alloc.free(out_disk);

    alloc.free(sha);
    alloc.free(disk_name);

    const out = Modfile{
        .id = out_id,
        .filename = out_filename,
        .disk_name = out_disk,
        .size_bytes = size,
        .added_at = now,
        .recipe_ids = &.{},
    };

    log.info("added mod for game {d}: {s} ({d} bytes)", .{ game_thread_id, basename, size });
    return AddResult{ .added = out };
}

/// Pick a unique disk basename in `game_dir`. Returns original if
/// free, otherwise appends `-2`, `-3`, … before the extension.
fn pickAvailableDiskName(
    alloc: std.mem.Allocator,
    io: Io,
    game_dir: []const u8,
    desired: []const u8,
) ![]u8 {
    const ext = extOf(desired);
    const stem_len = if (ext.len > 0 and ext.len <= desired.len) desired.len - ext.len else desired.len;
    const stem = desired[0..stem_len];

    var n: u32 = 1;
    while (true) : (n += 1) {
        const candidate = if (n == 1)
            try alloc.dupe(u8, desired)
        else
            try std.fmt.allocPrint(alloc, "{s}-{d}{s}", .{ stem, n, ext });
        errdefer alloc.free(candidate);

        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ game_dir, candidate });
        defer alloc.free(full);

        const exists = (std.Io.Dir.cwd().access(io, full, .{}) catch null) != null;
        if (!exists) return candidate;
        alloc.free(candidate);

        if (n > 9999) return Error.WriteFailed; // pathological collision
    }
}

// ============================================================
//  Lookup
// ============================================================

/// Look up by SHA across every game's index. Returns null if not
/// present anywhere. Result is owned (caller frees via freeModfile).
pub fn globalFindBySha(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    sha_hex: []const u8,
) !?struct { game_thread_id: u64, modfile: Modfile } {
    var root = std.Io.Dir.cwd().openDir(io, dest_root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return Error.ReadFailed,
    };
    defer root.close(io);

    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const game_thread = std.fmt.parseUnsigned(u64, entry.name, 10) catch continue;

        const mods = loadIndex(alloc, io, dest_root, game_thread) catch continue;
        defer freeModfileList(alloc, mods);

        for (mods) |m| {
            if (std.mem.eql(u8, m.id, sha_hex)) {
                // Dupe each field as a local first so a mid-construction
                // OOM doesn't leak earlier dupes via an abandoned
                // struct literal.
                const id_d = try alloc.dupe(u8, m.id);
                errdefer alloc.free(id_d);
                const filename_d = try alloc.dupe(u8, m.filename);
                errdefer alloc.free(filename_d);
                const disk_d = try alloc.dupe(u8, m.disk_name);
                errdefer alloc.free(disk_d);
                const recipe_ids_d = try dupeRecipeIds(alloc, m.recipe_ids);

                return .{
                    .game_thread_id = game_thread,
                    .modfile = .{
                        .id = id_d,
                        .filename = filename_d,
                        .disk_name = disk_d,
                        .size_bytes = m.size_bytes,
                        .added_at = m.added_at,
                        .recipe_ids = recipe_ids_d,
                    },
                };
            }
        }
    }
    return null;
}

/// Deep-dupe a `[]const []const u8` slice of recipe ids. Used by
/// every "return a fresh Modfile" path so caller's lifetime is
/// independent of the loaded index.
fn dupeRecipeIds(alloc: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
    if (src.len == 0) return &.{};
    const out = try alloc.alloc([]const u8, src.len);
    errdefer alloc.free(out);
    var i: usize = 0;
    errdefer for (out[0..i]) |s| alloc.free(s);
    while (i < src.len) : (i += 1) {
        out[i] = try alloc.dupe(u8, src[i]);
    }
    return out;
}

/// Find the modfile linked to a specific recipe id in a given game's
/// store. Returns null if no entry has `recipe_id == recipe_id_q`.
pub fn findByRecipe(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
    recipe_id_q: []const u8,
) !?Modfile {
    const mods = try loadIndex(alloc, io, dest_root, game_thread_id);
    defer freeModfileList(alloc, mods);

    for (mods) |m| {
        for (m.recipe_ids) |r| {
            if (!std.mem.eql(u8, r, recipe_id_q)) continue;
            const id_d = try alloc.dupe(u8, m.id);
            errdefer alloc.free(id_d);
            const filename_d = try alloc.dupe(u8, m.filename);
            errdefer alloc.free(filename_d);
            const disk_d = try alloc.dupe(u8, m.disk_name);
            errdefer alloc.free(disk_d);
            const recipe_ids_d = try dupeRecipeIds(alloc, m.recipe_ids);

            return .{
                .id = id_d,
                .filename = filename_d,
                .disk_name = disk_d,
                .size_bytes = m.size_bytes,
                .added_at = m.added_at,
                .recipe_ids = recipe_ids_d,
            };
        }
    }
    return null;
}

// ============================================================
//  Mutation: link / delete / scan
// ============================================================

/// Bind a recipe id to an existing modfile. Idempotent.
pub fn linkRecipe(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
    modfile_id: []const u8,
    recipe_id: []const u8,
) !void {
    const mods = try loadIndex(alloc, io, dest_root, game_thread_id);
    defer freeModfileList(alloc, mods);

    var found = false;
    for (mods) |*m| {
        if (!std.mem.eql(u8, m.id, modfile_id)) continue;
        // Dedup — same id twice in the list serves no purpose.
        var already = false;
        for (m.recipe_ids) |existing| {
            if (std.mem.eql(u8, existing, recipe_id)) {
                already = true;
                break;
            }
        }
        if (!already) {
            const new_slice = try alloc.alloc([]const u8, m.recipe_ids.len + 1);
            errdefer alloc.free(new_slice);
            for (m.recipe_ids, 0..) |old, i| new_slice[i] = old;
            new_slice[m.recipe_ids.len] = try alloc.dupe(u8, recipe_id);
            // Free the old outer slice; inner strings ownership moved.
            if (m.recipe_ids.len > 0) alloc.free(m.recipe_ids);
            m.recipe_ids = new_slice;
        }
        found = true;
        break;
    }
    if (!found) return Error.SourceNotFound;

    try saveIndex(alloc, io, dest_root, game_thread_id, mods);
}

/// Pin / clear a preset id on an existing modfile. Pass `null` to
/// clear (no preset matched). Idempotent.
pub fn setPresetId(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
    modfile_id: []const u8,
    preset_id: ?[]const u8,
) !void {
    const mods = try loadIndex(alloc, io, dest_root, game_thread_id);
    defer freeModfileList(alloc, mods);

    var found = false;
    for (mods) |*m| {
        if (std.mem.eql(u8, m.id, modfile_id)) {
            if (m.preset_id) |old| alloc.free(old);
            m.preset_id = if (preset_id) |p| try alloc.dupe(u8, p) else null;
            found = true;
            break;
        }
    }
    if (!found) return Error.SourceNotFound;

    try saveIndex(alloc, io, dest_root, game_thread_id, mods);
}

/// Remove a single recipe id from a modfile's link list (recipe
/// deleted upstream). No-op when the modfile or the id isn't found.
/// `recipe_id` can be null to clear ALL links (legacy "this archive
/// is being unlinked entirely" semantics).
pub fn unlinkRecipe(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
    modfile_id: []const u8,
    recipe_id: ?[]const u8,
) !void {
    const mods = try loadIndex(alloc, io, dest_root, game_thread_id);
    defer freeModfileList(alloc, mods);

    for (mods) |*m| {
        if (!std.mem.eql(u8, m.id, modfile_id)) continue;
        if (recipe_id) |target| {
            // Remove one matching id; keep the others.
            var match_idx: ?usize = null;
            for (m.recipe_ids, 0..) |existing, i| {
                if (std.mem.eql(u8, existing, target)) {
                    match_idx = i;
                    break;
                }
            }
            if (match_idx) |hit| {
                alloc.free(m.recipe_ids[hit]);
                const new_len = m.recipe_ids.len - 1;
                if (new_len == 0) {
                    alloc.free(m.recipe_ids);
                    m.recipe_ids = &.{};
                } else {
                    const new_slice = try alloc.alloc([]const u8, new_len);
                    var w: usize = 0;
                    for (m.recipe_ids, 0..) |existing, i| {
                        if (i == hit) continue;
                        new_slice[w] = existing;
                        w += 1;
                    }
                    alloc.free(m.recipe_ids);
                    m.recipe_ids = new_slice;
                }
            }
        } else {
            // Clear every link.
            for (m.recipe_ids) |s| alloc.free(s);
            if (m.recipe_ids.len > 0) alloc.free(m.recipe_ids);
            m.recipe_ids = &.{};
        }
        break;
    }
    try saveIndex(alloc, io, dest_root, game_thread_id, mods);
}

/// Delete the archive from disk and drop its index entry.
pub fn deleteForGame(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
    modfile_id: []const u8,
) !void {
    const mods = try loadIndex(alloc, io, dest_root, game_thread_id);
    defer freeModfileList(alloc, mods);

    var keep: std.ArrayList(Modfile) = .empty;
    defer keep.deinit(alloc);

    var target_disk: ?[]const u8 = null;
    for (mods) |m| {
        if (std.mem.eql(u8, m.id, modfile_id)) {
            target_disk = m.disk_name;
            continue;
        }
        try keep.append(alloc, m);
    }
    if (target_disk == null) return Error.SourceNotFound;

    const full = try modfilePathAlloc(alloc, dest_root, game_thread_id, target_disk.?);
    defer alloc.free(full);
    std.Io.Dir.cwd().deleteFile(io, full) catch |e| switch (e) {
        error.FileNotFound => {}, // missing on disk; still drop the index entry
        else => return Error.WriteFailed,
    };

    try saveIndex(alloc, io, dest_root, game_thread_id, keep.items);
    log.info("deleted modfile {s} for game {d}", .{ modfile_id, game_thread_id });
}

pub const ScanDuplicate = struct {
    basename: []const u8,
    existing_game_thread_id: u64,
};

pub const ScanReport = struct {
    added: []const Modfile,
    unchanged: u32,
    duplicates_skipped: []const ScanDuplicate,
    non_archive_skipped: []const []const u8,
    removed_missing: u32,

    pub fn deinit(self: *ScanReport, alloc: std.mem.Allocator) void {
        freeModfileList(alloc, self.added);
        for (self.duplicates_skipped) |d| alloc.free(d.basename);
        if (self.duplicates_skipped.len > 0) alloc.free(self.duplicates_skipped);
        for (self.non_archive_skipped) |s| alloc.free(s);
        if (self.non_archive_skipped.len > 0) alloc.free(self.non_archive_skipped);
        self.* = undefined;
    }
};

/// Walk the per-game dir, ingesting any file not yet in the index.
/// Hashes new files (slow for large archives — caller should run
/// this off the UI thread). Returns a report of what changed.
pub fn scanForGame(
    alloc: std.mem.Allocator,
    io: Io,
    dest_root: []const u8,
    game_thread_id: u64,
) !ScanReport {
    const game_dir = try gameDirAlloc(alloc, dest_root, game_thread_id);
    defer alloc.free(game_dir);
    std.Io.Dir.cwd().createDirPath(io, game_dir) catch return Error.WriteFailed;

    const existing = try loadIndex(alloc, io, dest_root, game_thread_id);
    defer freeModfileList(alloc, existing);

    var dir = std.Io.Dir.cwd().openDir(io, game_dir, .{ .iterate = true }) catch return Error.ReadFailed;
    defer dir.close(io);

    var on_disk: std.StringHashMap(void) = .init(alloc);
    defer {
        var k = on_disk.keyIterator();
        while (k.next()) |kp| alloc.free(kp.*);
        on_disk.deinit();
    }

    var added_list: std.ArrayList(Modfile) = .empty;
    defer added_list.deinit(alloc);
    var dup_list: std.ArrayList(ScanDuplicate) = .empty;
    defer dup_list.deinit(alloc);
    var nonarch_list: std.ArrayList([]const u8) = .empty;
    defer nonarch_list.deinit(alloc);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, INDEX_FILENAME)) continue;
        if (std.mem.endsWith(u8, entry.name, ".tmp")) continue;

        try on_disk.put(try alloc.dupe(u8, entry.name), {});

        // Already indexed under this disk_name?
        var already = false;
        for (existing) |m| {
            if (std.mem.eql(u8, m.disk_name, entry.name)) {
                already = true;
                break;
            }
        }
        if (already) continue;

        if (!isArchive(entry.name)) {
            try nonarch_list.append(alloc, try alloc.dupe(u8, entry.name));
            continue;
        }

        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ game_dir, entry.name });
        defer alloc.free(full);

        var size: u64 = 0;
        const sha = try hashFile(alloc, io, full, &size);
        errdefer alloc.free(sha);

        // Dedup against any game (including this one's existing list).
        var dup_owner: ?u64 = null;
        for (existing) |m| {
            if (std.mem.eql(u8, m.id, sha)) {
                dup_owner = game_thread_id;
                break;
            }
        }
        if (dup_owner == null) {
            if (try globalFindBySha(alloc, io, dest_root, sha)) |hit| {
                var copy = hit.modfile;
                freeModfile(alloc, copy);
                _ = &copy;
                dup_owner = hit.game_thread_id;
            }
        }
        if (dup_owner) |owner| {
            alloc.free(sha);
            try dup_list.append(alloc, .{
                .basename = try alloc.dupe(u8, entry.name),
                .existing_game_thread_id = owner,
            });
            continue;
        }

        try added_list.append(alloc, .{
            .id = sha,
            .filename = try alloc.dupe(u8, entry.name),
            .disk_name = try alloc.dupe(u8, entry.name),
            .size_bytes = size,
            .added_at = nowSeconds(io),
            .recipe_ids = &.{},
        });
    }

    // Build the final index: existing entries whose disk file still
    // exists, plus the newly added ones.
    var next: std.ArrayList(Modfile) = .empty;
    defer next.deinit(alloc);
    var removed_missing: u32 = 0;
    var unchanged: u32 = 0;
    for (existing) |m| {
        if (on_disk.contains(m.disk_name)) {
            try next.append(alloc, m);
            unchanged += 1;
        } else {
            removed_missing += 1;
        }
    }
    for (added_list.items) |m| try next.append(alloc, m);

    try saveIndex(alloc, io, dest_root, game_thread_id, next.items);

    return ScanReport{
        .added = try added_list.toOwnedSlice(alloc),
        .unchanged = unchanged,
        .duplicates_skipped = try dup_list.toOwnedSlice(alloc),
        .non_archive_skipped = try nonarch_list.toOwnedSlice(alloc),
        .removed_missing = removed_missing,
    };
}

/// Absolute on-disk path for a modfile. Caller frees.
pub fn diskPathOf(alloc: std.mem.Allocator, dest_root: []const u8, game_thread_id: u64, m: Modfile) ![]u8 {
    return modfilePathAlloc(alloc, dest_root, game_thread_id, m.disk_name);
}

// ============================================================
//  Internal I/O
// ============================================================

fn copyFile(io: Io, src: []const u8, dst: []const u8) !void {
    var in = std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only }) catch return Error.SourceNotFound;
    defer in.close(io);
    if (std.fs.path.dirname(dst)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch return Error.WriteFailed;
    var out = std.Io.Dir.cwd().createFile(io, dst, .{ .truncate = true }) catch return Error.WriteFailed;
    defer out.close(io);

    // Same aliasing trap as hashFile — keep the reader's backing
    // buffer distinct from the chunk we hand to its readSliceShort.
    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    while (true) {
        const got = in_reader.interface.readSliceShort(&chunk) catch return Error.ReadFailed;
        if (got == 0) break;
        out_writer.interface.writeAll(chunk[0..got]) catch return Error.WriteFailed;
    }
    out_writer.interface.flush() catch return Error.WriteFailed;
    const st = in.stat(io) catch return;
    out.setPermissions(io, st.permissions) catch {};
}

// ============================================================
//  Tests
// ============================================================

const testing = std.testing;

fn writeTestFile(io: Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [128]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
}

test "extOf: known + unknown extensions" {
    try testing.expectEqualStrings(".tar.gz", extOf("/tmp/foo.tar.gz"));
    try testing.expectEqualStrings(".7z", extOf("/tmp/bar.7z"));
    try testing.expectEqualStrings(".zip", extOf("/tmp/baz.ZIP"));
    try testing.expectEqualStrings("", extOf("/tmp/noext"));
}

test "isArchive: positive / negative" {
    try testing.expect(isArchive("foo.zip"));
    try testing.expect(isArchive("foo.tar.gz"));
    try testing.expect(!isArchive("foo.txt"));
    try testing.expect(!isArchive("readme"));
}

test "addForGame: copies, indexes, returns added" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-add";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const src = "/tmp/f69-ma-add-src.zip";
    std.Io.Dir.cwd().deleteFile(io, src) catch {};
    try writeTestFile(io, src, "fake-archive-payload-1");
    defer std.Io.Dir.cwd().deleteFile(io, src) catch {};

    const res = try addForGame(testing.allocator, io, root, 42, src);
    switch (res) {
        .added => |m| {
            defer freeModfile(testing.allocator, m);
            try testing.expectEqual(@as(usize, 64), m.id.len);
            try testing.expectEqualStrings("f69-ma-add-src.zip", m.filename);
            try testing.expectEqualStrings("f69-ma-add-src.zip", m.disk_name);
            try testing.expect(m.size_bytes > 0);
            try testing.expectEqual(@as(usize, 0), m.recipe_ids.len);
        },
        .duplicate => return error.TestExpectedAdded,
    }

    // Source still exists (we copy, not move).
    _ = try std.Io.Dir.cwd().access(io, src, .{});

    const mods = try loadIndex(testing.allocator, io, root, 42);
    defer freeModfileList(testing.allocator, mods);
    try testing.expectEqual(@as(usize, 1), mods.len);
    try testing.expectEqualStrings("f69-ma-add-src.zip", mods[0].filename);
}

test "addForGame: same content twice → duplicate" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-dup";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const src = "/tmp/f69-ma-dup-src.zip";
    std.Io.Dir.cwd().deleteFile(io, src) catch {};
    try writeTestFile(io, src, "same-bytes");
    defer std.Io.Dir.cwd().deleteFile(io, src) catch {};

    const r1 = try addForGame(testing.allocator, io, root,100, src);
    switch (r1) {
        .added => |m| freeModfile(testing.allocator, m),
        .duplicate => return error.TestExpectedAdded,
    }

    const r2 = try addForGame(testing.allocator, io, root,200, src);
    switch (r2) {
        .added => return error.TestExpectedDuplicate,
        .duplicate => |d| {
            defer freeModfile(testing.allocator, d.existing);
            try testing.expectEqual(@as(u64, 100), d.game_thread_id);
        },
    }
}

test "addForGame: filename collision different hash → suffix" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-coll";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Two different files with the same basename — different staging dirs.
    const dir_a = "/tmp/f69-ma-coll-a";
    const dir_b = "/tmp/f69-ma-coll-b";
    std.Io.Dir.cwd().deleteTree(io, dir_a) catch {};
    std.Io.Dir.cwd().deleteTree(io, dir_b) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_a) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_b) catch {};

    try writeTestFile(io, "/tmp/f69-ma-coll-a/mod.zip", "alpha");
    try writeTestFile(io, "/tmp/f69-ma-coll-b/mod.zip", "beta-different");

    const r1 = try addForGame(testing.allocator, io, root,7, "/tmp/f69-ma-coll-a/mod.zip");
    switch (r1) {
        .added => |m| {
            defer freeModfile(testing.allocator, m);
            try testing.expectEqualStrings("mod.zip", m.disk_name);
        },
        .duplicate => return error.TestExpectedAdded,
    }

    const r2 = try addForGame(testing.allocator, io, root,7, "/tmp/f69-ma-coll-b/mod.zip");
    switch (r2) {
        .added => |m| {
            defer freeModfile(testing.allocator, m);
            try testing.expectEqualStrings("mod-2.zip", m.disk_name);
            try testing.expectEqualStrings("mod.zip", m.filename);
        },
        .duplicate => return error.TestExpectedAdded,
    }
}

test "addForGame: non-archive rejected" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-nonarch";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const src = "/tmp/f69-ma-nonarch.txt";
    std.Io.Dir.cwd().deleteFile(io, src) catch {};
    try writeTestFile(io, src, "just text");
    defer std.Io.Dir.cwd().deleteFile(io, src) catch {};

    try testing.expectError(Error.NotAnArchive, addForGame(testing.allocator, io, root, 1, src));
}

test "linkRecipe + findByRecipe round-trip" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-link";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const src = "/tmp/f69-ma-link.zip";
    std.Io.Dir.cwd().deleteFile(io, src) catch {};
    try writeTestFile(io, src, "linker-bytes");
    defer std.Io.Dir.cwd().deleteFile(io, src) catch {};

    const r = try addForGame(testing.allocator, io, root,9, src);
    var modfile_id: []u8 = undefined;
    switch (r) {
        .added => |m| {
            modfile_id = try testing.allocator.dupe(u8, m.id);
            freeModfile(testing.allocator, m);
        },
        .duplicate => return error.TestExpectedAdded,
    }
    defer testing.allocator.free(modfile_id);

    try linkRecipe(testing.allocator, io, root, 9, modfile_id, "incest-patch");

    const found = try findByRecipe(testing.allocator, io, root, 9, "incest-patch");
    try testing.expect(found != null);
    defer freeModfile(testing.allocator, found.?);
    try testing.expectEqualStrings(modfile_id, found.?.id);
    try testing.expectEqual(@as(usize, 1), found.?.recipe_ids.len);
    try testing.expectEqualStrings("incest-patch", found.?.recipe_ids[0]);

    const not_found = try findByRecipe(testing.allocator, io, root, 9, "nope");
    try testing.expect(not_found == null);
}

test "deleteForGame: removes from disk + index" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-del";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const src = "/tmp/f69-ma-del.zip";
    std.Io.Dir.cwd().deleteFile(io, src) catch {};
    try writeTestFile(io, src, "to-delete");
    defer std.Io.Dir.cwd().deleteFile(io, src) catch {};

    const r = try addForGame(testing.allocator, io, root,3, src);
    var id_owned: []u8 = undefined;
    var disk_owned: []u8 = undefined;
    switch (r) {
        .added => |m| {
            id_owned = try testing.allocator.dupe(u8, m.id);
            disk_owned = try testing.allocator.dupe(u8, m.disk_name);
            freeModfile(testing.allocator, m);
        },
        .duplicate => return error.TestExpectedAdded,
    }
    defer testing.allocator.free(id_owned);
    defer testing.allocator.free(disk_owned);

    const disk_full = try modfilePathAlloc(testing.allocator, root, 3, disk_owned);
    defer testing.allocator.free(disk_full);
    _ = try std.Io.Dir.cwd().access(io, disk_full, .{});

    try deleteForGame(testing.allocator, io, root, 3, id_owned);

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, disk_full, .{}));
    const mods = try loadIndex(testing.allocator, io, root, 3);
    defer freeModfileList(testing.allocator, mods);
    try testing.expectEqual(@as(usize, 0), mods.len);
}

test "scanForGame: picks up manually-pasted file" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-scan";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, "/tmp/f69-ma-scan/55");

    try writeTestFile(io, "/tmp/f69-ma-scan/55/manual.zip", "manual-paste");
    try writeTestFile(io, "/tmp/f69-ma-scan/55/readme.txt", "ignore me");

    var report = try scanForGame(testing.allocator, io, root, 55);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.added.len);
    try testing.expectEqualStrings("manual.zip", report.added[0].filename);
    try testing.expectEqual(@as(usize, 1), report.non_archive_skipped.len);
    try testing.expectEqualStrings("readme.txt", report.non_archive_skipped[0]);

    const mods = try loadIndex(testing.allocator, io, root, 55);
    defer freeModfileList(testing.allocator, mods);
    try testing.expectEqual(@as(usize, 1), mods.len);
}

test "saveIndex + loadIndex: filenames with quotes / backslashes round-trip" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-escape";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Build a Modfile by hand whose filename has a quote and a
    // backslash, plus a recipe_id that includes a newline. Naïve
    // JSON printing would corrupt the index on reload.
    const filename = "Wei\\rd \"v2\".zip";
    const recipe_id = "some-recipe\nwith-newline";
    const id_slice = try testing.allocator.alloc([]const u8, 1);
    id_slice[0] = try testing.allocator.dupe(u8, recipe_id);
    const m = Modfile{
        .id = try testing.allocator.dupe(u8, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
        .filename = try testing.allocator.dupe(u8, filename),
        .disk_name = try testing.allocator.dupe(u8, "mod.zip"),
        .size_bytes = 42,
        .added_at = 1234567890,
        .recipe_ids = id_slice,
    };
    defer freeModfile(testing.allocator, m);

    try saveIndex(testing.allocator, io, root, 99, &.{m});

    const mods = try loadIndex(testing.allocator, io, root, 99);
    defer freeModfileList(testing.allocator, mods);
    try testing.expectEqual(@as(usize, 1), mods.len);
    try testing.expectEqualStrings(filename, mods[0].filename);
    try testing.expectEqual(@as(usize, 1), mods[0].recipe_ids.len);
    try testing.expectEqualStrings(recipe_id, mods[0].recipe_ids[0]);
}

test "loadIndex: missing file returns empty without leaking" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-missing";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const mods = try loadIndex(testing.allocator, io, root, 12345);
    defer freeModfileList(testing.allocator, mods);
    try testing.expectEqual(@as(usize, 0), mods.len);
}

test "scanForGame: dedupes against another game" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const root = "/tmp/f69-ma-scan-dup";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const src = "/tmp/f69-ma-scan-dup-src.zip";
    std.Io.Dir.cwd().deleteFile(io, src) catch {};
    try writeTestFile(io, src, "shared-bytes");
    defer std.Io.Dir.cwd().deleteFile(io, src) catch {};

    const r = try addForGame(testing.allocator, io, root,1, src);
    switch (r) {
        .added => |m| freeModfile(testing.allocator, m),
        .duplicate => return error.TestExpectedAdded,
    }

    try std.Io.Dir.cwd().createDirPath(io, "/tmp/f69-ma-scan-dup/2");
    try writeTestFile(io, "/tmp/f69-ma-scan-dup/2/shared.zip", "shared-bytes");

    var report = try scanForGame(testing.allocator, io, root, 2);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), report.added.len);
    try testing.expectEqual(@as(usize, 1), report.duplicates_skipped.len);
    try testing.expectEqualStrings("shared.zip", report.duplicates_skipped[0].basename);
    try testing.expectEqual(@as(u64, 1), report.duplicates_skipped[0].existing_game_thread_id);
}
