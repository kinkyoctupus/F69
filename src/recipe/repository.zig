// Recipe storage. For v1: local-only.
//
//   1. `~/.config/f69/recipes/<id>.game.zon`     (user authored game recipes)
//   2. `~/.config/f69/recipes/<id>.mod.zon`      (user authored mod recipes)
//   3. Auto-derived from F95 scrape (ephemeral, in-memory only unless saved)
//
// Future (v2 / phase 12): hosted community repo synced into a third layer
// at `~/.cache/f69/recipes/`. See docs/PLAN.md.

const std = @import("std");
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const zon = @import("zon_loader.zig");

pub const Repo = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    local_dir: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, local_dir: []const u8) Repo {
        return .{ .alloc = alloc, .io = io, .local_dir = local_dir };
    }

    /// Find a game recipe by its id. Returns owned ParsedGame; caller deinits.
    pub fn findGame(self: *Repo, id: []const u8) errs.Error!?zon.ParsedGame {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.game.zon", .{ self.local_dir, id }) catch return errs.Error.OutOfMemory;
        const parsed = zon.loadGame(self.io, self.alloc, path) catch |e| switch (e) {
            errs.Error.RecipeNotFound => return null,
            else => return e,
        };
        return parsed;
    }

    /// Look up a game recipe by its F95 thread id. Walks the local
    /// recipes directory and parses every `*.game.zon` until one
    /// matches. O(N) over the user's authored recipes — fine for the
    /// tens-to-hundreds we expect. Promote to an index if it ever
    /// becomes hot.
    pub fn findGameByThread(self: *Repo, thread_id: u64) errs.Error!?zon.ParsedGame {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.local_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return null,
            else => return errs.Error.RecipeNotFound,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".game.zon")) continue;

            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.local_dir, entry.name }) catch continue;

            var parsed = zon.loadGame(self.io, self.alloc, path) catch continue;
            if (parsed.recipe.f95_thread == thread_id) return parsed;
            parsed.deinit();
        }
        return null;
    }

    /// Scan every `*.game.zon` for a source with `sha256 == hex_sha`
    /// (case-insensitive). Returns the matching recipe's `version`
    /// duped on the repo allocator (caller frees). First hit wins;
    /// callers shouldn't rely on stable ordering across runs.
    ///
    /// Used by the manual-install panel to pre-fill the Version
    /// field when the user picks an archive whose hash we recognise
    /// from a local recipe — saves them typing.
    pub fn findVersionByArchiveSha256(self: *Repo, hex_sha: []const u8) errs.Error!?[]u8 {
        if (hex_sha.len == 0) return null;

        var dir = std.Io.Dir.cwd().openDir(self.io, self.local_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return null,
            else => return errs.Error.RecipeNotFound,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".game.zon")) continue;

            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.local_dir, entry.name }) catch continue;

            var parsed = zon.loadGame(self.io, self.alloc, path) catch continue;
            const matched = sourceListContainsSha(parsed.recipe.sources, hex_sha);
            if (matched) {
                const v = self.alloc.dupe(u8, parsed.recipe.version) catch {
                    parsed.deinit();
                    return errs.Error.OutOfMemory;
                };
                parsed.deinit();
                return v;
            }
            parsed.deinit();
        }
        return null;
    }

    /// Walk the local recipes dir, parse every `*.mod.zon`, keep the
    /// ones whose `for_game` field matches `game_recipe_id`. Caller-
    /// owned slice; release with `freeModList` (or iterate + deinit
    /// each entry then `alloc.free(slice)`).
    pub fn listModsForGame(self: *Repo, game_recipe_id: []const u8) errs.Error![]zon.ParsedMod {
        var out: std.ArrayList(zon.ParsedMod) = .empty;
        errdefer {
            for (out.items) |*p| p.deinit();
            out.deinit(self.alloc);
        }

        var dir = std.Io.Dir.cwd().openDir(self.io, self.local_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return out.toOwnedSlice(self.alloc) catch return errs.Error.OutOfMemory,
            else => return errs.Error.RecipeNotFound,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".mod.zon")) continue;

            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.local_dir, entry.name }) catch continue;

            var parsed = zon.loadMod(self.io, self.alloc, path) catch continue;
            if (!std.mem.eql(u8, parsed.recipe.for_game, game_recipe_id)) {
                parsed.deinit();
                continue;
            }
            out.append(self.alloc, parsed) catch {
                parsed.deinit();
                return errs.Error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    /// Companion to `listModsForGame` — deinit each ParsedMod and free
    /// the slice.
    pub fn freeModList(self: *Repo, mods: []zon.ParsedMod) void {
        for (mods) |*m| m.deinit();
        self.alloc.free(mods);
    }

    pub fn findMod(self: *Repo, id: []const u8) errs.Error!?zon.ParsedMod {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.mod.zon", .{ self.local_dir, id }) catch return errs.Error.OutOfMemory;
        const parsed = zon.loadMod(self.io, self.alloc, path) catch |e| switch (e) {
            errs.Error.RecipeNotFound => return null,
            else => return e,
        };
        return parsed;
    }

    pub fn saveGame(self: *Repo, recipe: *const dom.GameRecipe) errs.Error!void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.game.zon", .{ self.local_dir, recipe.id }) catch return errs.Error.OutOfMemory;
        return zon.saveGame(self.io, self.alloc, path, recipe);
    }

    pub fn saveMod(self: *Repo, recipe: *const dom.ModRecipe) errs.Error!void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.mod.zon", .{ self.local_dir, recipe.id }) catch return errs.Error.OutOfMemory;
        return zon.saveMod(self.io, self.alloc, path, recipe);
    }
};

/// True iff any source in `sources` has a sha256 matching `hex_sha`
/// case-insensitively. Used by `findVersionByArchiveSha256`. Mirror
/// entries' sha256 is optional; rpdl/ddl carry it unconditionally.
fn sourceListContainsSha(sources: []const dom.Source, hex_sha: []const u8) bool {
    for (sources) |s| {
        const candidate: ?[]const u8 = switch (s) {
            .rpdl => |x| x.sha256,
            .ddl => |x| x.sha256,
            .mirror => |x| x.sha256,
        };
        if (candidate) |csha| {
            if (csha.len == hex_sha.len and std.ascii.eqlIgnoreCase(csha, hex_sha)) return true;
        }
    }
    return false;
}
