// Compat recipe repository. Loads:
//
//   1. Bundled recipes — `@embedFile`d from `src/compat/recipes/*.compat.zon`
//      at compile time. These ship with the app and are the authoritative
//      source for the fixes f69 knows about.
//
//   2. User recipes — `.compat.zon` files under
//      `<data_root>/compat-recipes/`. Optional; loaded after bundled ones,
//      can override a bundled recipe by re-using the same `id`.
//
// Validation runs at load time; recipes that don't validate are skipped
// and logged. The repo holds parsed recipes for the life of the process.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");
const zon_loader = @import("zon_loader.zig");
const validator = @import("validator.zig");

const log = std.log.scoped(.compat_repo);

/// Comptime list of bundled recipes. Add a new file by appending a row
/// here. Each row is `(file_basename, embedded_bytes)` — the basename
/// is used only for diagnostic messages.
const BUNDLED = [_]struct { name: []const u8, src: [:0]const u8 }{
    .{
        .name = "linux.renpy.sdl-fhs.compat.zon",
        .src = @embedFile("recipes/linux.renpy.sdl-fhs.compat.zon"),
    },
};

pub const Entry = struct {
    parsed: zon_loader.Parsed,
    /// SHA-256 of the recipe source bytes, lowercase hex. Used by
    /// FixRecord so the UI can detect "recipe upgraded since I
    /// applied it" later.
    source_sha256: []u8,
    /// "bundled" or the absolute path of the user file, for logs.
    origin: []const u8,

    pub fn recipe(self: *const Entry) *const dom.Recipe {
        return &self.parsed.recipe;
    }
};

pub const Repo = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(Entry),
    /// Absolute path to the user-recipe directory. Optional — empty
    /// disables user-recipe loading.
    user_dir: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, user_dir: []const u8) Repo {
        return .{
            .alloc = alloc,
            .io = io,
            .entries = .empty,
            .user_dir = user_dir,
        };
    }

    pub fn deinit(self: *Repo) void {
        self.clearEntries();
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    fn clearEntries(self: *Repo) void {
        for (self.entries.items) |*e| {
            e.parsed.deinit();
            self.alloc.free(e.source_sha256);
            if (!std.mem.eql(u8, e.origin, "bundled")) {
                self.alloc.free(e.origin);
            }
        }
        self.entries.clearRetainingCapacity();
    }

    /// Load bundled + user recipes. Idempotent — calling twice is
    /// the same as calling once (entries cleared first).
    pub fn load(self: *Repo) errs.Error!void {
        self.clearEntries();

        for (BUNDLED) |b| {
            self.loadOne(b.src, "bundled", b.name) catch |e| {
                log.warn("bundled recipe {s} skipped: {s}", .{ b.name, @errorName(e) });
            };
        }

        if (self.user_dir.len > 0) self.loadUserDir() catch |e| {
            log.warn("user compat-recipes dir not loaded: {s}", .{@errorName(e)});
        };

        log.info("loaded {d} compat recipe(s)", .{self.entries.items.len});
    }

    fn loadOne(self: *Repo, bytes_z: [:0]const u8, origin_literal: []const u8, name_for_log: []const u8) errs.Error!void {
        var parsed = try zon_loader.parseFromBytes(self.alloc, bytes_z);
        errdefer parsed.deinit();
        try validator.validate(&parsed.recipe);
        const sha = zon_loader.hashSource(self.alloc, parsed.source_bytes) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(sha);
        const origin_owned = if (std.mem.eql(u8, origin_literal, "bundled"))
            origin_literal
        else
            self.alloc.dupe(u8, origin_literal) catch return errs.Error.OutOfMemory;
        errdefer if (!std.mem.eql(u8, origin_owned, "bundled")) self.alloc.free(origin_owned);

        // Override semantics: if a recipe with the same id already
        // exists, replace it. User recipes win because they're loaded
        // second.
        for (self.entries.items, 0..) |*existing, i| {
            if (std.mem.eql(u8, existing.recipe().id, parsed.recipe.id)) {
                log.info("overriding bundled recipe {s} with {s}", .{ parsed.recipe.id, origin_literal });
                existing.parsed.deinit();
                self.alloc.free(existing.source_sha256);
                if (!std.mem.eql(u8, existing.origin, "bundled")) {
                    self.alloc.free(existing.origin);
                }
                self.entries.items[i] = .{
                    .parsed = parsed,
                    .source_sha256 = sha,
                    .origin = origin_owned,
                };
                return;
            }
        }
        self.entries.append(self.alloc, .{
            .parsed = parsed,
            .source_sha256 = sha,
            .origin = origin_owned,
        }) catch return errs.Error.OutOfMemory;
        _ = name_for_log;
    }

    fn loadUserDir(self: *Repo) errs.Error!void {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.user_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return,
            error.AccessDenied, error.PermissionDenied => return errs.Error.PermissionDenied,
            else => return errs.Error.IoError,
        };
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".compat.zon")) continue;
            const path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.user_dir, entry.name }) catch return errs.Error.OutOfMemory;
            defer self.alloc.free(path);
            var parsed = zon_loader.loadPath(self.io, self.alloc, path) catch |e| {
                log.warn("user recipe {s} skipped: {s}", .{ path, @errorName(e) });
                continue;
            };
            errdefer parsed.deinit();
            validator.validate(&parsed.recipe) catch |e| {
                log.warn("user recipe {s} failed validation: {s}", .{ path, @errorName(e) });
                parsed.deinit();
                continue;
            };
            const sha = zon_loader.hashSource(self.alloc, parsed.source_bytes) catch {
                parsed.deinit();
                continue;
            };
            errdefer self.alloc.free(sha);
            const path_owned = self.alloc.dupe(u8, path) catch {
                self.alloc.free(sha);
                parsed.deinit();
                continue;
            };
            // Reuse override path through loadOne by inlining: simpler
            // here since we already have parsed bytes.
            for (self.entries.items, 0..) |*existing, i| {
                if (std.mem.eql(u8, existing.recipe().id, parsed.recipe.id)) {
                    existing.parsed.deinit();
                    self.alloc.free(existing.source_sha256);
                    if (!std.mem.eql(u8, existing.origin, "bundled")) {
                        self.alloc.free(existing.origin);
                    }
                    self.entries.items[i] = .{
                        .parsed = parsed,
                        .source_sha256 = sha,
                        .origin = path_owned,
                    };
                    break;
                }
            } else {
                self.entries.append(self.alloc, .{
                    .parsed = parsed,
                    .source_sha256 = sha,
                    .origin = path_owned,
                }) catch {
                    parsed.deinit();
                    self.alloc.free(sha);
                    self.alloc.free(path_owned);
                    return errs.Error.OutOfMemory;
                };
            }
        }
    }

    /// Read-only iterator over loaded recipes.
    pub fn all(self: *const Repo) []const Entry {
        return self.entries.items;
    }

    /// Lookup by recipe id. O(n) — fine for our recipe counts.
    pub fn byId(self: *const Repo, id: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.recipe().id, id)) return e;
        }
        return null;
    }
};
