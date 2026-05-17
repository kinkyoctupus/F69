// Per-game launch + convert + running-games tracking + saves/folder
// helpers + compat env composition. After R9 lives separate from the
// sync / downloads / installer pipelines that surround it.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const recipe = @import("recipe");
const sandbox_mod = @import("sandbox");
const convert_mod = @import("convert");
const compat_mod = @import("compat");
const downloads = @import("downloads");
const version_mod = @import("util_version");
const dvui = @import("dvui");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const owned_types = @import("../owned.zig");
const mods_act = @import("mods.zig");

const Frame = types.Frame;
const State = types.State;

const RunningGamesMap = owned_types.RunningGamesMap;

// ============================================================
//  per-game launch — recipe + sandbox
// ============================================================

/// Resolve the recipe for `game`, ensure the placeholder install dir
/// + per-game sandbox HOME exist, then ask the sandbox backend to
/// launch the recipe's `launch.linux` executable.
///
/// Layout (until Phase 7 installer lands a real version-keyed layout):
///   - install dir:  `<library_root>/<thread_id>/`
///   - sandbox HOME: `<library_root>/<thread_id>/.f69-home/`
///
/// On failure: writes a one-line message to `state.launch_msg_buf`.
/// On success: same buffer reports the PID.
pub fn doLaunchGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // ---- 1. install_path ----
    // Resolve which install row Launch acts on:
    //   1. Honour `state.detail_picker_install_id` — whatever the
    //      detail-page dropdown currently shows is what runs.
    //   2. Fall back to the newest install (top of version-desc list)
    //      when the picker hasn't recorded a choice yet (e.g. detail
    //      page opened then Launch hit from a keybind before paint).
    //   3. Last-ditch fallback: legacy `<library_root>/<tid>/` for the
    //      pre-multi-install layout — keeps Launch alive for installs
    //      that predate the installs table.
    var fallback_buf: [640]u8 = undefined;
    const installs_owned: ?[]library.Install = frame.lib.listInstalls(game.f95_thread_id) catch null;
    defer if (installs_owned) |list| frame.lib.freeInstalls(list);
    const picked_install: ?*const library.Install = blk: {
        const list = installs_owned orelse break :blk null;
        if (list.len == 0) break :blk null;
        if (state.detail_picker_install_id) |sel| {
            for (list) |*inst| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) break :blk inst;
            }
        }
        break :blk &list[0];
    };
    const install_path: []const u8 = if (picked_install) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Install path buffer overflow.");
            return;
        };
    std.Io.Dir.cwd().access(frame.io, install_path, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "No install at {s}. Download the game first.", .{install_path}) catch "No install dir.";
        state.setLaunchMsg(msg);
        return;
    };

    // ---- 2. sandbox HOME ----
    // Only built when the effective sandbox decision says "sandboxed".
    // For host-mode launches we pass an empty `sandbox_home` to
    // signal NoSandbox to keep the host's own HOME in the env.
    const want_sandbox = shouldSandbox(state, game);
    var home_buf: [640]u8 = undefined;
    var sandbox_home: []const u8 = "";
    if (want_sandbox) {
        sandbox_home = std.fmt.bufPrint(&home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Sandbox HOME buffer overflow.");
            return;
        };
        std.Io.Dir.cwd().createDirPath(frame.io, sandbox_home) catch |e| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to create sandbox HOME: {s}", .{@errorName(e)}) catch "createDirPath failed";
            state.setLaunchMsg(msg);
            return;
        };
    }

    // ---- 3. resolve executable ----
    // Launcher resolution: heuristic-only. We used to honor a recipe
    // `launch.linux` pin, but that field has been retired — the
    // heuristic finder catches the canonical cases and any pin
    // belongs in a per-game settings override (future work).
    //
    // Auto-convert before launch when nothing Linux-runnable is on
    // disk yet. The convert preset matcher figures out the spec from
    // the detected engine; `.none` means "nothing to do."
    var exe_buf: [512]u8 = undefined;
    var exe_storage: []const u8 = "";
    if (findLinuxLauncher(frame.io, alloc, install_path, &exe_buf) == null) {
        const conv_spec = mods_act.resolveConvertSpec(frame, install_path);
        if (conv_spec != .none) {
            state.setLaunchMsg("Converting before launch...");
            frame.convert_svc.convert(install_path, conv_spec, false) catch |e| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Auto-convert failed: {s}", .{@errorName(e)}) catch "Auto-convert failed";
                state.setLaunchMsg(msg);
                return;
            };
        }
    }

    // Second pass post-convert (or first pass when no convert was
    // needed). The launcher should exist now if everything worked.
    if (findLinuxLauncher(frame.io, alloc, install_path, &exe_buf)) |found| {
        exe_storage = found;
        log.info("launch: auto-picked launcher '{s}' under {s}", .{ found, install_path });
    } else {
        // Nothing Linux-native on disk. Look for a Windows .exe so we
        // can give an actionable message.
        if (findWindowsExe(frame.io, alloc, install_path, &exe_buf)) |win_exe| {
            var buf: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "Found Windows binary ({s}) — click Convert to translate it for Linux first.",
                .{win_exe},
            ) catch "Windows build — click Convert first.";
            state.notifyErr(msg);
        } else {
            var buf: [384]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "No runnable found under {s}. Either the archive didn't extract cleanly (re-download), or the install layout is non-standard (open the folder and check what's there).",
                .{install_path},
            ) catch "No runnable found in the install dir.";
            state.notifyErr(msg);
        }
        return;
    }

    // Sandbox config used to pull `network` / `bind_extra` from the
    // recipe. Those are local-user decisions; default to safe (net
    // on, no extra binds). Per-game overrides will move to a DB
    // settings table when needed.
    const net: bool = true;

    // ---- 3.5. Compose env_extra from any compat fixes applied to
    //           this install. Pre-merges prepend-mode pairs with the
    //           host environ so the sandbox sees plain `SET KEY VAL`.
    //           The compat resource dir is bound into the sandbox via
    //           `bind_extra` so env paths pointing at it actually
    //           resolve inside the bwrap namespace.
    const compat_envs: []sandbox_mod.EnvOverride = blk: {
        if (picked_install) |inst| {
            break :blk composeCompatEnv(frame, &inst.id) catch |e| switch (e) {
                else => {
                    log.warn("compat env compose failed: {s}", .{@errorName(e)});
                    break :blk &.{};
                },
            };
        }
        break :blk &.{};
    };
    defer freeCompatEnv(frame.lib.alloc, compat_envs);
    const bind_extra: []const []const u8 = compatBindExtra(frame, compat_envs) catch &.{};
    defer freeCompatBindExtra(frame.lib.alloc, bind_extra);

    // ---- 4. SandboxConfig + launch ----
    // `want_sandbox` chose the route back in step 2. The sandboxed
    // path uses `frame.sandbox` (bwrap on Linux, sandboxie on Windows,
    // fallback NoSandbox elsewhere); the host path uses the always-
    // available `frame.host_launcher` with an empty `sandbox_home`
    // so the game sees the real `$HOME`.
    const cfg = sandbox_mod.SandboxConfig{
        .network = net,
        .bind_extra = bind_extra,
        .sandbox_home = sandbox_home,
        .install_path = install_path,
        .executable = exe_storage,
        .host = frame.info.host,
        .env_extra = compat_envs,
    };
    const backend_name: []const u8 = if (want_sandbox) frame.sandbox.backendName() else "host";
    const result = (if (want_sandbox)
        frame.sandbox.launch(alloc, cfg)
    else
        frame.host_launcher.launch(alloc, cfg)) catch |e| {
        // Sandbox backends stash the detail string for the most
        // recent failure. Surface it verbatim — `LaunchFailed` alone
        // is not informative ("permission denied"/"file not found"/
        // "argv too long" all collapse to the same enum value).
        const detail = if (want_sandbox) frame.sandbox.lastError() else frame.host_launcher.lastError();
        const hint = launchFailureHint(detail, backend_name);
        var buf: [512]u8 = undefined;
        const msg = if (hint.len > 0 and detail.len > 0)
            std.fmt.bufPrint(&buf, "Launch failed (backend={s}): {s}\n{s}", .{ backend_name, detail, hint }) catch "Launch failed"
        else if (detail.len > 0)
            std.fmt.bufPrint(&buf, "Launch failed (backend={s}): {s}", .{ backend_name, detail }) catch "Launch failed"
        else
            std.fmt.bufPrint(&buf, "Launch failed: {s} (backend={s})", .{ @errorName(e), backend_name }) catch "Launch failed";
        state.notifyErr(msg);
        return;
    };

    if (result.pid > 0) {
        runningGamesMap(frame).put(game.f95_thread_id, result.pid) catch {};
    }
    var ok_buf: [128]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Launched (pid {d}, {s})", .{
        result.pid,
        backend_name,
    }) catch "Launched";
    state.setLaunchMsg(ok_msg);
}

