//! Layer-1 headless integration tests.
//!
//! Built against dvui's *testing* backend (pure CPU — no SDL, no Vulkan,
//! no window, no compositor), so f69's action layer can be driven
//! head­lessly and uniformly on any OS. The same compiled logic runs the
//! same everywhere, so these run once per OS *target* (not per distro /
//! per package). See docs/test-automation-research.md (Layer 1) and
//! docs/test-plan-full.md.
//!
//! Run with: `zig build test-integration`
//!
//! This file is the harness root. It reuses every non-dvui service
//! module directly and the `ui` module rebuilt against the testing
//! backend. The slices grow from here: settings persistence (no deps) →
//! Frame-driven actions on a testing window (next).

const std = @import("std");
const ui = @import("ui");
const dvui = @import("dvui");
const library = @import("library");
const recipe = @import("recipe");
const f95_indexer = @import("f95_indexer");
const net = std.Io.net;
const TestBackend = @import("dvui_testing_backend");
const TestEnv = @import("util_test_env").TestEnv;
const util_setting = @import("util_setting");

// Pull in nested test files as the harness grows.
test {
    std.testing.refAllDecls(@This());
}

/// A localhost HTTP fixture server for the F95Checker cache API. Serves
/// canned `/fast` + `/full/{id}` responses so the indexer client can be
/// tested deterministically (the indexer's base_url is injectable). Handles
/// exactly `expected_requests` connections then the worker thread exits on
/// its own — no shutdown race. The server struct is heap-stable (the worker
/// borrows it by pointer).
const FixtureServer = struct {
    const FAST_JSON = "{\"12345\": 1700000000}";
    const FULL_JSON = "{\"name\": \"Eva's Ecstasy\", \"version\": \"1.3\", \"developer\": \"GilgaGames\"}";

    gpa: std.mem.Allocator,
    io: std.Io,
    server: net.Server,
    port: u16,
    thread: std.Thread,

    fn start(gpa: std.mem.Allocator, io: std.Io, expected_requests: usize) !*FixtureServer {
        const self = try gpa.create(FixtureServer);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.io = io;

        // Bind a fixed loopback port, retrying on collision.
        var port: u16 = 41700;
        self.server = while (port < 41760) : (port += 1) {
            const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch continue;
            break addr.listen(io, .{ .reuse_address = true }) catch continue;
        } else return error.NoFreePort;
        self.port = port;

        self.thread = try std.Thread.spawn(.{}, serve, .{ self, expected_requests });
        return self;
    }

    fn serve(self: *FixtureServer, expected_requests: usize) void {
        var i: usize = 0;
        while (i < expected_requests) : (i += 1) {
            var stream = self.server.accept(self.io) catch break;
            defer stream.close(self.io);
            var rbuf: [8192]u8 = undefined;
            var wbuf: [8192]u8 = undefined;
            var sr = stream.reader(self.io, &rbuf);
            var sw = stream.writer(self.io, &wbuf);
            var hs = std.http.Server.init(&sr.interface, &sw.interface);
            var req = hs.receiveHead() catch continue;
            const body = if (std.mem.startsWith(u8, req.head.target, "/fast")) FAST_JSON else FULL_JSON;
            req.respond(body, .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch {};
        }
    }

    fn deinit(self: *FixtureServer) void {
        self.thread.join();
        self.server.deinit(self.io);
        self.gpa.destroy(self);
    }
};

/// A dvui window on the testing backend (pure CPU — no display). The
/// backend value must outlive the window (the window's render vtable
/// points back at it), so both are returned by-pointer-stable locals in
/// the caller and torn down window-first.
const TestWindow = struct {
    backend: TestBackend,
    window: dvui.Window,

    // Fills `self` in place — the backend must sit at a stable address
    // before the window captures `&self.backend` in its render vtable, so
    // this can't return by value.
    fn init(self: *TestWindow, gpa: std.mem.Allocator, io: std.Io) !void {
        dvui.io = io;
        const sz = dvui.Size{ .w = 1280, .h = 800 };
        self.backend = TestBackend.init(.{
            .allocator = gpa,
            .size = dvui.Size.Natural.cast(sz),
            .size_pixels = sz.scale(2.0, dvui.Size.Physical),
        });
        self.window = try dvui.Window.init(@src(), gpa, self.backend.backend(), .{});
    }

    fn deinit(self: *TestWindow) void {
        self.window.deinit();
        self.backend.deinit();
    }
};

// --- F10: settings persistence -------------------------------------------
//
// Proves the whole headless path: the `ui` module + action layer compile
// and run against the testing backend with no display, and a real action
// mutates on-disk state that survives a reload. This is the smallest
// end-to-end slice — no window/Frame/services yet (those come next), just
// the action layer driven directly.

test "headless: ui_scale persists through the action layer and reloads" {
    const ta = std.testing.allocator;
    var env = try TestEnv.init(ta, "headless-uiscale");
    defer env.deinit();

    const path = try env.path("ui_scale");
    defer ta.free(path);

    var state: ui.State = .{};
    state.ui_scale = 1.5;
    state.ui_scale_persisted = 1.25; // dirty → should write

    ui.persistUiScaleIfDirty(&state, path, env.io);

    // The dirty flag is cleared once written.
    try std.testing.expectEqual(@as(f32, 1.5), state.ui_scale_persisted);

    // And the value is on disk, reloadable by the same loader main uses.
    const reloaded = util_setting.loadFloat(f32, env.io, ta, path, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), reloaded, 0.001);
}

