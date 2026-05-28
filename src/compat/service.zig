// Compat orchestrator. The single entry point UI + launcher talk to.
//
//   scan(install_root, applied)        → []Issue
//   apply(install_id, install_root, e) → FixRecord
//   undo(install_id, install_root, fr) → void
//   composeEnv(applied) on Outcome
//
// The service owns the apply atomicity: pre-flight backup → run
// actions → commit FixRecord. Any failure mid-apply restores from
// the snapshots that were already taken and returns an error. The
// caller never sees a half-applied state.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");
const apply_mod = @import("apply.zig");
const backup_mod = @import("backup.zig");
const detect_mod = @import("detect.zig");
const host_mod = @import("host.zig");
const repo_mod = @import("repository.zig");
const resources_mod = @import("resources.zig");

const log = std.log.scoped(.compat_svc);

pub const Service = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: *repo_mod.Repo,
    host: *const host_mod.Host,
    resources: *const resources_mod.Resolver,
    backups: *backup_mod.Store,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        repo: *repo_mod.Repo,
        host: *const host_mod.Host,
        resources: *const resources_mod.Resolver,
        backups: *backup_mod.Store,
    ) Service {
        return .{
            .alloc = alloc,
            .io = io,
            .repo = repo,
            .host = host,
            .resources = resources,
            .backups = backups,
        };
    }

    /// Walk every recipe in the repo against `install_root`. Returned
    /// slice is `alloc`-owned; caller frees via `freeIssues`. The
    /// `already_applied` set tells the service which recipes already
    /// have a FixRecord on this install so they're surfaced as
    /// `.fixed` rather than `.unfixed`.
    pub fn scan(
        self: *const Service,
        install_root: []const u8,
        already_applied: []const []const u8,
    ) errs.Error![]dom.Issue {
        var out: std.ArrayList(dom.Issue) = .empty;
        errdefer {
            for (out.items) |is| self.alloc.free(is.title);
            out.deinit(self.alloc);
        }

        const ctx = detect_mod.Ctx{
            .io = self.io,
            .install_root = install_root,
            .host = self.host,
        };

        for (self.repo.all()) |*entry| {
            const r = entry.recipe();
            if (r.platforms.len > 0) {
                const our_os = currentOs();
                var matched = false;
                for (r.platforms) |os| if (os == our_os) {
                    matched = true;
                    break;
                };
                if (!matched) {
                    std.log.scoped(.compat).info("scan: {s} skipped — platform mismatch", .{r.id});
                    continue;
                }
            }
            if (!detect_mod.matches(&ctx, &r.detect)) {
                std.log.scoped(.compat).info("scan: {s} skipped — detect.matches false", .{r.id});
                continue;
            }
            std.log.scoped(.compat).info("scan: {s} matched", .{r.id});

            const status: dom.IssueStatus = blk: {
                for (already_applied) |id| if (std.mem.eql(u8, id, r.id)) break :blk .fixed;
                break :blk .unfixed;
            };

            const title_owned = self.alloc.dupe(u8, r.title) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(title_owned);
            const explain_owned = self.alloc.dupe(u8, r.explain) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(explain_owned);
            const id_owned = self.alloc.dupe(u8, r.id) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(id_owned);

            out.append(self.alloc, .{
                .recipe_id = id_owned,
                .title = title_owned,
                .explain = explain_owned,
                .severity = r.severity,
                .status = status,
                .estimated_backup_bytes = 0, // env-only recipes, no backup cost
            }) catch return errs.Error.OutOfMemory;
        }

        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    /// Free issues + their strings.
    pub fn freeIssues(self: *const Service, issues: []dom.Issue) void {
        for (issues) |is| {
            self.alloc.free(is.recipe_id);
            self.alloc.free(is.title);
            self.alloc.free(is.explain);
        }
        self.alloc.free(issues);
    }

    /// Apply a recipe to an install. Atomic: any error rolls back
    /// snapshots taken during pre-flight and returns. On success,
    /// returns a FixRecord — the caller persists it (library DB).
    pub fn apply(
        self: *Service,
        install_id: []const u8,
        install_root: []const u8,
        entry: *const repo_mod.Entry,
    ) errs.Error!dom.FixRecord {
        const r = entry.recipe();

        // 1. Collect every touched path across the recipe's actions.
        var all_touched: std.ArrayList(dom.TouchedPath) = .empty;
        defer {
            // Touched paths' slices are owned by the recipe arena;
            // we only own the outer list.
            all_touched.deinit(self.alloc);
        }
        for (r.apply) |action| {
            const tp = try apply_mod.touchedPaths(action, self.alloc);
            defer self.alloc.free(tp);
            for (tp) |p| all_touched.append(self.alloc, p) catch return errs.Error.OutOfMemory;
        }

        // 2. Pre-flight backup. On any failure we restore everything
        // snapshotted so far and abort.
        var backups: std.ArrayList(dom.BackupRecord) = .empty;
        errdefer {
            for (backups.items) |b| self.backups.freeRecord(b);
            backups.deinit(self.alloc);
        }
        for (all_touched.items) |tp| {
            const rec = self.backups.snapshot(install_id, install_root, tp) catch |e| {
                // Rollback any earlier snapshots — but a failed
                // snapshot hasn't mutated the install tree, so
                // there's nothing to restore yet, just free.
                return e;
            };
            backups.append(self.alloc, rec) catch return errs.Error.OutOfMemory;
        }

        // 3. Run actions. If any action errors, restore from
        // snapshots in reverse order and surface the original error.
        var outcome = apply_mod.Outcome.init(self.alloc);
        errdefer outcome.deinit();
        for (r.apply, 0..) |action, idx| {
            apply_mod.applyAction(self.alloc, self.resources, self.io, install_root, action, &outcome) catch |e| {
                log.warn("apply step {d} of recipe {s} failed: {s}", .{ idx, r.id, @errorName(e) });
                // Restore snapshots (file-mutating future actions
                // need this; env-only actions had no effect on disk).
                var i = backups.items.len;
                while (i > 0) {
                    i -= 1;
                    self.backups.restore(install_id, install_root, backups.items[i]) catch |re| {
                        log.err("rollback failed for {s}: {s}", .{ backups.items[i].relpath, @errorName(re) });
                    };
                }
                return e;
            };
        }

        // 4. Commit. The Outcome's env pairs are stored separately —
        // the launcher recomposes them on every launch by re-running
        // applyAction against the persisted recipe + resolver. The
        // FixRecord just records WHAT was applied, not the
        // intermediate env state. (Re-resolution lets resource paths
        // adapt to a moved data_root.)
        outcome.deinit();

        const id_owned = self.alloc.dupe(u8, r.id) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(id_owned);
        const sha_owned = self.alloc.dupe(u8, entry.source_sha256) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(sha_owned);

        const backups_slice = backups.toOwnedSlice(self.alloc) catch return errs.Error.OutOfMemory;

        return .{
            .recipe_id = id_owned,
            .recipe_sha256 = sha_owned,
            // Placeholder timestamp — the library DB layer stamps the
            // row at insert time with its own clock. See library
            // `unixSecondsApprox` comment for the std.time pending
            // upgrade.
            .applied_at = 0,
            .backups = backups_slice,
        };
    }

    /// Reverse an applied fix. Restores every backup; the caller
    /// then deletes the FixRecord from the library DB.
    pub fn undo(
        self: *Service,
        install_id: []const u8,
        install_root: []const u8,
        rec: dom.FixRecord,
    ) errs.Error!void {
        // Restore in reverse order — file_overlay-style additions
        // need to be removed before underlying files.
        var i = rec.backups.len;
        while (i > 0) {
            i -= 1;
            self.backups.restore(install_id, install_root, rec.backups[i]) catch |e| {
                log.warn("undo: restore failed for {s}: {s}", .{ rec.backups[i].relpath, @errorName(e) });
                return e;
            };
        }
    }

    /// Build env pairs for a launch by replaying actions of all
    /// applied recipes against the live resolver. Caller frees via
    /// `Outcome.deinit`.
    pub fn composeEnv(
        self: *const Service,
        applied_recipe_ids: []const []const u8,
    ) errs.Error!apply_mod.Outcome {
        var outcome = apply_mod.Outcome.init(self.alloc);
        errdefer outcome.deinit();
        for (applied_recipe_ids) |id| {
            const entry = self.repo.byId(id) orelse {
                log.warn("composeEnv: applied recipe {s} not found in repo (possibly removed)", .{id});
                continue;
            };
            for (entry.recipe().apply) |action| {
                // composeEnv only collects env pairs; pass null for
                // install_root so file-mutating actions (symlink_create)
                // no-op rather than re-running on every launch.
                try apply_mod.applyAction(self.alloc, self.resources, self.io, null, action, &outcome);
            }
        }
        return outcome;
    }
};