// ============================================================
//  compat env composition for launch
// ============================================================

/// Read the install's applied compat fixes, replay each recipe's
/// `env_prepend`/`env_set` actions, pre-merge prepend values with the
/// host environ, and return a freshly allocated []EnvOverride for the
/// sandbox. Caller frees via `freeCompatEnv`.
fn composeCompatEnv(frame: *Frame, install_id_ptr: *const [36]u8) ![]sandbox_mod.EnvOverride {
    const alloc = frame.lib.alloc;
    const install_id: []const u8 = install_id_ptr[0..];

    const applied = try frame.lib.listAppliedCompat(install_id);
    defer frame.lib.freeAppliedCompatList(applied);
    if (applied.len == 0) return &.{};

    // Collect recipe ids that point at recipes the repo still knows
    // about. Stale rows (recipe removed) are just skipped here; the
    // launch path doesn't take that as failure.
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    for (applied) |row| {
        ids.append(alloc, row.recipe_id) catch return error.OutOfMemory;
    }

    var outcome = try frame.compat_svc.composeEnv(ids.items);
    defer outcome.deinit();
    if (outcome.env_pairs.items.len == 0) return &.{};

    var overrides: std.ArrayList(sandbox_mod.EnvOverride) = .empty;
    errdefer freeOverridesList(alloc, &overrides);
    // Host environ getter — the frame doesn't carry an environ
    // reference, but the host_launcher does. We pull from there.
    //
    // For LD_LIBRARY_PATH specifically we ALSO pre-pend the GPU
    // driver dir (NixOS: /run/opengl-driver/lib). Without it,
    // libglvnd-based libGL.so.1 in our bundle can't find the
    // vendor implementation (libGLX_nvidia / libGLX_mesa) and
    // silently falls back to software rendering — a big perf hit
    // for anything that uses OpenGL.
    const gpu_driver_lib: ?[]const u8 = detectGpuDriverLib(frame);
    for (outcome.env_pairs.items) |p| {
        const name_owned = alloc.dupe(u8, p.name) catch return error.OutOfMemory;
        errdefer alloc.free(name_owned);
        const is_ld_path = std.mem.eql(u8, p.name, "LD_LIBRARY_PATH");
        const value_owned: []const u8 = if (p.prepend) blk: {
            const existing = frame.host_launcher.environ.getAlloc(alloc, p.name) catch null;
            defer if (existing) |e| alloc.free(e);
            // Format: <recipe value><sep><gpu driver><sep><existing>
            // Each part skipped when empty. Driver injection only
            // happens for LD_LIBRARY_PATH.
            const gpu_part: []const u8 = if (is_ld_path) (gpu_driver_lib orelse "") else "";
            const exist_str: []const u8 = if (existing) |e| e else "";
            const parts = [_][]const u8{ p.value, gpu_part, exist_str };
            const sep = p.sep;
            // Pre-compute total length + accumulate joining non-empty parts.
            var nonempty_count: usize = 0;
            var total: usize = 0;
            for (parts) |part| if (part.len > 0) {
                if (nonempty_count > 0) total += sep.len;
                total += part.len;
                nonempty_count += 1;
            };
            if (total == 0) break :blk alloc.dupe(u8, "") catch return error.OutOfMemory;
            const out = alloc.alloc(u8, total) catch return error.OutOfMemory;
            var idx: usize = 0;
            var written: usize = 0;
            for (parts) |part| if (part.len > 0) {
                if (written > 0) {
                    @memcpy(out[idx .. idx + sep.len], sep);
                    idx += sep.len;
                }
                @memcpy(out[idx .. idx + part.len], part);
                idx += part.len;
                written += 1;
            };
            break :blk out;
        } else alloc.dupe(u8, p.value) catch return error.OutOfMemory;
        log.info("compat: env override {s} (len {d})", .{ name_owned, value_owned.len });
        overrides.append(alloc, .{
            .name = name_owned,
            .value = value_owned,
        }) catch return error.OutOfMemory;
    }

    // GLX vendor hint — only when the env hasn't already set it and
    // we can confidently pick from /dev. This lives outside the
    // recipe because it depends on the host's GPU layout, not on
    // any specific recipe.
    if (detectGlxVendor(frame)) |vendor| blk: {
        const existing = frame.host_launcher.environ.getAlloc(alloc, "__GLX_VENDOR_LIBRARY_NAME") catch null;
        defer if (existing) |e| alloc.free(e);
        if (existing != null and existing.?.len > 0) break :blk;
        const name = alloc.dupe(u8, "__GLX_VENDOR_LIBRARY_NAME") catch return error.OutOfMemory;
        errdefer alloc.free(name);
        const value = alloc.dupe(u8, vendor) catch return error.OutOfMemory;
        errdefer alloc.free(value);
        log.info("compat: GLX vendor hint -> {s}", .{vendor});
        overrides.append(alloc, .{ .name = name, .value = value }) catch return error.OutOfMemory;
    }

    return overrides.toOwnedSlice(alloc) catch error.OutOfMemory;
}

