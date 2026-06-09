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
const TestEnv = @import("util_test_env").TestEnv;
const util_setting = @import("util_setting");

// Pull in nested test files as the harness grows.
test {
    std.testing.refAllDecls(@This());
}

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