fn currentOs() dom.Os {
    return switch (@import("builtin").target.os.tag) {
        .linux => .linux,
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}

// -----------------------------------------------------------------
//  serde — convert FixRecord ↔ JSON for persistence in the library
//  DB. Library stores backups_json as TEXT; the compat service
//  serializes here.
// -----------------------------------------------------------------

pub fn serializeBackups(alloc: std.mem.Allocator, backups: []const dom.BackupRecord) errs.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    // Hand-rolled JSON keeps allocator behaviour predictable and
    // doesn't pull in std.json.Stringify quirks across Zig versions.
    buf.append(alloc, '[') catch return errs.Error.OutOfMemory;
    for (backups, 0..) |b, i| {
        if (i > 0) buf.append(alloc, ',') catch return errs.Error.OutOfMemory;
        try jsonAppendObject(alloc, &buf, b);
    }
    buf.append(alloc, ']') catch return errs.Error.OutOfMemory;
    return buf.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

fn jsonAppendObject(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), b: dom.BackupRecord) errs.Error!void {
    buf.append(alloc, '{') catch return errs.Error.OutOfMemory;
    try jsonKvString(alloc, buf, "sha256", b.sha256);
    buf.append(alloc, ',') catch return errs.Error.OutOfMemory;
    try jsonKvString(alloc, buf, "relpath", b.relpath);
    buf.append(alloc, ',') catch return errs.Error.OutOfMemory;
    try jsonKvNumber(alloc, buf, "size", @intCast(b.size));
    buf.append(alloc, ',') catch return errs.Error.OutOfMemory;
    try jsonKvNumber(alloc, buf, "mode", @intCast(b.mode));
    buf.append(alloc, ',') catch return errs.Error.OutOfMemory;
    const bool_str: []const u8 = if (b.was_symlink) "true" else "false";
    try jsonAppendRaw(alloc, buf, "\"was_symlink\":");
    try jsonAppendRaw(alloc, buf, bool_str);
    if (b.symlink_target) |t| {
        buf.append(alloc, ',') catch return errs.Error.OutOfMemory;
        try jsonKvString(alloc, buf, "symlink_target", t);
    }
    if (b.was_absent) {
        buf.append(alloc, ',') catch return errs.Error.OutOfMemory;
        try jsonAppendRaw(alloc, buf, "\"was_absent\":true");
    }
    buf.append(alloc, '}') catch return errs.Error.OutOfMemory;
}