/// Return the absolute path of the host's GPU-driver lib dir if one
/// looks plausible. Currently only handles NixOS's
/// `/run/opengl-driver/lib`; other distros' libGL lives in the
/// standard loader path and needs no injection.
fn detectGpuDriverLib(frame: *Frame) ?[]const u8 {
    const candidate = "/run/opengl-driver/lib";
    std.Io.Dir.cwd().access(frame.io, candidate, .{}) catch return null;
    return candidate;
}

/// libglvnd asks the X server "which GLX vendor for this screen?"
/// On XWayland + NVIDIA the answer is sometimes wrong (XWayland
/// advertises Mesa) so libglvnd loads libGLX_mesa and Mesa falls
/// back to llvmpipe (software). Overriding via
/// `__GLX_VENDOR_LIBRARY_NAME` skips that probe and forces the
/// vendor we want. Detection is best-effort:
///   - `/dev/nvidia0` present  → nvidia
///   - else `/dev/dri/card*`   → mesa
///   - else                    → null (let libglvnd decide)
fn detectGlxVendor(frame: *Frame) ?[]const u8 {
    std.Io.Dir.cwd().access(frame.io, "/dev/nvidia0", .{}) catch {
        std.Io.Dir.cwd().access(frame.io, "/dev/dri", .{}) catch return null;
        return "mesa";
    };
    return "nvidia";
}

fn freeCompatEnv(alloc: std.mem.Allocator, env: []sandbox_mod.EnvOverride) void {
    for (env) |o| {
        alloc.free(o.name);
        alloc.free(o.value);
    }
    if (env.len > 0) alloc.free(env);
}

/// Build a `bind_extra` slice that exposes the compat resource dir
/// inside the bwrap sandbox. Without this, env vars pointing at
/// `<data_root>/compat-resources/...` resolve to a path that doesn't
/// exist inside the sandbox's filesystem namespace. No-op when there
/// are no compat overrides to support. Caller frees via
/// `freeCompatBindExtra`.
///
/// Also includes `/run/opengl-driver` (NixOS) when present so the
/// bundled libGL dispatcher can find the vendor implementation.
fn compatBindExtra(frame: *Frame, env_extra: []const sandbox_mod.EnvOverride) ![]const []const u8 {
    if (env_extra.len == 0) return &.{};
    const alloc = frame.lib.alloc;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    }
    const resources_path = try std.fmt.allocPrint(alloc, "{s}/compat-resources", .{frame.info.data_root});
    try list.append(alloc, resources_path);
    if (detectGpuDriverLib(frame) != null) {
        const gpu_path = try alloc.dupe(u8, "/run/opengl-driver");
        try list.append(alloc, gpu_path);
    }
    return list.toOwnedSlice(alloc) catch error.OutOfMemory;
}

fn freeCompatBindExtra(alloc: std.mem.Allocator, bind_extra: []const []const u8) void {
    for (bind_extra) |p| alloc.free(p);
    if (bind_extra.len > 0) alloc.free(bind_extra);
}

fn freeOverridesList(alloc: std.mem.Allocator, list: *std.ArrayList(sandbox_mod.EnvOverride)) void {
    for (list.items) |o| {
        alloc.free(o.name);
        alloc.free(o.value);
    }
    list.deinit(alloc);
}

// ============================================================
//  compat issue surface — scan + apply + undo helpers
// ============================================================
//
// Callable from any UI button. The result of `scanCompatForInstall`
// is owned by the caller and freed via the matching free helper.
// `applyCompatFix` and `undoCompatFix` persist their changes to the
// library DB so subsequent launches consult the updated state.

