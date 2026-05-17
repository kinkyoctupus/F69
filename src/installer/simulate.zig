// Symbolic simulation of a mod install. Walks the install-plan steps
// against the archive's entry metadata, building a virtual filesystem
// map of what *would* land on disk. No actual extraction — pure
// reasoning over file headers + the current install dir + the tracker.
//
// Output is a structured `SimulationResult` the UI can render as a
// plain-English summary, a collapsible detail tree, or both.
//
// Limitations:
//   - extract_inner is recognized but recorded as a warning + skipped.
//     Properly simulating nested archives would require extracting the
//     outer one to disk to read the inner — too expensive for the live
//     preview path. The real "Test install" button is the escape hatch.
//   - chmod_x acts on already-written entries; if a path doesn't exist
//     in the simulated state, it surfaces as a warning rather than a
//     hard error (the real installer would skip the entry too).

const std = @import("std");
const dom = @import("domain.zig");
const recipe = @import("recipe");
const archive = @import("util_archive");
const trk = @import("tracker.zig");

const Io = std.Io;

pub const Action = enum {
    /// Path is new on disk — nothing currently exists there.
    add,
    /// Path exists on disk + is NOT owned by any tracked mod (i.e. it
    /// belongs to the vanilla install). Install will overwrite it.
    overwrite_vanilla,
    /// Path exists AND the tracker says another mod owns it. Install
    /// will displace that mod's file. Highlighted as a conflict.
    overwrite_mod,
};

pub const FileWrite = struct {
    /// Path relative to `install_dir`.
    rel_path: []const u8,
    size_bytes: u64,
    action: Action,
    /// Index into the original plan (`recipe.InstallStep` slice) that
    /// produced this entry. Lets the UI cross-highlight block ↔ file.
    source_step_index: usize,
    /// Mod id that currently owns this path, when `action ==
    /// .overwrite_mod`. Null otherwise.
    conflicting_mod: ?[]const u8 = null,
};

pub const ModeChange = struct {
    rel_path: []const u8,
    executable: bool,
    source_step_index: usize,
    /// True when the path doesn't exist in the simulated state — the
    /// installer would silently skip it. UI flags as a "no-op" warning.
    missing: bool = false,
};

pub const PathDel = struct {
    rel_path: []const u8,
    /// True when the path actually exists in the simulated state (i.e.
    /// the delete will do something). False = warning (no-op).
    existed: bool,
    source_step_index: usize,
};

pub const Severity = enum { info, warn, err };

pub const Diagnostic = struct {
    severity: Severity,
    msg: []const u8,
    source_step_index: ?usize = null,
};

/// Per-step summary the UI can render under each block: "Will write
/// 142 files into <install>/game/" without traversing the full
/// writes list.
pub const StepImpact = struct {
    files_written: usize = 0,
    bytes_written: u64 = 0,
    files_modified: usize = 0,
    mode_changes: usize = 0,
    deletions: usize = 0,
    /// True if the step produced no observable effect — useful UI
    /// signal that a block is dead code (e.g. delete of a nonexistent
    /// path).
    no_op: bool = false,
};

pub const SimulationResult = struct {
    writes: []FileWrite,
    mode_changes: []ModeChange,
    deletions: []PathDel,
    diagnostics: []Diagnostic,
    /// One entry per input plan step, parallel-indexed.
    impacts: []StepImpact,
    /// The install dir the plan was simulated against — arena-owned
    /// dupe so callers (the tree-view renderer) can read it past the
    /// simulate() call's stack.
    install_dir: []const u8,
    /// Arena owns every string + the slices themselves.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *SimulationResult) void {
        self.arena.deinit();
    }

    /// True when at least one write / mode-change / deletion has a
    /// `conflicting_mod` / `overwrite_mod` annotation. UI uses this
    /// for the "⚠ this install will displace another mod's files"
    /// banner.
    pub fn hasConflicts(self: *const SimulationResult) bool {
        for (self.writes) |w| if (w.action == .overwrite_mod) return true;
        return false;
    }

    /// Count of writes whose action is `add` (new files).
    pub fn addCount(self: *const SimulationResult) usize {
        var n: usize = 0;
        for (self.writes) |w| {
            if (w.action == .add) n += 1;
        }
        return n;
    }

    pub fn overwriteVanillaCount(self: *const SimulationResult) usize {
        var n: usize = 0;
        for (self.writes) |w| {
            if (w.action == .overwrite_vanilla) n += 1;
        }
        return n;
    }

    pub fn overwriteModCount(self: *const SimulationResult) usize {
        var n: usize = 0;
        for (self.writes) |w| {
            if (w.action == .overwrite_mod) n += 1;
        }
        return n;
    }

    pub fn totalBytes(self: *const SimulationResult) u64 {
        var n: u64 = 0;
        for (self.writes) |w| n += w.size_bytes;
        return n;
    }
};