test "headless: ui_scale not rewritten when unchanged (no dirty)" {
    const ta = std.testing.allocator;
    var env = try TestEnv.init(ta, "headless-uiscale-clean");
    defer env.deinit();

    const path = try env.path("ui_scale");
    defer ta.free(path);

    var state: ui.State = .{};
    state.ui_scale = 1.25;
    state.ui_scale_persisted = 1.25; // not dirty → must NOT write

    ui.persistUiScaleIfDirty(&state, path, env.io);

    // File should not exist (nothing was written) → readSingleLine errors
    // (missing file) and yields null.
    const maybe = util_setting.readSingleLine(env.io, ta, path) catch null;
    if (maybe) |s| ta.free(s);
    try std.testing.expect(maybe == null);
}

// --- F4.2: folder scan (full Frame harness, no network) ------------------
//
// The first Frame-driven slice: builds the complete service graph + a
// Frame on a testing window via ui.Harness, then drives the real folder-
// scan action (doFolderScan + pump tickFolderScan to completion) against
// a synthetic Ren'Py install, asserting the scan detected it. This is the
// template every remaining feature suite follows: build harness → frame()
// → drive action → drain → assert on real state.

test "headless: folder scan detects a Ren'Py game (F4.2)" {
    const gpa = std.testing.allocator;
    var env = try TestEnv.init(gpa, "headless-folderscan");
    defer env.deinit();

    // A scannable tree: <root>/games/MyGame/renpy/bootstrap.py is the
    // Ren'Py fingerprint folder_scan looks for.
    try env.writeFile("games/MyGame/renpy/bootstrap.py", "");
    const scan_dir = try env.path("games");
    defer gpa.free(scan_dir);

    var tw: TestWindow = undefined;
    try tw.init(gpa, env.io);
    defer tw.deinit();

    var h = try ui.Harness.init(gpa, env.io, &tw.window, env.root);
    defer h.deinit();

    var f = h.frame();
    ui.doFolderScan(&f, scan_dir);

    // Pump the scan forward until the session reports done (bounded so a
    // bug can't hang the test).
    var guard: usize = 0;
    while (guard < 100_000) : (guard += 1) {
        ui.tickFolderScan(&f);
        if (std.mem.indexOf(u8, h.state.folderScanMsg(), "done") != null) break;
    }

    try std.testing.expect(std.mem.indexOf(u8, h.state.folderScanMsg(), "done") != null);
    try std.testing.expect(h.state.folder_scan_row_count >= 1);
}

// --- F3: library DB round-trip + engine filter ---------------------------
//
// A pure-DB slice (no Frame/window needed): insert games through the real
// SQLite layer, read them back, and run the production filter predicate.
// Shows that integration slices only spin up the full ui.Harness when they
// need a Frame; DB/logic round-trips use the service directly.

test "headless: engine filter selects matching games after a DB round-trip (F3)" {
    const gpa = std.testing.allocator;
    var env = try TestEnv.init(gpa, "headless-filter");
    defer env.deinit();

    const db_path = try env.path("f69.db");
    defer gpa.free(db_path);

    var lib = try library.Library.open(gpa, db_path);
    defer lib.close();

    _ = try lib.insertIfMissing(&.{ .f95_thread_id = 1, .name = "RenGame", .engine = .renpy });
    _ = try lib.insertIfMissing(&.{ .f95_thread_id = 2, .name = "UniGame", .engine = .unity });

    const games = try lib.listGames();
    defer lib.freeGames(games);
    try std.testing.expectEqual(@as(usize, 2), games.len);

    // Filter to Ren'Py only → exactly one match.
    var filters = ui.Filters{};
    filters.engine.insert(.renpy);
    var matched: usize = 0;
    for (games) |*g| {
        if (filters.match(g)) matched += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), matched);
}