/// Scan an install's tree against every loaded compat recipe.
/// Returned slice is owned by the caller; free with
/// `freeCompatIssues`. Status field reflects whether a FixRecord for
/// the recipe is already present in the library for this install.
pub fn scanCompatForInstall(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
) ![]compat_mod.Issue {
    const id_slice: []const u8 = install_id[0..];
    const applied = try frame.lib.listAppliedCompat(id_slice);
    defer frame.lib.freeAppliedCompatList(applied);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(frame.lib.alloc);
    for (applied) |row| ids.append(frame.lib.alloc, row.recipe_id) catch return error.OutOfMemory;
    return frame.compat_svc.scan(install_root, ids.items);
}

pub fn freeCompatIssues(frame: *Frame, issues: []compat_mod.Issue) void {
    frame.compat_svc.freeIssues(issues);
}

/// Apply one fix and persist the FixRecord. Errors propagate from
/// the service (resource missing, snapshot failure, etc.). Caller is
/// responsible for surfacing the error message in the UI.
pub fn applyCompatFix(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
    recipe_id: []const u8,
) !void {
    const alloc = frame.lib.alloc;
    const entry = frame.compat_svc.repo.byId(recipe_id) orelse return error.RecipeNotFound;
    const id_slice: []const u8 = install_id[0..];
    const fix = try frame.compat_svc.apply(id_slice, install_root, entry);
    defer {
        alloc.free(fix.recipe_id);
        alloc.free(fix.recipe_sha256);
        for (fix.backups) |b| frame.compat_svc.backups.freeRecord(b);
        if (fix.backups.len > 0) alloc.free(fix.backups);
    }
    const backups_json = try compat_mod.serializeBackups(alloc, fix.backups);
    defer alloc.free(backups_json);
    try frame.lib.upsertAppliedCompat(id_slice, fix.recipe_id, fix.recipe_sha256, fix.applied_at, backups_json);
}

/// Reverse an applied fix and remove its row from the DB. Errors
/// propagate from restore. A failed restore leaves the FixRecord
/// row in place so the user can retry.
pub fn undoCompatFix(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
    recipe_id: []const u8,
) !void {
    const id_slice: []const u8 = install_id[0..];
    const applied = try frame.lib.listAppliedCompat(id_slice);
    defer frame.lib.freeAppliedCompatList(applied);
    var match_idx: ?usize = null;
    for (applied, 0..) |row, i| if (std.mem.eql(u8, row.recipe_id, recipe_id)) {
        match_idx = i;
        break;
    };
    const row = applied[match_idx orelse return error.NotApplied];
    const backups = try compat_mod.deserializeBackups(frame.lib.alloc, row.backups_json);
    defer {
        for (backups) |b| {
            frame.lib.alloc.free(b.sha256);
            frame.lib.alloc.free(b.relpath);
            if (b.symlink_target) |t| frame.lib.alloc.free(t);
        }
        if (backups.len > 0) frame.lib.alloc.free(backups);
    }
    const fix_record = compat_mod.FixRecord{
        .recipe_id = row.recipe_id,
        .recipe_sha256 = row.recipe_sha256,
        .applied_at = row.applied_at,
        .backups = backups,
    };
    try frame.compat_svc.undo(id_slice, install_root, fix_record);
    try frame.lib.deleteAppliedCompat(id_slice, recipe_id);
}

/// Pick a one-line "what to try next" hint for the most common launch
/// failures, by sniffing the backend's error detail string. Empty
/// return = no known suggestion; the verbatim error is then on its
/// own. Patterns are conservative — better to stay silent than guess
/// wrong and send the user chasing the wrong fix.
fn launchFailureHint(detail: []const u8, backend: []const u8) []const u8 {
    if (detail.len == 0) return "";
    // bwrap-specific failures we see often on NixOS / hardened kernels.
    if (std.mem.eql(u8, backend, "bwrap")) {
        if (std.mem.indexOf(u8, detail, "user namespaces") != null or
            std.mem.indexOf(u8, detail, "unshare") != null or
            std.mem.indexOf(u8, detail, "EPERM") != null)
        {
            return "Tip: kernel.unprivileged_userns_clone may be off. Enable user namespaces (sysctl -w kernel.unprivileged_userns_clone=1) or turn sandbox off for this game.";
        }
        if (std.mem.indexOf(u8, detail, "not found") != null) {
            return "Tip: bwrap binary missing. Install it (NixOS: `nix profile add nixpkgs#bubblewrap`) or set Sandbox=Never for this game.";
        }
    }
    // Anywhere: a permission-denied on the executable means the install
    // dropped the +x bit. `chmod_x` recipe steps may have been skipped.
    if (std.mem.indexOf(u8, detail, "Permission denied") != null or
        std.mem.indexOf(u8, detail, "EACCES") != null)
    {
        return "Tip: executable missing the +x bit. `chmod +x` the launcher, or re-run Convert to redo the install's chmod step.";
    }
    if (std.mem.indexOf(u8, detail, "No such file") != null or
        std.mem.indexOf(u8, detail, "ENOENT") != null)
    {
        return "Tip: launcher path no longer exists. The install dir may have moved or been emptied — re-download / re-import.";
    }
    return "";
}

/// Resolve the effective sandbox decision for `game`. Per-game
/// `SandboxOverride` (`.always` / `.never`) wins; `.use_default`
/// consults `state.sandbox_default` (the global toggle in Settings).
pub fn shouldSandbox(state: *const State, game: *const library.Game) bool {
    return switch (game.sandbox) {
        .always => true,
        .never => false,
        .use_default => state.sandbox_default,
    };
}

/// Resolve the effective auto-update decision for `game`. Twin of
/// `shouldSandbox`: `.always` / `.never` wins; `.use_default` falls
/// back to `state.auto_update_default`.
pub fn shouldAutoUpdate(state: *const State, game: *const library.Game) bool {
    return switch (game.auto_update) {
        .always => true,
        .never => false,
        .use_default => state.auto_update_default,
    };
}