/// Build a SimulationResult from `(archive_path, plan, install_dir,
/// tracker_log_path)`. The tracker is optional — pass null when the
/// install has no `.f69-mods.json` yet (first-mod case). Errors during
/// archive read surface as `error.ArchiveUnreadable`; everything else
/// is captured as a Diagnostic.
pub fn simulate(
    parent_alloc: std.mem.Allocator,
    io: Io,
    archive_path: []const u8,
    plan: []const recipe.InstallStep,
    install_dir: []const u8,
    tracker_log_path: ?[]const u8,
) !SimulationResult {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    const entries = archive.listEntriesMeta(parent_alloc, archive_path) catch return error.ArchiveUnreadable;
    defer archive.freeEntryMetas(parent_alloc, entries);

    // Pre-load tracker once (cheap; small JSON line-delimited file).
    var tracker_log: ?dom.InstallLog = null;
    defer if (tracker_log) |*log| log.deinit(parent_alloc);
    if (tracker_log_path) |p| {
        const loaded = trk.Tracker.load(parent_alloc, io, p) catch null;
        tracker_log = loaded;
    }

    // Virtual filesystem. Key = rel-path under install_dir. We use the
    // arena alloc for keys so they outlive each step's mutations.
    var vfs: std.StringHashMap(VfsEntry) = .init(aalloc);

    // Pre-seed VFS with current real install contents — only paths
    // matched by any step's writes get queried (lazy via on-demand
    // Dir.access in `classifyAction`), so we don't have to enumerate
    // the whole install dir upfront.

    var writes: std.ArrayList(FileWrite) = .empty;
    var mode_changes: std.ArrayList(ModeChange) = .empty;
    var deletions: std.ArrayList(PathDel) = .empty;
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    var impacts: std.ArrayList(StepImpact) = .empty;
    try impacts.appendNTimes(aalloc, .{}, plan.len);

    for (plan, 0..) |step, step_idx| {
        switch (step) {
            .extract => |x| try simulateExtract(aalloc, &vfs, entries, x.to, x.strip, step_idx, &diagnostics, &impacts.items[step_idx]),
            .extract_inner => {
                try diagnostics.append(aalloc, .{
                    .severity = .info,
                    .msg = "Nested archive (extract_inner) — preview can't see inside without a real extract. Use Test install to verify.",
                    .source_step_index = step_idx,
                });
                impacts.items[step_idx].no_op = true;
            },
            .copy => |x| try simulateCopy(aalloc, &vfs, x.src, x.dest, step_idx, &diagnostics, &impacts.items[step_idx]),
            .move => |x| try simulateMove(aalloc, &vfs, x.src, x.dest, step_idx, &diagnostics, &impacts.items[step_idx]),
            .delete => |x| try simulateDelete(aalloc, &vfs, x.path, step_idx, &deletions, &diagnostics, &impacts.items[step_idx]),
            .chmod_x => |x| try simulateChmodX(aalloc, &vfs, x.paths, step_idx, &mode_changes, &diagnostics, &impacts.items[step_idx]),
        }
    }

    // Classify each VFS entry as add / overwrite-vanilla / overwrite-mod.
    var it = vfs.iterator();
    while (it.next()) |kv| {
        const rel = kv.key_ptr.*;
        const ent = kv.value_ptr.*;
        if (ent.deleted) continue;

        const action_info = classifyAction(io, install_dir, rel, tracker_log);
        try writes.append(aalloc, .{
            .rel_path = rel,
            .size_bytes = ent.size_bytes,
            .action = action_info.action,
            .source_step_index = ent.source_step_index,
            .conflicting_mod = action_info.conflicting_mod,
        });
        const imp = &impacts.items[ent.source_step_index];
        imp.files_written += 1;
        imp.bytes_written += ent.size_bytes;
        if (action_info.action != .add) imp.files_modified += 1;
    }

    return .{
        .writes = try writes.toOwnedSlice(aalloc),
        .mode_changes = try mode_changes.toOwnedSlice(aalloc),
        .deletions = try deletions.toOwnedSlice(aalloc),
        .diagnostics = try diagnostics.toOwnedSlice(aalloc),
        .impacts = try impacts.toOwnedSlice(aalloc),
        .install_dir = try aalloc.dupe(u8, install_dir),
        .arena = arena,
    };
}

