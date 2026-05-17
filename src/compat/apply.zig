// Action implementations + `touched_paths` declarations.
//
// MVP scope: env-only actions (`env_prepend`, `env_set`, `system_hint`).
// File-mutating actions (patchelf, file_overlay, file_replace) are
// intentionally not yet in `domain.Action`; adding them is purely
// additive — declare the variant in domain.zig, list its touched
// paths here, and implement the apply step.
//
// Apply pipeline (driven by service.zig):
//   1. service.zig collects `touched_paths` across the recipe's
//      actions, snapshots them via backup.zig.
//   2. service.zig calls `applyAction` for each action.
//   3. For env-only actions, `applyAction` records an `EnvPair` on
//      the supplied list. The launcher consumes those at launch
//      time. No filesystem side effects.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");
const resources_mod = @import("resources.zig");

/// What an action will mutate. Service.zig uses this to drive the
/// pre-flight backup phase. Empty = pure env action.
pub fn touchedPaths(action: dom.Action, alloc: std.mem.Allocator) errs.Error![]dom.TouchedPath {
    return switch (action) {
        .env_prepend, .env_set, .system_hint => alloc.alloc(dom.TouchedPath, 0) catch errs.Error.OutOfMemory,
    };
}

/// Per-action effects gathered during apply. Service.zig hands the
/// caller a fresh `Outcome` per recipe.
pub const Outcome = struct {
    env_pairs: std.ArrayList(dom.EnvPair),
    /// Allocator that owns the strings inside each EnvPair.
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Outcome {
        return .{ .env_pairs = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Outcome) void {
        for (self.env_pairs.items) |p| {
            self.alloc.free(p.name);
            self.alloc.free(p.value);
            self.alloc.free(p.sep);
        }
        self.env_pairs.deinit(self.alloc);
    }
};

/// Run one action. The action must already have its `touched_paths`
/// backed up (service.zig handles that before calling this).
pub fn applyAction(
    alloc: std.mem.Allocator,
    resolver: *const resources_mod.Resolver,
    action: dom.Action,
    out: *Outcome,
) errs.Error!void {
    switch (action) {
        .env_prepend => |p| {
            const value = try resolver.resolveSub(p.from_resource, p.relpath);
            errdefer alloc.free(value);
            const name = alloc.dupe(u8, p.name) catch return errs.Error.OutOfMemory;
            errdefer alloc.free(name);
            const sep = alloc.dupe(u8, p.sep) catch return errs.Error.OutOfMemory;
            errdefer alloc.free(sep);
            out.env_pairs.append(out.alloc, .{
                .name = name,
                .value = value,
                .prepend = true,
                .sep = sep,
            }) catch return errs.Error.OutOfMemory;
        },
        .env_set => |s| {
            const name = alloc.dupe(u8, s.name) catch return errs.Error.OutOfMemory;
            errdefer alloc.free(name);
            const value = alloc.dupe(u8, s.value) catch return errs.Error.OutOfMemory;
            errdefer alloc.free(value);
            const sep = alloc.dupe(u8, ":") catch return errs.Error.OutOfMemory;
            errdefer alloc.free(sep);
            out.env_pairs.append(out.alloc, .{
                .name = name,
                .value = value,
                .prepend = false,
                .sep = sep,
            }) catch return errs.Error.OutOfMemory;
        },
        .system_hint => {
            // No side effect. The UI renders the hint message from
            // the recipe directly when surfacing the issue.
        },
    }
}

/// Merge env pairs into a host environ map. Called from the launcher
/// after building the spawn env from `std.process.Environ.createMap`.
///
/// `map` is a `std.process.Environ.Map` (interface signature follows the
/// std lib type — see callers).
pub fn applyEnvPairs(
    alloc: std.mem.Allocator,
    map: *std.process.Environ.Map,
    pairs: []const dom.EnvPair,
) errs.Error!void {
    // `Map.put` dupes key + value, so we only need short-lived
    // scratch storage for the merged "prepend" string.
    for (pairs) |p| {
        if (p.prepend) {
            const existing = map.get(p.name) orelse "";
            const merged = if (existing.len == 0)
                alloc.dupe(u8, p.value) catch return errs.Error.OutOfMemory
            else
                std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ p.value, p.sep, existing }) catch return errs.Error.OutOfMemory;
            defer alloc.free(merged);
            map.put(p.name, merged) catch return errs.Error.OutOfMemory;
        } else {
            map.put(p.name, p.value) catch return errs.Error.OutOfMemory;
        }
    }
}

test "applyEnvPairs prepends when existing is empty" {
    const ta = std.testing.allocator;
    var map = std.process.Environ.Map.init(ta);
    defer map.deinit();
    const pair = dom.EnvPair{
        .name = "LD_LIBRARY_PATH",
        .value = "/nix/store/abc/lib",
        .prepend = true,
        .sep = ":",
    };
    try applyEnvPairs(ta, &map, &.{pair});
    try std.testing.expectEqualStrings("/nix/store/abc/lib", map.get("LD_LIBRARY_PATH").?);
}

test "applyEnvPairs prepends with separator when existing is set" {
    const ta = std.testing.allocator;
    var map = std.process.Environ.Map.init(ta);
    defer map.deinit();
    try map.put("LD_LIBRARY_PATH", "/usr/lib");
    const pair = dom.EnvPair{
        .name = "LD_LIBRARY_PATH",
        .value = "/nix/store/abc/lib",
        .prepend = true,
        .sep = ":",
    };
    try applyEnvPairs(ta, &map, &.{pair});
    try std.testing.expectEqualStrings("/nix/store/abc/lib:/usr/lib", map.get("LD_LIBRARY_PATH").?);
}