/// True iff a recipe exists for `game_id` AND it carries at least one
/// auto-fetchable source (RPDL torrent or DDL URL). Mirror entries
/// are link-lists, not auto-fetchable. Hits disk via the recipe
/// repo — keep call sites gated on a cheap pre-check (e.g. only
/// inside the recap-push branch, where version bumps are rare).
pub fn hasAutoFetchableSource(frame: *Frame, game_id: u64) bool {
    const parsed_opt = frame.recipe_repo.findGameByThread(game_id) catch return false;
    var parsed = parsed_opt orelse return false;
    defer parsed.deinit();
    for (parsed.recipe.sources) |s| switch (s) {
        .rpdl, .ddl => return true,
        .mirror => continue,
    };
    return false;
}

/// Auto-update readiness for a single game. Bundles two disk-hitting
/// checks into one recipe lookup:
///   1. Recipe has at least one auto-fetchable source (RPDL / DDL).
///   2. Recipe version is canonically equivalent to F95's
///      `latest_version` — i.e. the recipe knows about this build.
///      A stale recipe (still pinned to v0.20 while F95 ships v0.21)
///      would re-download the same old archive and label it the new
///      version; skip those silently and let the recipe-repo catch
///      up out-of-band.
/// Returns `true` only when both checks pass. Used as the auto-update
/// gate inside `drainSync`.
pub fn recipeReadyForAutoUpdate(frame: *Frame, game_id: u64, target_version: []const u8) bool {
    const parsed_opt = frame.recipe_repo.findGameByThread(game_id) catch return false;
    var parsed = parsed_opt orelse return false;
    defer parsed.deinit();
    var has_fetchable = false;
    for (parsed.recipe.sources) |s| switch (s) {
        .rpdl, .ddl => {
            has_fetchable = true;
            break;
        },
        .mirror => continue,
    };
    if (!has_fetchable) return false;
    return version_mod.equivalent(parsed.recipe.version, target_version);
}

/// Open the manual-install panel pre-filled with `latest_version` so
/// the user can point at a new archive to satisfy the update. No-op
/// on the version pre-fill when the buffer is already non-empty —
/// don't clobber whatever the user typed.
/// Look up a recipe-recorded version by SHA-256 of the user-picked
/// archive. Used by the manual-install panel to pre-fill the
/// Version field when the local recipe set happens to know this
/// file. Sync hash compute — capped at 500 MB so the UI thread
/// doesn't freeze on multi-GB game archives (the filename heuristic
/// covers larger files).
///
/// Returns the matching `recipe.version`, allocator-owned by
/// `frame.lib.alloc`, or null when:
///   - file > size cap
///   - file unreadable
///   - no recipe source's sha256 matches
const HASH_LOOKUP_MAX_BYTES: u64 = 500 * 1024 * 1024;

pub fn lookupVersionFromArchiveSha(frame: *Frame, file_path: []const u8) ?[]u8 {
    var f = std.Io.Dir.cwd().openFile(frame.io, file_path, .{ .mode = .read_only }) catch return null;
    defer f.close(frame.io);
    const st = f.stat(frame.io) catch return null;
    if (st.size > HASH_LOOKUP_MAX_BYTES) return null;

    var rd_buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(frame.io, &rd_buf);
    var hasher = downloads.Hasher.init();
    while (true) {
        var chunk: [64 * 1024]u8 = undefined;
        const got = fr.interface.readSliceShort(&chunk) catch return null;
        if (got == 0) break;
        hasher.update(chunk[0..got]);
    }
    const sha_bytes = hasher.finalize();
    const hex = std.fmt.bytesToHex(sha_bytes, .lower);

    return frame.recipe_repo.findVersionByArchiveSha256(&hex) catch null;
}

pub fn openManualInstallForUpdate(state: *State, latest_version: []const u8) void {
    state.manual_install_open = true;
    const cur = state.manualInstallVersionSlice();
    if (cur.len == 0 and latest_version.len > 0) {
        const n = @min(latest_version.len, state.manual_install_version_buf.len - 1);
        @memcpy(state.manual_install_version_buf[0..n], latest_version[0..n]);
        state.manual_install_version_buf[n] = 0;
    }
}

/// Walk `install_path` (up to a depth of 3) looking for a launchable
/// Linux file. Priority order:
///   1. `<game>.sh` at the root — Ren'Py / Linux ports universally
///      drop their launch script here.
///   2. Any `.sh` anywhere (search depth-limited).
///   3. Any `.AppImage` file.
/// Returns the path *relative to install_path* in `buf`. Null when
/// nothing matches.
fn findLinuxLauncher(io: std.Io, alloc: std.mem.Allocator, install_path: []const u8, buf: []u8) ?[]const u8 {
    _ = alloc;
    // Pass 1: shallow root scan first — that's where Ren'Py / native
    // Linux ports put their `.sh`. Cheap.
    var root = std.Io.Dir.cwd().openDir(io, install_path, .{ .iterate = true }) catch return null;
    defer root.close(io);

    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".sh") or
            std.mem.endsWith(u8, entry.name, ".AppImage"))
        {
            return std.fmt.bufPrint(buf, "{s}", .{entry.name}) catch null;
        }
    }

    // Pass 2: one level deeper. Many extracted archives wrap the
    // game in a single subdir.
    var it2 = root.iterate();
    while (it2.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var sub_path_buf: [320]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ install_path, entry.name }) catch continue;
        var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (sub_it.next(io) catch null) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (std.mem.endsWith(u8, sub_entry.name, ".sh") or
                std.mem.endsWith(u8, sub_entry.name, ".AppImage"))
            {
                return std.fmt.bufPrint(buf, "{s}/{s}", .{ entry.name, sub_entry.name }) catch null;
            }
        }
    }
    return null;
}