// ============================================================
//  Internal helpers
// ============================================================

const VfsEntry = struct {
    size_bytes: u64,
    source_step_index: usize,
    executable: bool = false,
    deleted: bool = false,
};

const ActionInfo = struct {
    action: Action,
    conflicting_mod: ?[]const u8 = null,
};

fn classifyAction(io: Io, install_dir: []const u8, rel: []const u8, tracker_log: ?dom.InstallLog) ActionInfo {
    var path_buf: [2048]u8 = undefined;
    const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, rel }) catch return .{ .action = .add };
    const exists = (std.Io.Dir.cwd().access(io, full, .{}) catch null) != null;
    if (!exists) return .{ .action = .add };

    if (tracker_log) |log| {
        for (log.entries) |e| {
            if (std.mem.eql(u8, e.path, rel) and e.mod_id.len > 0) {
                return .{ .action = .overwrite_mod, .conflicting_mod = e.mod_id };
            }
        }
    }
    return .{ .action = .overwrite_vanilla };
}

fn simulateExtract(
    aalloc: std.mem.Allocator,
    vfs: *std.StringHashMap(VfsEntry),
    entries: []const archive.EntryMeta,
    to_raw: []const u8,
    strip: u8,
    step_idx: usize,
    diagnostics: *std.ArrayList(Diagnostic),
    impact: *StepImpact,
) !void {
    _ = diagnostics;
    const to_clean = trimRelPrefix(to_raw);

    for (entries) |e| {
        if (e.is_dir) continue;
        const stripped_opt = stripPathComponents(e.path, strip);
        const stripped = stripped_opt orelse continue;
        const rel = if (to_clean.len == 0)
            try aalloc.dupe(u8, stripped)
        else
            try std.fmt.allocPrint(aalloc, "{s}/{s}", .{ to_clean, stripped });

        try putVfs(aalloc, vfs, rel, .{
            .size_bytes = e.size_bytes,
            .source_step_index = step_idx,
        });
    }
    _ = impact; // counts filled in classify pass
}

fn simulateCopy(
    aalloc: std.mem.Allocator,
    vfs: *std.StringHashMap(VfsEntry),
    src_raw: []const u8,
    dest_raw: []const u8,
    step_idx: usize,
    diagnostics: *std.ArrayList(Diagnostic),
    impact: *StepImpact,
) !void {
    const src = trimRelPrefix(src_raw);
    const dest = trimRelPrefix(dest_raw);
    const src_key = vfs.getKey(src);
    if (src_key == null) {
        try diagnostics.append(aalloc, .{
            .severity = .warn,
            .msg = try std.fmt.allocPrint(aalloc, "Copy source `{s}` not produced by any prior step.", .{src}),
            .source_step_index = step_idx,
        });
        impact.no_op = true;
        return;
    }
    const src_entry = vfs.get(src_key.?).?;
    const dest_key = try aalloc.dupe(u8, dest);
    try vfs.put(dest_key, .{
        .size_bytes = src_entry.size_bytes,
        .source_step_index = step_idx,
        .executable = src_entry.executable,
    });
}

fn simulateMove(
    aalloc: std.mem.Allocator,
    vfs: *std.StringHashMap(VfsEntry),
    src_raw: []const u8,
    dest_raw: []const u8,
    step_idx: usize,
    diagnostics: *std.ArrayList(Diagnostic),
    impact: *StepImpact,
) !void {
    const src = trimRelPrefix(src_raw);
    const dest = trimRelPrefix(dest_raw);
    if (!vfs.contains(src)) {
        try diagnostics.append(aalloc, .{
            .severity = .warn,
            .msg = try std.fmt.allocPrint(aalloc, "Move source `{s}` not present at this point in the plan.", .{src}),
            .source_step_index = step_idx,
        });
        impact.no_op = true;
        return;
    }
    const old = vfs.get(src).?;
    _ = vfs.remove(src);
    const dest_key = try aalloc.dupe(u8, dest);
    try vfs.put(dest_key, .{
        .size_bytes = old.size_bytes,
        .source_step_index = step_idx,
        .executable = old.executable,
    });
}