fn jsonKvString(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) errs.Error!void {
    buf.append(alloc, '"') catch return errs.Error.OutOfMemory;
    buf.appendSlice(alloc, key) catch return errs.Error.OutOfMemory;
    buf.appendSlice(alloc, "\":\"") catch return errs.Error.OutOfMemory;
    for (value) |c| {
        switch (c) {
            '"' => buf.appendSlice(alloc, "\\\"") catch return errs.Error.OutOfMemory,
            '\\' => buf.appendSlice(alloc, "\\\\") catch return errs.Error.OutOfMemory,
            '\n' => buf.appendSlice(alloc, "\\n") catch return errs.Error.OutOfMemory,
            '\r' => buf.appendSlice(alloc, "\\r") catch return errs.Error.OutOfMemory,
            '\t' => buf.appendSlice(alloc, "\\t") catch return errs.Error.OutOfMemory,
            else => if (c < 0x20) {
                var tmp: [8]u8 = undefined;
                const escaped = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch return errs.Error.OutOfMemory;
                buf.appendSlice(alloc, escaped) catch return errs.Error.OutOfMemory;
            } else {
                buf.append(alloc, c) catch return errs.Error.OutOfMemory;
            },
        }
    }
    buf.append(alloc, '"') catch return errs.Error.OutOfMemory;
}

