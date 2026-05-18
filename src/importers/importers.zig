// Public face of the importer context.
//
// Two sources today — F95Checker (SQLite at ~/.config/f95checker/) and
// xLibrary (Electron app, JSON at ~/.config/xlibrary/). Both shapes
// land in `ImportedGame` so the migration + library-upsert flow
// downstream only sees one type.
//
// Each reader returns a `Bundle` that owns its string memory via an
// arena, so the caller frees with one `bundle.deinit()` call.

const std = @import("std");

pub const Error = error{
    OpenFailed,
    ParseFailed,
    OutOfMemory,
};

pub const ImportedGame = struct {
    /// F95Zone thread id — the primary key f69's library uses to dedupe.
    thread_id: u64,
    name: []const u8,
    developer: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    changelog: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    cover_url: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    /// 0..5 scale on the source DB's user rating axis. Both sources use
    /// the F95Zone star scale so this maps 1:1 onto `library.Game.user_rating`.
    user_rating: ?f32 = null,
    /// F95Zone-scraped average score (0..5). Maps to `library.Game.rating`.
    rating: ?f32 = null,
    vote_count: ?u32 = null,
    last_played_at: ?i64 = null,
    /// Relative path from the source's games-base-dir down to the
    /// launcher binary, exactly as the source recorded it
    /// (e.g. `Babysitter-0.2.2b.-linux/Babysitter.sh`). The migrator
    /// uses the *first* path segment as the install directory to copy.
    /// Null = source has no install for this game (library-only entry).
    install_executable_rel: ?[]const u8 = null,
    /// Optional source-claimed completion state ("Completed" /
    /// "Not Started" / etc.). Down-converted to f69's enum at upsert
    /// time; null = unknown.
    completion_status: ?[]const u8 = null,

    /// First path segment of `install_executable_rel`, which is the
    /// directory the migrator should copy. Null when no install or
    /// when the executable is at the base dir's top level.
    pub fn installDirRel(self: *const ImportedGame) ?[]const u8 {
        const p = self.install_executable_rel orelse return null;
        const slash = std.mem.indexOfScalar(u8, p, '/') orelse return null;
        return p[0..slash];
    }
};

/// Owns every string referenced by `games`. Caller frees with `deinit`.
pub const Bundle = struct {
    arena: *std.heap.ArenaAllocator,
    games: []ImportedGame,

    pub fn deinit(self: *Bundle) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

pub const f95checker = @import("f95checker.zig");
pub const xlibrary = @import("xlibrary.zig");
pub const folder_scan = @import("folder_scan.zig");
pub const migrate = @import("migrate.zig");

test {
    _ = f95checker;
    _ = xlibrary;
    _ = folder_scan;
    _ = migrate;
}