/// Same shape as `findLinuxLauncher`, but for `.exe`. Used to give
/// the user an actionable "needs conversion" message instead of just
/// "nothing runnable found".
fn findWindowsExe(io: std.Io, alloc: std.mem.Allocator, install_path: []const u8, buf: []u8) ?[]const u8 {
    _ = alloc;
    var root = std.Io.Dir.cwd().openDir(io, install_path, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".exe")) {
            return std.fmt.bufPrint(buf, "{s}", .{entry.name}) catch null;
        }
    }
    var it2 = root.iterate();
    while (it2.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var sub_path_buf: [320]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ install_path, entry.name }) catch continue;
        var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (sub_it.next(io) catch null) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (std.mem.endsWith(u8, sub_entry.name, ".exe")) {
                return std.fmt.bufPrint(buf, "{s}/{s}", .{ entry.name, sub_entry.name }) catch null;
            }
        }
    }
    return null;
}

// ============================================================
//  per-game convert — recipe + ConvertService
// ============================================================

/// Resolve the recipe for `game`, build a `convert.ConvertSpec` from
/// its `convert_linux` block, then ask the service to apply it against
/// `<library_root>/<thread_id>/` (the same placeholder install dir
/// the Launch action uses). Idempotent — re-clicking after a
/// successful convert reports "already converted".
pub fn doConvertGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    // Convert operates against whatever the *latest* install is. If
    // there's no DB row yet, fall back to the legacy placeholder dir.
    var fallback_buf: [640]u8 = undefined;
    const install_opt = frame.lib.latestInstallForGame(game.f95_thread_id) catch null;
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install_path: []const u8 = if (install_opt) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setConvertMsg("Install path buffer overflow.");
            return;
        };

    // Convert spec from the preset matcher — engine-keyed dispatch
    // over the merged built-in + `<data_root>/convert-presets/` pool.
    const spec = mods_act.resolveConvertSpec(frame, install_path);
    if (spec == .none) {
        state.setConvertMsg("No convert needed (engine not detected, or already Linux-native).");
        return;
    }

    frame.convert_svc.convert(install_path, spec, false) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Convert failed: {s}", .{@errorName(e)}) catch "Convert failed";
        state.setConvertMsg(msg);
        return;
    };

    state.setConvertMsg("Converted. Try Launch.");
}

// `RunningGamesMap` aliased from `owned.zig` at the top of the file.

fn runningGamesMap(frame: *Frame) *RunningGamesMap {
    if (frame.state.running_games) |p| return p;
    const map_ptr = frame.lib.alloc.create(RunningGamesMap) catch unreachable;
    map_ptr.* = RunningGamesMap.init(frame.lib.alloc);
    frame.state.running_games = map_ptr;
    return map_ptr;
}

/// Read-only probe — screens.zig uses this to swap Launch ↔ Stop.
pub fn isGameRunning(frame: *Frame, thread_id: u64) bool {
    if (frame.state.running_games == null) return false;
    return runningGamesMap(frame).contains(thread_id);
}

/// SIGTERM the running game for `game.f95_thread_id` and drop the
/// state entry. No-op + cleanup when the process is already dead.
pub fn doStopGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const m = runningGamesMap(frame);
    const pid = m.get(game.f95_thread_id) orelse {
        state.setLaunchMsg("Game is not tracked as running.");
        return;
    };
    std.posix.kill(@intCast(pid), .TERM) catch |e| switch (e) {
        error.ProcessNotFound => {
            // Already dead; just clean up state.
            _ = m.remove(game.f95_thread_id);
            state.setLaunchMsg("Game already exited.");
            return;
        },
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Stop failed: {s}", .{@errorName(e)}) catch "Stop failed";
            state.setLaunchMsg(msg);
            return;
        },
    };
    _ = m.remove(game.f95_thread_id);
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "SIGTERM sent to pid {d}", .{pid}) catch "Stopped";
    state.setLaunchMsg(msg);
}

/// Each guiFrame: prune entries whose pid has exited. Uses
/// `waitpid(pid, WNOHANG)` instead of `kill(pid, 0)` because the
/// launched game is f69's child — once it exits it becomes a
/// zombie, and `kill(zombie, 0)` returns success (zombies "exist"
/// until reaped). `waitpid(WNOHANG)` both detects the exit AND
/// reaps the zombie in a single non-blocking call.
pub fn drainRunningGames(frame: *Frame) void {
    if (frame.state.running_games == null) return;
    const m = runningGamesMap(frame);

    var doomed: std.ArrayList(struct { tid: u64, status: u32, pid: i32 }) = .empty;
    defer doomed.deinit(frame.lib.alloc);
    var it = m.iterator();
    while (it.next()) |entry| {
        const pid: std.c.pid_t = @intCast(entry.value_ptr.*);
        // libc waitpid(WNOHANG) returns:
        //   >0  → child exited; we just reaped it.
        //    0  → child still running.
        //   -1  → ECHILD (not our child / already reaped). Treat as
        //         exited so the stale entry doesn't pin the UI.
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
        if (rc != 0) {
            log.info("running game pid={d} (tid={d}) exited (waitpid rc={d}, status=0x{x}) — clearing entry", .{
                pid, entry.key_ptr.*, rc, status,
            });
            doomed.append(frame.lib.alloc, .{
                .tid = entry.key_ptr.*,
                .status = @bitCast(status),
                .pid = pid,
            }) catch break;
        }
    }
    for (doomed.items) |d| {
        _ = m.remove(d.tid);
        // Only surface a notification when the exit code is non-zero
        // (a clean exit means the user quit the game normally). The
        // ECHILD case (rc == -1) collapses into status = 0 here so
        // it stays silent too — those are stale entries, not crashes.
        notifyOnAbnormalExit(frame, d.tid, d.status);
    }
}