fn jsonKvNumber(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: u64) errs.Error!void {
    buf.append(alloc, '"') catch return errs.Error.OutOfMemory;
    buf.appendSlice(alloc, key) catch return errs.Error.OutOfMemory;
    buf.appendSlice(alloc, "\":") catch return errs.Error.OutOfMemory;
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return errs.Error.OutOfMemory;
    buf.appendSlice(alloc, s) catch return errs.Error.OutOfMemory;
}

fn jsonAppendRaw(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) errs.Error!void {
    buf.appendSlice(alloc, s) catch return errs.Error.OutOfMemory;
}

/// Parse the JSON form produced by `serializeBackups`. Returned
/// slices are owned by `alloc`; caller frees each record via
/// `BackupStore.freeRecord` (or equivalent allocator.free chain).
pub fn deserializeBackups(alloc: std.mem.Allocator, json_bytes: []const u8) errs.Error![]dom.BackupRecord {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch return errs.Error.IoError;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return errs.Error.IoError,
    };
    var out: std.ArrayList(dom.BackupRecord) = .empty;
    errdefer out.deinit(alloc);
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return errs.Error.IoError,
        };
        const sha = obj.get("sha256") orelse return errs.Error.IoError;
        const rel = obj.get("relpath") orelse return errs.Error.IoError;
        const size = obj.get("size") orelse return errs.Error.IoError;
        const mode = obj.get("mode") orelse return errs.Error.IoError;
        const was_sym = obj.get("was_symlink") orelse std.json.Value{ .bool = false };
        const sha_str = switch (sha) {
            .string => |s| s,
            else => return errs.Error.IoError,
        };
        const rel_str = switch (rel) {
            .string => |s| s,
            else => return errs.Error.IoError,
        };
        const size_int: u64 = switch (size) {
            .integer => |x| @intCast(x),
            else => return errs.Error.IoError,
        };
        const mode_int: u32 = switch (mode) {
            .integer => |x| @intCast(x),
            else => return errs.Error.IoError,
        };
        const was_sym_bool: bool = switch (was_sym) {
            .bool => |b| b,
            else => false,
        };
        var sym_target_owned: ?[]const u8 = null;
        if (obj.get("symlink_target")) |sv| switch (sv) {
            .string => |s| sym_target_owned = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory,
            else => {},
        };
        const sha_owned = alloc.dupe(u8, sha_str) catch return errs.Error.OutOfMemory;
        errdefer alloc.free(sha_owned);
        const rel_owned = alloc.dupe(u8, rel_str) catch return errs.Error.OutOfMemory;
        errdefer alloc.free(rel_owned);
        const was_absent_bool: bool = if (obj.get("was_absent")) |v| switch (v) {
            .bool => |b| b,
            else => false,
        } else false;
        out.append(alloc, .{
            .sha256 = sha_owned,
            .relpath = rel_owned,
            .size = size_int,
            .mode = mode_int,
            .was_symlink = was_sym_bool,
            .symlink_target = sym_target_owned,
            .was_absent = was_absent_bool,
        }) catch return errs.Error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

// -----------------------------------------------------------------
//  integration tests — scan + apply + composeEnv against a synthetic
//  Ren'Py install fixture. Host probe is hand-constructed so the test
//  is deterministic regardless of the host distro.
// -----------------------------------------------------------------

const test_recipe_id = "linux.renpy7.sdl-fhs";
const test_env = @import("util_test_env");

