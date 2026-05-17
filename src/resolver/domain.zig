// Resolver outputs.

const std = @import("std");

pub const PlanStep = struct {
    mod_id: []const u8,
    mod_version: []const u8,
    /// Position in the load order (lower = applied first).
    load_index: u32,
};

pub const Plan = struct {
    /// Ordered install steps (deps first, conflicts already weeded out).
    steps: []const PlanStep,
};

pub const ConflictReason = enum {
    declared_conflict, // mod recipe says `conflicts "x"`
    file_collision,    // two enabled mods write the same path with different content
    version_mismatch,  // for_game version doesn't satisfy install
};

pub const Conflict = struct {
    a: []const u8,
    b: []const u8,
    reason: ConflictReason,
    detail: ?[]const u8 = null,
};
