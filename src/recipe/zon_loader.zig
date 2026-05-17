// Parse a recipe .zon file via std.zon.parse. No custom lexer/parser/AST.
// The recipe domain types in `domain.zig` are the deserialization target.
//
// Recipe kind is detected by file extension: `<id>.game.zon` /
// `<id>.mod.zon`. The repository.zig file routes the right loader.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");

/// Cap on a single recipe's source size. Real recipes are well under
/// 64 KiB; the limit is a safety net against malformed files.
const RECIPE_MAX_BYTES: usize = 256 * 1024;

pub const ParsedGame = struct {
    recipe: dom.GameRecipe,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedGame) void {
        self.arena.deinit();
    }
};

pub const ParsedMod = struct {
    recipe: dom.ModRecipe,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedMod) void {
        self.arena.deinit();
    }
};

/// Load + parse a game recipe from disk. Returned ParsedGame owns its
/// arena; deinit when done. `io` is the project-wide `std.Io` handle —
/// recipe loading is small so synchronous-in-the-IO-fiber is fine.
pub fn loadGame(io: std.Io, parent_alloc: std.mem.Allocator, path: []const u8) errs.Error!ParsedGame {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();

    const bytes_z = readFileSentinel(io, arena.allocator(), path) catch |e| return mapReadErr(e);
    const recipe = std.zon.parse.fromSliceAlloc(
        dom.GameRecipe,
        arena.allocator(),
        bytes_z,
        null,
        .{ .ignore_unknown_fields = true, .free_on_error = false },
    ) catch |e| return switch (e) {
        error.OutOfMemory => errs.Error.OutOfMemory,
        error.ParseZon => errs.Error.ZonParseError,
    };
    return .{ .recipe = recipe, .arena = arena };
}

pub fn loadMod(io: std.Io, parent_alloc: std.mem.Allocator, path: []const u8) errs.Error!ParsedMod {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();

    const bytes_z = readFileSentinel(io, arena.allocator(), path) catch |e| return mapReadErr(e);
    const recipe = std.zon.parse.fromSliceAlloc(
        dom.ModRecipe,
        arena.allocator(),
        bytes_z,
        null,
        .{ .ignore_unknown_fields = true, .free_on_error = false },
    ) catch |e| return switch (e) {
        error.OutOfMemory => errs.Error.OutOfMemory,
        error.ParseZon => errs.Error.ZonParseError,
    };
    return .{ .recipe = recipe, .arena = arena };
}

/// Parse a game recipe directly from a sentinel-terminated source slice.
/// Used by tests and when the source isn't on disk yet (e.g. user has
/// it pasted into the inline editor). Caller frees via ParsedGame.deinit.
pub fn parseGameFromBytes(parent_alloc: std.mem.Allocator, bytes_z: [:0]const u8) errs.Error!ParsedGame {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const recipe = std.zon.parse.fromSliceAlloc(
        dom.GameRecipe,
        arena.allocator(),
        bytes_z,
        null,
        .{ .ignore_unknown_fields = true, .free_on_error = false },
    ) catch |e| return switch (e) {
        error.OutOfMemory => errs.Error.OutOfMemory,
        error.ParseZon => errs.Error.ZonParseError,
    };
    return .{ .recipe = recipe, .arena = arena };
}

pub fn parseModFromBytes(parent_alloc: std.mem.Allocator, bytes_z: [:0]const u8) errs.Error!ParsedMod {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const recipe = std.zon.parse.fromSliceAlloc(
        dom.ModRecipe,
        arena.allocator(),
        bytes_z,
        null,
        .{ .ignore_unknown_fields = true, .free_on_error = false },
    ) catch |e| return switch (e) {
        error.OutOfMemory => errs.Error.OutOfMemory,
        error.ParseZon => errs.Error.ZonParseError,
    };
    return .{ .recipe = recipe, .arena = arena };
}

/// Serialize a recipe back to ZON for saving. We write to a tmp path
/// + atomic rename so a crash mid-write can never leave a partial
/// recipe on disk.
pub fn saveGame(io: std.Io, alloc: std.mem.Allocator, path: []const u8, recipe: *const dom.GameRecipe) errs.Error!void {
    return saveAny(dom.GameRecipe, io, alloc, path, recipe);
}

pub fn saveMod(io: std.Io, alloc: std.mem.Allocator, path: []const u8, recipe: *const dom.ModRecipe) errs.Error!void {
    return saveAny(dom.ModRecipe, io, alloc, path, recipe);
}

fn saveAny(comptime T: type, io: std.Io, alloc: std.mem.Allocator, path: []const u8, recipe: *const T) errs.Error!void {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(alloc, 4096) catch return errs.Error.OutOfMemory;
    defer aw.deinit();
    std.zon.stringify.serialize(recipe.*, .{}, &aw.writer) catch return errs.Error.SaveFailed;

    var tmp_buf: [1024]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return errs.Error.SaveFailed;
    var tmp = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true }) catch return errs.Error.SaveFailed;
    defer tmp.close(io);
    var fw_buf: [4096]u8 = undefined;
    var fw = tmp.writer(io, &fw_buf);
    fw.interface.writeAll(aw.writer.buffered()) catch return errs.Error.SaveFailed;
    fw.interface.flush() catch return errs.Error.SaveFailed;
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch return errs.Error.SaveFailed;
}

fn readFileSentinel(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        alloc,
        .limited(RECIPE_MAX_BYTES),
        .of(u8),
        0,
    );
}

fn mapReadErr(e: anyerror) errs.Error {
    return switch (e) {
        error.OutOfMemory => errs.Error.OutOfMemory,
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.IsDir => errs.Error.RecipeNotFound,
        else => errs.Error.ZonParseError,
    };
}

