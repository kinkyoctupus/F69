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
const TestBackend = @import("dvui_testing_backend");
const TestEnv = @import("util_test_env").TestEnv;
const util_setting = @import("util_setting");

// Pull in nested test files as the harness grows.
test {
    std.testing.refAllDecls(@This());
}

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