test "service scan + apply + composeEnv against synthetic Ren'Py install" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "compat-svc-scan");
    defer env.deinit();
    const io = env.io;

    // Lay out: <tmp>/install (renpy game), <tmp>/resources/renpy7-fhs-libs/lib,
    // <tmp>/backups.
    try env.touchFile("install/renpy/bootstrap.py");
    try env.touchFile("install/lib/linux-x86_64/libSDL2-2.0.so.0");
    // Pin the synthetic install to Ren'Py 7 so `engine_version_at_most
    // 7.99` in the renpy7 recipe matches (and the renpy8 recipe stays
    // dormant).
    try env.writeFile("install/renpy/vc_version.py", "version = u'7.5.3.23060707'\n");

    // touch a marker file so the resolver's access() succeeds
    try env.touchFile("resources/renpy7-fhs-libs/lib/marker.txt");

    const install_root = try env.path("install");
    defer ta.free(install_root);
    const resources_root = try env.path("resources");
    defer ta.free(resources_root);
    const backups_root = try env.path("backups");
    defer ta.free(backups_root);

    // Build host with empty soname_search → host_lacks_soname is true
    // for every soname. Deterministic regardless of distro.
    const empty_search = try ta.dupe(u8, "");
    var host_obj = @import("host.zig").Host{
        .alloc = ta,
        .soname_search = empty_search,
        .package_manager = .nix_ld,
        .is_nixos = true,
    };
    defer host_obj.deinit();

    var repo = repo_mod.Repo.init(ta, io, "");
    defer repo.deinit();
    try repo.load();
    try std.testing.expect(repo.byId(test_recipe_id) != null);

    var resolver = resources_mod.Resolver.init(ta, io, resources_root);
    var backups = backup_mod.Store.init(ta, io, backups_root);

    var svc = Service.init(ta, io, &repo, &host_obj, &resolver, &backups);

    // Scan — should produce one Issue (unfixed).
    const issues = try svc.scan(install_root, &.{});
    defer svc.freeIssues(issues);
    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings(test_recipe_id, issues[0].recipe_id);
    try std.testing.expectEqual(dom.IssueStatus.unfixed, issues[0].status);

    // Apply — env-only, no backups.
    const entry = repo.byId(test_recipe_id).?;
    const fix = try svc.apply("test-install", install_root, entry);
    defer {
        ta.free(fix.recipe_id);
        ta.free(fix.recipe_sha256);
        for (fix.backups) |b| backups.freeRecord(b);
        if (fix.backups.len > 0) ta.free(fix.backups);
    }
    try std.testing.expectEqualStrings(test_recipe_id, fix.recipe_id);
    try std.testing.expectEqual(@as(usize, 0), fix.backups.len);

    // Re-scan — issue is now .fixed.
    const id_slice: []const []const u8 = &.{test_recipe_id};
    const issues2 = try svc.scan(install_root, id_slice);
    defer svc.freeIssues(issues2);
    try std.testing.expectEqual(@as(usize, 1), issues2.len);
    try std.testing.expectEqual(dom.IssueStatus.fixed, issues2[0].status);

    // Compose env — recipe ships TWO env actions: an env_prepend for
    // LD_LIBRARY_PATH (the FHS bundle) and an env_set for
    // SDL_VIDEODRIVER=x11.
    var outcome = try svc.composeEnv(id_slice);
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 2), outcome.env_pairs.items.len);
    // First pair is the env_prepend (recipe action order is preserved).
    try std.testing.expectEqualStrings("LD_LIBRARY_PATH", outcome.env_pairs.items[0].name);
    try std.testing.expect(outcome.env_pairs.items[0].prepend);
    try std.testing.expect(std.mem.indexOf(u8, outcome.env_pairs.items[0].value, "renpy7-fhs-libs/lib") != null);
    // Second pair is the env_set.
    try std.testing.expectEqualStrings("SDL_VIDEODRIVER", outcome.env_pairs.items[1].name);
    try std.testing.expect(!outcome.env_pairs.items[1].prepend);
    try std.testing.expectEqualStrings("x11", outcome.env_pairs.items[1].value);
}

test "serialize then deserialize backups round-trips" {
    const ta = std.testing.allocator;
    const records = [_]dom.BackupRecord{
        .{
            .sha256 = "abcd",
            .relpath = "lib/foo.so",
            .size = 1234,
            .mode = 0o644,
            .was_symlink = false,
        },
        .{
            .sha256 = "ffff",
            .relpath = "lib/link",
            .size = 0,
            .mode = 0o777,
            .was_symlink = true,
            .symlink_target = "/nix/store/abc",
        },
    };
    const json = try serializeBackups(ta, &records);
    defer ta.free(json);
    const back = try deserializeBackups(ta, json);
    defer {
        for (back) |b| {
            ta.free(b.sha256);
            ta.free(b.relpath);
            if (b.symlink_target) |t| ta.free(t);
        }
        ta.free(back);
    }
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("lib/foo.so", back[0].relpath);
    try std.testing.expect(back[1].was_symlink);
    try std.testing.expectEqualStrings("/nix/store/abc", back[1].symlink_target.?);
}