fn simulateDelete(
    aalloc: std.mem.Allocator,
    vfs: *std.StringHashMap(VfsEntry),
    path_raw: []const u8,
    step_idx: usize,
    deletions: *std.ArrayList(PathDel),
    diagnostics: *std.ArrayList(Diagnostic),
    impact: *StepImpact,
) !void {
    const p = trimRelPrefix(path_raw);
    const existed = vfs.contains(p);
    if (existed) _ = vfs.remove(p);

    const path_owned = try aalloc.dupe(u8, p);
    try deletions.append(aalloc, .{
        .rel_path = path_owned,
        .existed = existed,
        .source_step_index = step_idx,
    });
    impact.deletions += 1;
    if (!existed) {
        try diagnostics.append(aalloc, .{
            .severity = .info,
            .msg = try std.fmt.allocPrint(aalloc, "Delete `{s}` — no matching file produced by earlier steps (will affect on-disk file if present).", .{p}),
            .source_step_index = step_idx,
        });
    }
}

fn simulateChmodX(
    aalloc: std.mem.Allocator,
    vfs: *std.StringHashMap(VfsEntry),
    paths: []const []const u8,
    step_idx: usize,
    mode_changes: *std.ArrayList(ModeChange),
    diagnostics: *std.ArrayList(Diagnostic),
    impact: *StepImpact,
) !void {
    for (paths) |raw| {
        const p = trimRelPrefix(raw);
        const present = vfs.getEntry(p);
        if (present) |entry| entry.value_ptr.executable = true;
        const path_owned = try aalloc.dupe(u8, p);
        try mode_changes.append(aalloc, .{
            .rel_path = path_owned,
            .executable = true,
            .source_step_index = step_idx,
            .missing = present == null,
        });
        impact.mode_changes += 1;
        if (present == null) {
            try diagnostics.append(aalloc, .{
                .severity = .info,
                .msg = try std.fmt.allocPrint(aalloc, "chmod +x `{s}` — file not produced by earlier steps; will only apply if path exists on disk at install time.", .{p}),
                .source_step_index = step_idx,
            });
        }
    }
}

fn putVfs(aalloc: std.mem.Allocator, vfs: *std.StringHashMap(VfsEntry), rel_owned: []u8, e: VfsEntry) !void {
    // Reuse existing key string if the path collides — keeps the
    // arena from accumulating duplicate keys for each overwrite.
    if (vfs.getEntry(rel_owned)) |existing| {
        existing.value_ptr.* = e;
        // rel_owned is leaked into the arena; arena cleans up on deinit.
        return;
    }
    try vfs.put(rel_owned, e);
    _ = aalloc;
}

/// Drop "./" / "/" prefix from a recipe-supplied relative path. The
/// installer normalizes the same way; mirroring keeps the simulator
/// honest. Returns the cleaned slice (aliasing input).
fn trimRelPrefix(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 0 and (s[0] == '/' or (s.len >= 2 and s[0] == '.' and s[1] == '/'))) {
        if (s[0] == '/') {
            s = s[1..];
        } else {
            s = s[2..];
        }
    }
    if (std.mem.eql(u8, s, ".")) return "";
    return s;
}

/// Drop N leading path components. Returns null when N is larger than
/// the path's depth (entry is skipped — same as the real extractor).
fn stripPathComponents(path: []const u8, n: u8) ?[]const u8 {
    if (n == 0) return path;
    var rest = path;
    var stripped: u8 = 0;
    while (stripped < n) : (stripped += 1) {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash + 1 ..];
        if (rest.len == 0) return null;
    }
    return rest;
}

// ============================================================
//  Tests
// ============================================================

test "stripPathComponents basics" {
    try std.testing.expectEqualStrings("foo.rpy", stripPathComponents("game/foo.rpy", 1).?);
    try std.testing.expectEqualStrings("sub/foo.rpy", stripPathComponents("game/sub/foo.rpy", 1).?);
    try std.testing.expect(stripPathComponents("foo.rpy", 1) == null);
    try std.testing.expect(stripPathComponents("game/", 1) == null);
}

test "trimRelPrefix variants" {
    try std.testing.expectEqualStrings("game/foo", trimRelPrefix("./game/foo"));
    try std.testing.expectEqualStrings("game/foo", trimRelPrefix("/game/foo"));
    try std.testing.expectEqualStrings("game/foo", trimRelPrefix(".//game/foo"));
    try std.testing.expectEqualStrings("", trimRelPrefix("."));
    try std.testing.expectEqualStrings("game", trimRelPrefix("game"));
}
