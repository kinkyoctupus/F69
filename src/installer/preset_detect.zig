// Bridge between an on-disk archive and the recipe preset matcher.
// Lists the archive's entries via `util_archive.listEntries`, then
// loads the merged built-in + user preset set and runs detection
// over it.
//
// Allocates a fresh `recipe.MergedPresetSet` per call: parses 5
// embedded ZON files + scans `<data_root>/mod-presets/` for any
// `*.preset.zon` the user has added. Sub-millisecond unless the user
// dir grows pathologically large.

const std = @import("std");
const archive = @import("util_archive");
const recipe = @import("recipe");

/// Re-export so the UI / actions layer (which doesn't import
/// util_archive directly) can still list an archive's contents.
pub const listEntries = archive.listEntries;
pub const freeEntryList = archive.freeEntryList;

pub const Error = error{
    /// Archive couldn't be opened or read.
    ArchiveUnreadable,
    /// Preset bundle parse failed (should never happen — embedded data).
    PresetLoadFailed,
    OutOfMemory,
};

pub const Detection = struct {
    /// Caller-owned dupe of the matched preset's id.
    preset_id: []u8,
    /// Same scoring confidence reported by `detectBest`.
    confidence: f32,
    /// True when the matched preset came from `<data_root>/mod-presets/`
    /// rather than the embedded built-ins. UI can flag user-authored
    /// matches differently.
    from_user: bool,

    pub fn deinit(self: Detection, alloc: std.mem.Allocator) void {
        alloc.free(self.preset_id);
    }
};

/// Run preset detection against `archive_path` for a game of `engine`.
/// `user_dir` is `<data_root>/mod-presets/` — missing dir is fine and
/// just means only built-ins are considered. Returns null when nothing
/// matched. Caller owns the `Detection` and must `deinit`.
pub fn detect(
    alloc: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    user_dir: []const u8,
    engine: ?recipe.Engine,
) Error!?Detection {
    const entries = archive.listEntries(alloc, archive_path) catch |e| switch (e) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.ArchiveUnreadable,
    };
    defer archive.freeEntryList(alloc, entries);

    // Re-shape `[][]u8` (owned mutable slices) into `[]const []const u8`
    // for the matcher — recipe.detectPresetBest takes the const view.
    const paths_const: [][]const u8 = alloc.alloc([]const u8, entries.len) catch return Error.OutOfMemory;
    defer alloc.free(paths_const);
    for (entries, 0..) |e, i| paths_const[i] = e;

    var bundle = recipe.loadMergedPresets(alloc, io, user_dir) catch |e| switch (e) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.PresetLoadFailed,
    };
    defer bundle.deinit();

    const matched = recipe.detectPresetBest(bundle.presets, paths_const, engine) orelse return null;

    // Find which preset index won so we can report `from_user`.
    var from_user: bool = false;
    for (bundle.presets, bundle.from_user) |p, fu| {
        if (std.mem.eql(u8, p.id, matched.preset.id)) {
            from_user = fu;
            break;
        }
    }

    // Bundle dies on return — dupe the id into caller's allocator.
    const id_owned = alloc.dupe(u8, matched.preset.id) catch return Error.OutOfMemory;
    return .{
        .preset_id = id_owned,
        .confidence = matched.confidence,
        .from_user = from_user,
    };
}