// --- F7: recipe save + reload round-trip ---------------------------------
//
// Drives the harness's recipe repo (the real ZON serialize → disk → parse
// path) and asserts a saved game recipe reloads by thread id. Exercises the
// recipe subsystem through the same Repo the Download/Install actions use.

test "headless: game recipe saves to disk and reloads by thread (F7)" {
    const gpa = std.testing.allocator;
    var env = try TestEnv.init(gpa, "headless-recipe");
    defer env.deinit();

    var tw: TestWindow = undefined;
    try tw.init(gpa, env.io);
    defer tw.deinit();

    var h = try ui.Harness.init(gpa, env.io, &tw.window, env.root);
    defer h.deinit();

    const rec = recipe.GameRecipe{
        .id = "test-game-1",
        .name = "Test Game",
        .f95_thread = 12345,
        .version = "1.0",
        .engine = .renpy,
    };
    try h.recipe_repo.saveGame(&rec);

    var found = (try h.recipe_repo.findGameByThread(12345)) orelse return error.TestUnexpectedResult;
    defer found.deinit();
    try std.testing.expectEqualStrings("Test Game", found.recipe.name);
    try std.testing.expectEqual(@as(u64, 12345), found.recipe.f95_thread);
    try std.testing.expectEqualStrings("1.0", found.recipe.version);
}

// --- F2: indexer sync against a localhost fixture (deterministic) --------
//
// The first network slice. Stands up a localhost HTTP server serving canned
// F95Checker cache-API responses, points an indexer client at it (base_url
// is injectable), and asserts the real request-build → HTTP → parse path.
// Two requests: /fast then /full. No real internet, fully deterministic.

test "headless: indexer client fetches + parses against a fixture server (F2)" {
    const gpa = std.testing.allocator;
    // The Threaded io's gpa backs io.async (the HTTP client's concurrent
    // connect) and is touched from multiple threads, so it MUST be
    // threadsafe — testing.allocator isn't. Use the smp allocator for the
    // io; the test's own allocations still go through testing.allocator so
    // leaks are caught.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try FixtureServer.start(gpa, io, 2);
    defer fx.deinit();

    var url_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{fx.port});
    var client = f95_indexer.Client.init(gpa, io, base);

    // /fast — change-timestamp probe.
    const fast = try client.fastCheck(&.{12345});
    defer gpa.free(fast);
    try std.testing.expectEqual(@as(usize, 1), fast.len);
    try std.testing.expectEqual(@as(u64, 12345), fast[0].id);
    try std.testing.expectEqual(@as(i64, 1700000000), fast[0].last_change);

    // /full — the metadata the sync worker maps onto the game row.
    var full = try client.fullCheck(12345, 0);
    defer full.deinit();
    try std.testing.expectEqualStrings("Eva's Ecstasy", full.name.?);
    try std.testing.expectEqualStrings("1.3", full.version.?);
    try std.testing.expectEqualStrings("GilgaGames", full.developer.?);
}

// --- F2 end-to-end: sync action populates a game row from the fixture ----
//
// The full pipeline through the harness: an unsynced game + the real
// startSyncAll action (indexer backend) → batched /fast pre-flight → /full
// for the changed game → applyScrape to the DB. Drives it against the
// localhost fixture (2 requests) and drains the async sync workers to
// completion, then asserts the game row got its scraped metadata. Ties
// together harness + fixture + worker-drain + DB.

test "headless: sync action populates a game from the indexer fixture (F2 e2e)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try TestEnv.init(gpa, "sync-action");
    defer env.deinit();

    var fx = try FixtureServer.start(gpa, io, 2); // /fast + /full
    defer fx.deinit();

    var tw: TestWindow = undefined;
    try tw.init(gpa, io);
    defer tw.deinit();

    var h = try ui.Harness.init(gpa, io, &tw.window, env.root);
    defer h.deinit();

    // Point the harness's indexer at the fixture; ensure indexer backend.
    var url_buf: [64]u8 = undefined;
    h.indexer_client.base_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{fx.port});
    h.state.refresh_backend = .indexer;

    // An unsynced game the sync should fill in.
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 12345, .name = "(unsynced)" });
    try h.reloadGames();

    var f = h.frame();
    ui.startSyncAll(&f);
    h.drainWorkers(500);

    // The DB row should now carry the scraped name.
    try h.reloadGames();
    const g = blk: {
        for (h.games) |*x| if (x.f95_thread_id == 12345) break :blk x;
        break :blk null;
    } orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Eva's Ecstasy", g.name);
}
