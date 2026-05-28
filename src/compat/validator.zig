// Compat recipe structural validation. Catches malformed recipes at
// load time so the service can rely on well-formed input downstream.
//
// Cross-recipe checks (resource id resolves to a materialized
// directory, etc.) happen at the service layer where it has access to
// the resource resolver.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");

pub fn validate(r: *const dom.Recipe) errs.Error!void {
    if (r.id.len == 0 or r.title.len == 0 or r.explain.len == 0) {
        return errs.Error.MissingRequiredField;
    }
    try validateDetect(&r.detect);
    for (r.apply) |a| try validateAction(a);
}

fn validateDetect(d: *const dom.Detect) errs.Error!void {
    switch (d.*) {
        .file_exists => |p| try checkSafePath(p),
        .file_exists_any => |list| {
            if (list.len == 0) return errs.Error.InvalidRecipe;
            for (list) |p| try checkSafePath(p);
        },
        .host_lacks_soname => |s| {
            if (s.len == 0) return errs.Error.InvalidRecipe;
        },
        .host_lacks_sonames_all => |list| {
            if (list.len == 0) return errs.Error.InvalidRecipe;
            for (list) |s| if (s.len == 0) return errs.Error.InvalidRecipe;
        },
        .host_lacks_any_soname => |list| {
            if (list.len == 0) return errs.Error.InvalidRecipe;
            for (list) |s| if (s.len == 0) return errs.Error.InvalidRecipe;
        },
        .engine_fingerprint => {},
        .engine_version_at_most, .engine_version_at_least => |b| {
            if (b.version.len == 0) return errs.Error.InvalidRecipe;
        },
        .all, .any => |list| {
            if (list.len == 0) return errs.Error.InvalidRecipe;
            for (list) |*child| try validateDetect(child);
        },
    }
}

fn validateAction(a: dom.Action) errs.Error!void {
    switch (a) {
        .env_prepend => |p| {
            if (p.name.len == 0 or p.from_resource.len == 0 or p.sep.len == 0) {
                return errs.Error.InvalidRecipe;
            }
            // relpath is optional; if set, check no traversal.
            if (p.relpath.len > 0) try checkSafePath(p.relpath);
        },
        .env_set => |s| {
            if (s.name.len == 0) return errs.Error.InvalidRecipe;
        },
        .system_hint => |h| {
            if (h.message.len == 0) return errs.Error.InvalidRecipe;
        },
        .symlink_create => |s| {
            if (s.link_path.len == 0 or s.target.len == 0) return errs.Error.InvalidRecipe;
            // link_path is always relative to install root — no
            // traversal allowed. target may be relative (most common —
            // sibling file with different case) or absolute.
            try checkSafePath(s.link_path);
            if (s.target[0] != '/') try checkSafePath(s.target);
        },
    }
}

/// Reject `..` segments and absolute paths in recipe-driven file refs.
fn checkSafePath(p: []const u8) errs.Error!void {
    if (p.len == 0) return errs.Error.MissingRequiredField;
    if (p[0] == '/') return errs.Error.UnsafePath;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return errs.Error.UnsafePath;
    }
}

test "validate rejects empty fields" {
    const r = dom.Recipe{
        .id = "",
        .title = "x",
        .explain = "y",
        .detect = .{ .file_exists = "a" },
    };
    try std.testing.expectError(errs.Error.MissingRequiredField, validate(&r));
}

test "validate rejects unsafe path" {
    const r = dom.Recipe{
        .id = "test",
        .title = "x",
        .explain = "y",
        .detect = .{ .file_exists = "../etc/passwd" },
    };
    try std.testing.expectError(errs.Error.UnsafePath, validate(&r));
}

test "validate accepts nested detect" {
    const inner = [_]dom.Detect{
        .{ .file_exists = "a" },
        .{ .host_lacks_soname = "libX11.so.6" },
    };
    const r = dom.Recipe{
        .id = "t",
        .title = "x",
        .explain = "y",
        .detect = .{ .all = &inner },
    };
    try validate(&r);
}
