// Compat recipe repository. Loads:
//
//   1. Bundled recipes — `@import("recipes/foo.compat.zon")`d at
//      compile time. The parsed `dom.Recipe` values live in the
//      binary's read-only segment; their sha-256 is precomputed at
//      comptime. Zero runtime parse, zero runtime allocation.
//
//   2. User recipes — `.compat.zon` files under
//      `<data_root>/compat-recipes/`. Optional; loaded after bundled
//      ones, can override a bundled recipe by re-using the same `id`.
//      Still go through `zon_loader.loadPath` → arena-owned `Parsed`.
//
// Validation runs at load time; recipes that don't validate are skipped
// and logged. The repo holds parsed recipes for the life of the process.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");
const zon_loader = @import("zon_loader.zig");
const validator = @import("validator.zig");

const log = std.log.scoped(.compat_repo);

/// Comptime list of bundled recipes. Each row binds a basename (for
/// log messages), the comptime-parsed recipe value, and its source
/// bytes (still needed for the sha hash). Adding a new built-in =
/// drop a `.compat.zon` under `recipes/` and append a row; a
/// malformed file breaks the build rather than failing at startup.
const Bundled = struct {
    name: []const u8,
    recipe: dom.Recipe,
    src: []const u8,
};

const BUNDLED: []const Bundled = &.{
    .{
        .name = "linux.renpy7.sdl-fhs.compat.zon",
        .recipe = @import("recipes/linux.renpy7.sdl-fhs.compat.zon"),
        .src = @embedFile("recipes/linux.renpy7.sdl-fhs.compat.zon"),
    },
    .{
        .name = "linux.renpy8.sdl-fhs.compat.zon",
        .recipe = @import("recipes/linux.renpy8.sdl-fhs.compat.zon"),
        .src = @embedFile("recipes/linux.renpy8.sdl-fhs.compat.zon"),
    },
    .{
        .name = "linux.rpgm-mv.fhs.compat.zon",
        .recipe = @import("recipes/linux.rpgm-mv.fhs.compat.zon"),
        .src = @embedFile("recipes/linux.rpgm-mv.fhs.compat.zon"),
    },
    .{
        .name = "linux.unity.fhs.compat.zon",
        .recipe = @import("recipes/linux.unity.fhs.compat.zon"),
        .src = @embedFile("recipes/linux.unity.fhs.compat.zon"),
    },
};

/// Sha-256 hex of one bundled recipe's source bytes, computed at
/// comptime. Hits Zig's default eval-branch quota fast — bump it.
fn comptimeSha256Hex(comptime bytes: []const u8) [64]u8 {
    @setEvalBranchQuota(200_000);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const tbl = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex[2 * i] = tbl[b >> 4];
        hex[2 * i + 1] = tbl[b & 0xf];
    }
    return hex;
}

/// Parallel-indexed sha table — `BUNDLED_SHA[i]` is the sha of
/// `BUNDLED[i].src`. Each entry is a static `[64]u8` in rodata.
const BUNDLED_SHA: [BUNDLED.len][64]u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [BUNDLED.len][64]u8 = undefined;
    for (BUNDLED, 0..) |b, i| out[i] = comptimeSha256Hex(b.src);
    break :blk out;
};

/// Loaded recipe entry. `is_bundled` gates the deinit path: bundled
/// entries point at rodata (no arena, no heap sha), user entries own
/// both an arena and a heap-allocated sha/origin.
pub const Entry = struct {
    /// Stable pointer to the recipe — either into rodata (bundled)
    /// or into the `arena` below (user).
    recipe_ptr: *const dom.Recipe,
    /// `null` for bundled entries (their data lives in rodata).
    /// `Parsed.arena` for user entries — owns the recipe value, all
    /// its nested strings, and the source bytes.
    arena: ?std.heap.ArenaAllocator,
    /// SHA-256 of the recipe source bytes, lowercase hex. Bundled =
    /// pointer into static `BUNDLED_SHA[i]`; user = heap slice owned
    /// by the repo allocator.
    source_sha256: []const u8,
    /// "bundled" or the absolute path of the user file, for logs.
    /// String literal for bundled; heap-owned dup for user.
    origin: []const u8,
    is_bundled: bool,

    pub fn recipe(self: *const Entry) *const dom.Recipe {
        return self.recipe_ptr;
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
            if (e.arena) |*a| a.deinit();
            if (!e.is_bundled) {
                self.alloc.free(e.source_sha256);
                self.alloc.free(e.origin);
            }
        }
        self.entries.clearRetainingCapacity();
    }

    /// Load bundled + user recipes. Idempotent — calling twice is
    /// the same as calling once (entries cleared first).
    pub fn load(self: *Repo) errs.Error!void {
        self.clearEntries();

        // Bundled recipes — comptime-parsed via `@import`, validation
        // is the only runtime step. No allocations for the recipe
        // value, sha, or origin string (all rodata).
        for (BUNDLED, 0..) |*b, i| {
            validator.validate(&b.recipe) catch |e| {
                log.warn("bundled recipe {s} skipped: {s}", .{ b.name, @errorName(e) });
                continue;
            };
            self.entries.append(self.alloc, .{
                .recipe_ptr = &b.recipe,
                .arena = null,
                .source_sha256 = &BUNDLED_SHA[i],
                .origin = "bundled",
                .is_bundled = true,
            }) catch |e| {
                log.warn("bundled recipe {s} append failed: {s}", .{ b.name, @errorName(e) });
            };
        }

        if (self.user_dir.len > 0) self.loadUserDir() catch |e| {
            log.warn("user compat-recipes dir not loaded: {s}", .{@errorName(e)});
        };

        log.info("loaded {d} compat recipe(s)", .{self.entries.items.len});
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

            // Move the parsed Recipe into the arena so we have a
            // stable address for `recipe_ptr`. (Parsed.recipe is a
            // value field — its address shifts when Parsed is moved
            // into the Entry, so we can't reuse it directly.)
            const recipe_slot = parsed.arena.allocator().create(dom.Recipe) catch {
                parsed.deinit();
                self.alloc.free(sha);
                self.alloc.free(path_owned);
                continue;
            };
            recipe_slot.* = parsed.recipe;

            const new_entry: Entry = .{
                .recipe_ptr = recipe_slot,
                .arena = parsed.arena,
                .source_sha256 = sha,
                .origin = path_owned,
                .is_bundled = false,
            };

            // Override semantics: a user recipe with the same id
            // REPLACES an existing entry. `clearEntries`-style logic
            // applies per-entry: bundled entries skip the sha/origin
            // free, user entries reclaim them.
            for (self.entries.items, 0..) |*existing, i| {
                if (std.mem.eql(u8, existing.recipe().id, recipe_slot.id)) {
                    log.info("overriding compat recipe {s} with {s}", .{ recipe_slot.id, path_owned });
                    if (existing.arena) |*a| a.deinit();
                    if (!existing.is_bundled) {
                        self.alloc.free(existing.source_sha256);
                        self.alloc.free(existing.origin);
                    }
                    self.entries.items[i] = new_entry;
                    break;
                }
            } else {
                self.entries.append(self.alloc, new_entry) catch {
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