// ============================================================
//  tests — round-trip a game + a mod recipe
// ============================================================

test "parseGameFromBytes minimal recipe" {
    const src: [:0]const u8 =
        \\.{
        \\    .id = "summertime-saga",
        \\    .name = "Summertime Saga",
        \\    .f95_thread = 1234,
        \\    .version = "0.20.17",
        \\    .engine = .renpy,
        \\}
    ;
    var parsed = try parseGameFromBytes(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("summertime-saga", parsed.recipe.id);
    try std.testing.expectEqualStrings("Summertime Saga", parsed.recipe.name);
    try std.testing.expectEqual(@as(u64, 1234), parsed.recipe.f95_thread);
    try std.testing.expectEqualStrings("0.20.17", parsed.recipe.version);
    try std.testing.expectEqual(dom.Engine.renpy, parsed.recipe.engine);
}

test "parseGameFromBytes with mirror source + install step" {
    const src: [:0]const u8 =
        \\.{
        \\    .id = "x",
        \\    .name = "X",
        \\    .f95_thread = 1,
        \\    .version = "1.0",
        \\    .sources = .{
        \\        .{ .mirror = .{
        \\            .url = "https://attachments.f95zone.to/x.zip",
        \\            .host = .f95_attachment,
        \\        } },
        \\    },
        \\    .install = .{
        \\        .{ .extract = .{ .to = ".", .strip = 1 } },
        \\    },
        \\}
    ;
    var parsed = try parseGameFromBytes(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.recipe.sources.len);
    try std.testing.expect(parsed.recipe.sources[0] == .mirror);
    try std.testing.expectEqualStrings("https://attachments.f95zone.to/x.zip", parsed.recipe.sources[0].mirror.url);
    try std.testing.expectEqual(@as(usize, 1), parsed.recipe.install.len);
    try std.testing.expect(parsed.recipe.install[0] == .extract);
    try std.testing.expectEqualStrings(".", parsed.recipe.install[0].extract.to);
    try std.testing.expectEqual(@as(u8, 1), parsed.recipe.install[0].extract.strip);
}

test "parseGameFromBytes rejects malformed input" {
    const src: [:0]const u8 = ".{ .id = \"x\", .name = ";
    const r = parseGameFromBytes(std.testing.allocator, src);
    try std.testing.expectError(errs.Error.ZonParseError, r);
}

test "parseModFromBytes minimal" {
    const src: [:0]const u8 =
        \\.{
        \\    .id = "incest-patch",
        \\    .name = "Incest Patch",
        \\    .f95_thread = 99,
        \\    .version = "1.0",
        \\    .for_game = "summertime-saga",
        \\    .for_game_version = "0.20",
        \\}
    ;
    var parsed = try parseModFromBytes(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("incest-patch", parsed.recipe.id);
    try std.testing.expectEqualStrings("summertime-saga", parsed.recipe.for_game);
}

test "parseModFromBytes with extract_inner step" {
    const src: [:0]const u8 =
        \\.{
        \\    .id = "double-packed",
        \\    .name = "Double Packed",
        \\    .f95_thread = 77,
        \\    .version = "1.0",
        \\    .for_game = "x",
        \\    .install = .{
        \\        .{ .extract = .{ .to = "./staging/", .strip = 0 } },
        \\        .{ .extract_inner = .{ .archive = "staging/inner.zip", .to = "./game/", .strip = 1 } },
        \\    },
        \\}
    ;
    var parsed = try parseModFromBytes(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.recipe.install.len);
    try std.testing.expect(parsed.recipe.install[1] == .extract_inner);
    try std.testing.expectEqualStrings("staging/inner.zip", parsed.recipe.install[1].extract_inner.archive);
    try std.testing.expectEqualStrings("./game/", parsed.recipe.install[1].extract_inner.to);
    try std.testing.expectEqual(@as(u8, 1), parsed.recipe.install[1].extract_inner.strip);
}

test "parseModFromBytes with load_after / conflicts" {
    const src: [:0]const u8 =
        \\.{
        \\    .id = "patch-b",
        \\    .name = "Patch B",
        \\    .f95_thread = 200,
        \\    .version = "1.0",
        \\    .for_game = "x",
        \\    .load_after = .{ "patch-a" },
        \\    .conflicts = .{ "patch-c" },
        \\}
    ;
    var parsed = try parseModFromBytes(std.testing.allocator, src);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.recipe.load_after.len);
    try std.testing.expectEqualStrings("patch-a", parsed.recipe.load_after[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.recipe.conflicts.len);
    try std.testing.expectEqualStrings("patch-c", parsed.recipe.conflicts[0]);
}

test "saveGame round-trip" {
    // Serialize a recipe to an allocating writer and parse it back.
    // Skips the file-system path so the test stays hermetic.
    const original = dom.GameRecipe{
        .id = "round-trip-id",
        .name = "Round Trip",
        .f95_thread = 42,
        .version = "0.1",
        .engine = .unity,
    };

    var aw: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 1024);
    defer aw.deinit();
    try std.zon.stringify.serialize(original, .{}, &aw.writer);

    // fromSliceAlloc needs a sentinel-terminated slice. dupeZ.
    const slice_z = try std.testing.allocator.dupeZ(u8, aw.writer.buffered());
    defer std.testing.allocator.free(slice_z);

    var parsed = try parseGameFromBytes(std.testing.allocator, slice_z);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(original.id, parsed.recipe.id);
    try std.testing.expectEqualStrings(original.name, parsed.recipe.name);
    try std.testing.expectEqual(original.f95_thread, parsed.recipe.f95_thread);
    try std.testing.expectEqualStrings(original.version, parsed.recipe.version);
    try std.testing.expectEqual(original.engine, parsed.recipe.engine);
}