/// Decode `status` from waitpid and, if it indicates an abnormal
/// exit, push a toast pointing the user at the game and (when a
/// compat scan finds anything) at the Fix Compat button.
fn notifyOnAbnormalExit(frame: *Frame, thread_id: u64, status: u32) void {
    const W = std.posix.W;
    const exited = W.IFEXITED(status);
    const signaled = W.IFSIGNALED(status);
    if (exited and W.EXITSTATUS(status) == 0) return; // clean exit
    if (!exited and !signaled) return; // stopped / continued — not interesting here

    // Find the game name so the toast is intelligible. Fall back to
    // the thread id when the library hasn't been re-queried yet.
    const name = blk: {
        for (frame.games) |*g| if (g.f95_thread_id == thread_id) break :blk g.name;
        break :blk "(unknown game)";
    };

    // Run a compat scan against the game's newest install — if it
    // matches a recipe with `.unfixed` status we mention it inline
    // so the user knows there's something to click.
    var issue_count: usize = 0;
    if (frame.lib.latestInstallForGame(thread_id) catch null) |inst| {
        defer frame.lib.freeInstall(inst);
        if (scanCompatForInstall(frame, &inst.id, inst.install_path)) |issues| {
            defer freeCompatIssues(frame, issues);
            for (issues) |is| if (is.status == .unfixed) {
                issue_count += 1;
            };
        } else |_| {}
    }

    var buf: [320]u8 = undefined;
    const msg = if (exited)
        if (issue_count > 0)
            std.fmt.bufPrint(&buf, "{s}: crashed (exit {d}). {d} compat fix(es) available — click Fix Compat.", .{ name, W.EXITSTATUS(status), issue_count }) catch "Game crashed."
        else
            std.fmt.bufPrint(&buf, "{s}: exited with error (code {d}).", .{ name, W.EXITSTATUS(status) }) catch "Game exited with error."
    else
        std.fmt.bufPrint(&buf, "{s}: killed by signal.", .{name}) catch "Game killed by signal.";
    frame.state.notifyErr(msg);
}

pub fn freeRunningGames(state: *State, alloc: std.mem.Allocator) void {
    if (state.running_games) |map_ptr| {
        map_ptr.deinit();
        alloc.destroy(map_ptr);
        state.running_games = null;
    }
}

/// Called each guiFrame. For every `.done` job that we haven't already
/// handed off AND that has a real `game_id`, kick off an async worker
/// that SHA-verifies + extracts the archive into
/// `<library_root>/<game_id>/<version>/`. The actual heavy lifting
/// (gigabyte-sized 7z/zip extracts) lives on a detached thread so the
/// UI stays responsive. `.failed` jobs go straight to the next-source

// ============================================================
//  per-game backup saves — sandbox HOME → dated XDG_DATA_HOME copy
// ============================================================

/// Recursively copy the per-game sandbox HOME to
/// `<XDG_DATA_HOME>/f69/save-backups/<thread_id>/<YYYY-MM-DD-HHMMSS>/`.
/// Defends against the Round-18 footgun where deleting an install dir
/// also wipes the co-located sandbox HOME (Phase 7 installer will
/// decouple these — until then, periodic backups are the mitigation).
pub fn doBackupSaves(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    var home_buf: [640]u8 = undefined;
    const sandbox_home = std.fmt.bufPrint(&home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
        state.setLaunchMsg("Saves path buffer overflow.");
        return;
    };
    std.Io.Dir.cwd().access(frame.io, sandbox_home, .{}) catch {
        state.setLaunchMsg("No sandbox HOME yet — launch the game once to create it.");
        return;
    };

    // Backups live under data_root so they travel with the portable
    // f69 folder. `<data_root>/save-backups/<thread_id>/<unix-seconds>/`.
    const ts = backupTimestamp(frame.io);
    var dest_buf: [768]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/save-backups/{d}/{s}", .{ frame.info.data_root, game.f95_thread_id, ts }) catch {
        state.setLaunchMsg("Backup path buffer overflow.");
        return;
    };
    std.Io.Dir.cwd().createDirPath(frame.io, dest) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Backup mkdir failed: {s}", .{@errorName(e)}) catch "Backup mkdir failed";
        state.setLaunchMsg(msg);
        return;
    };

    copyTreePlain(alloc, frame.io, sandbox_home, dest) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Backup copy failed: {s}", .{@errorName(e)}) catch "Backup copy failed";
        state.setLaunchMsg(msg);
        return;
    };

    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Saves backed up to {s}", .{dest}) catch "Saves backed up";
    state.setLaunchMsg(ok_msg);
}

/// Pure-ish: produce a stable "YYYYMMDD-HHMMSS"-shaped string. Uses
/// the host clock; falls back to "unknown" if the clock read fails.
fn backupTimestamp(io: std.Io) [24]u8 {
    var out: [24]u8 = [_]u8{0} ** 24;
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    const secs = @divTrunc(ts.raw.toNanoseconds(), 1_000_000_000);
    _ = std.fmt.bufPrint(&out, "{d}", .{secs}) catch return out;
    return out;
}

/// Simple recursive copy: directories + files, preserves modes, no
/// symlink magic. Backup destinations are user-owned save scratch
/// dirs — a symlink in there would be unusual and copying through is
/// closer to "snapshot what's there now".
fn copyTreePlain(alloc: std.mem.Allocator, io: std.Io, src: []const u8, dest: []const u8) !void {
    var src_dir = try std.Io.Dir.cwd().openDir(io, src, .{ .access_sub_paths = true, .iterate = true });
    defer src_dir.close(io);
    try std.Io.Dir.cwd().createDirPath(io, dest);

    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        var dst_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dest, entry.path }) catch return error.PathTooLong;
        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src, entry.path }) catch return error.PathTooLong;

        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, dest_path),
            .file => try copyOneFile(io, src_path, dest_path),
            else => {},
        }
    }
}

