//! Download/seed job model + the pure mapping from aria2's reported status
//! to our phase. Keeping the derivation pure means the lifecycle — the part
//! that's easy to get wrong (a completed torrent that's still seeding vs.
//! truly done) — is unit-tested without a running aria2.
//!
//! Reconcile (from a poll snapshot or a push event) calls `derivePhase`;
//! the manager owns the actual job table + IO.

const std = @import("std");

pub const Kind = enum { file, torrent };

/// Our lifecycle phase. `seeding` only applies to torrents.
pub const Phase = enum {
    queued,
    downloading,
    seeding,
    completed,
    paused,
    failed,
    removed,

    /// No further automatic transitions expected (UI may still allow remove).
    pub fn isTerminal(self: Phase) bool {
        return switch (self) {
            .completed, .failed, .removed => true,
            .queued, .downloading, .seeding, .paused => false,
        };
    }

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .queued => "Queued",
            .downloading => "Downloading",
            .seeding => "Seeding",
            .completed => "Completed",
            .paused => "Paused",
            .failed => "Failed",
            .removed => "Removed",
        };
    }
};

/// aria2's `status` field. ("error" is a Zig keyword → tag is `err`.)
pub const AriaStatus = enum {
    active,
    waiting,
    paused,
    complete,
    err,
    removed,

    pub fn fromStr(s: []const u8) ?AriaStatus {
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "waiting")) return .waiting;
        if (std.mem.eql(u8, s, "paused")) return .paused;
        if (std.mem.eql(u8, s, "complete")) return .complete;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "removed")) return .removed;
        return null;
    }
};

/// Map aria2's status onto our phase. The one subtle case: an `active`
/// torrent whose download is finished is *seeding* (aria2 keeps it active
/// and flags `seeder=true`); an active file (or a leeching torrent) is
/// `downloading`. With `--bt-detach-seed-only` seeders don't consume a
/// download slot, so this is purely a display/control distinction.
pub fn derivePhase(status: AriaStatus, kind: Kind, seeder: bool) Phase {
    return switch (status) {
        .waiting => .queued,
        .paused => .paused,
        .err => .failed,
        .removed => .removed,
        .complete => .completed,
        .active => if (kind == .torrent and seeder) .seeding else .downloading,
    };
}

/// Download progress in [0,1]. Guards total==0 (returns 0).
pub fn progress(done: u64, total: u64) f32 {
    if (total == 0) return 0;
    const d: f32 = @floatFromInt(@min(done, total));
    const t: f32 = @floatFromInt(total);
    return d / t;
}

/// Seed ratio = uploaded / downloaded. Guards downloaded==0 (returns 0).
pub fn seedRatio(uploaded: u64, downloaded: u64) f32 {
    if (downloaded == 0) return 0;
    return @as(f32, @floatFromInt(uploaded)) / @as(f32, @floatFromInt(downloaded));
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "AriaStatus.fromStr incl. the error keyword case" {
    try testing.expectEqual(AriaStatus.active, AriaStatus.fromStr("active").?);
    try testing.expectEqual(AriaStatus.err, AriaStatus.fromStr("error").?);
    try testing.expectEqual(AriaStatus.complete, AriaStatus.fromStr("complete").?);
    try testing.expect(AriaStatus.fromStr("bogus") == null);
}

test "derivePhase: active torrent seeder=true is seeding, else downloading" {
    try testing.expectEqual(Phase.seeding, derivePhase(.active, .torrent, true));
    try testing.expectEqual(Phase.downloading, derivePhase(.active, .torrent, false));
    try testing.expectEqual(Phase.downloading, derivePhase(.active, .file, true)); // files never seed
    try testing.expectEqual(Phase.queued, derivePhase(.waiting, .file, false));
    try testing.expectEqual(Phase.paused, derivePhase(.paused, .torrent, true));
    try testing.expectEqual(Phase.failed, derivePhase(.err, .file, false));
    try testing.expectEqual(Phase.completed, derivePhase(.complete, .torrent, false));
    try testing.expectEqual(Phase.removed, derivePhase(.removed, .file, false));
}

test "isTerminal" {
    try testing.expect(Phase.completed.isTerminal());
    try testing.expect(Phase.failed.isTerminal());
    try testing.expect(!Phase.seeding.isTerminal());
    try testing.expect(!Phase.downloading.isTerminal());
}

test "progress and seedRatio guard zero denominators" {
    try testing.expectEqual(@as(f32, 0), progress(10, 0));
    try testing.expectEqual(@as(f32, 0.5), progress(50, 100));
    try testing.expectEqual(@as(f32, 1.0), progress(150, 100)); // clamped
    try testing.expectEqual(@as(f32, 0), seedRatio(10, 0));
    try testing.expectEqual(@as(f32, 2.0), seedRatio(200, 100));
}