fn copyOneFile(io: std.Io, src: []const u8, dest: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);
    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer out.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    while (true) {
        // readSliceShort aliases its source if the destination is the
        // reader's own backing buffer — keep them distinct.
        const got = in_reader.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        try out_writer.interface.writeAll(chunk[0..got]);
    }
    try out_writer.interface.flush();
    const st = in.stat(io) catch return;
    try out.setPermissions(io, st.permissions);
}


pub fn doOpenGameFolder(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Honour the detail-page install picker. If the user has picked a
    // specific install in the dropdown, open *that* install's dir
    // rather than always the latest — matches how Launch resolves.
    var fallback_buf: [640]u8 = undefined;
    const installs_owned: ?[]library.Install = frame.lib.listInstalls(game.f95_thread_id) catch null;
    defer if (installs_owned) |list| frame.lib.freeInstalls(list);
    const picked: ?*const library.Install = blk: {
        const list = installs_owned orelse break :blk null;
        if (list.len == 0) break :blk null;
        if (state.detail_picker_install_id) |sel| {
            for (list) |*inst| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) break :blk inst;
            }
        }
        break :blk &list[0];
    };
    const target: []const u8 = if (picked) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Open folder: path buffer overflow.");
            return;
        };

    std.Io.Dir.cwd().access(frame.io, target, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "No install at {s}. Download the game first.", .{target}) catch "No install dir";
        state.setLaunchMsg(msg);
        return;
    };

    spawnXdgOpen(alloc, frame.io, target) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Open folder failed: {s}", .{@errorName(e)}) catch "Open folder failed";
        state.setLaunchMsg(msg);
        return;
    };
    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Opened {s}", .{target}) catch "Opened folder";
    state.setLaunchMsg(ok_msg);
}

pub fn doOpenSaves(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    var sandbox_home_buf: [640]u8 = undefined;
    const sandbox_home = std.fmt.bufPrint(&sandbox_home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
        state.setConvertMsg("Saves path buffer overflow.");
        return;
    };

    // Recipe-pinned save paths were retired — the `saves` block on
    // GameRecipe is gone. Engine-derived defaults (Ren'Py:
    // `$XDG_DATA_HOME/RenPy/...`; RPGM: `<install>/www/save/`) will
    // land later. For now we fall back to the sandbox HOME itself
    // so the user can navigate manually. `game` stays in scope for
    // the future engine-derive path.
    const target = sandbox_home;
    std.Io.Dir.cwd().createDirPath(frame.io, target) catch {}; // best-effort

    // Spawn xdg-open detached so the UI doesn't block on the file
    // manager startup.
    spawnXdgOpen(alloc, frame.io, target) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Open saves failed: {s}", .{@errorName(e)}) catch "Open saves failed";
        state.setConvertMsg(msg);
        return;
    };

    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Opened {s}", .{target}) catch "Opened saves";
    state.setConvertMsg(ok_msg);
}

/// Pure. Expand `$HOME` and `$XDG_DATA_HOME` in the recipe's saves
/// template against the per-game sandbox HOME. Allocator-owned result.
pub fn expandSavesPath(alloc: std.mem.Allocator, tmpl: []const u8, sandbox_home: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < tmpl.len) {
        if (std.mem.startsWith(u8, tmpl[i..], "$XDG_DATA_HOME")) {
            try out.appendSlice(alloc, sandbox_home);
            try out.appendSlice(alloc, "/.local/share");
            i += "$XDG_DATA_HOME".len;
        } else if (std.mem.startsWith(u8, tmpl[i..], "$HOME")) {
            try out.appendSlice(alloc, sandbox_home);
            i += "$HOME".len;
        } else {
            try out.append(alloc, tmpl[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn spawnXdgOpen(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const path_owned = try alloc.dupe(u8, path);
    // The reaper thread takes ownership of `path_owned` + the child
    // handle; UI thread returns immediately without blocking on
    // xdg-open's exit. Without this the f69 main thread sat on
    // `child.wait` for the few ms xdg-open lives, and the launched
    // file manager / browser appeared as f69's child in `ps`.
    const ReaperArgs = struct { io: std.Io, alloc: std.mem.Allocator, path: []u8 };
    const args_ptr = alloc.create(ReaperArgs) catch {
        alloc.free(path_owned);
        return error.OutOfMemory;
    };
    args_ptr.* = .{ .io = io, .alloc = alloc, .path = path_owned };

    const ReaperFn = struct {
        fn run(a: *ReaperArgs) void {
            defer a.alloc.free(a.path);
            defer a.alloc.destroy(a);
            var child = std.process.spawn(a.io, .{
                .argv = &.{ "xdg-open", a.path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch return;
            _ = child.wait(a.io) catch {};
        }
    };
    const thr = std.Thread.spawn(.{}, ReaperFn.run, .{args_ptr}) catch |e| {
        alloc.free(args_ptr.path);
        alloc.destroy(args_ptr);
        return e;
    };
    thr.detach();
}

const testing = std.testing;

test "expandSavesPath: $HOME substitution" {
    const got = try expandSavesPath(testing.allocator, "$HOME/.renpy/save", "/games/14014/.f69-home");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/games/14014/.f69-home/.renpy/save", got);
}

test "expandSavesPath: $XDG_DATA_HOME substitution" {
    const got = try expandSavesPath(testing.allocator, "$XDG_DATA_HOME/RenPy/SummertimeSaga-1454697768", "/games/14014/.f69-home");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/games/14014/.f69-home/.local/share/RenPy/SummertimeSaga-1454697768", got);
}

test "expandSavesPath: literal path passes through" {
    const got = try expandSavesPath(testing.allocator, "/abs/path", "/sandbox");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/abs/path", got);
}

test "expandSavesPath: $XDG_DATA_HOME takes precedence over $HOME prefix" {
    // Both markers start with `$`; the longer one must win at any
    // given position.
    const got = try expandSavesPath(testing.allocator, "$XDG_DATA_HOME/x", "/sb");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/sb/.local/share/x", got);
}

