// f69 — Zig + dvui rewrite of XLibrary, F95Zone-only.
//
// Layout: bounded contexts under src/<context>/. Each context exposes its
// public API through `<context>/<context>.zig`. Module names registered
// here (`library`, `recipe`, ...) match the public file names so call
// sites do `@import("library")` etc.
//
// dvui is opt-in via `-Dgui=true`. Skeleton compiles without it; once
// `zig fetch --save git+https://github.com/david-vanderson/dvui#main`
// has run, build with `-Dgui=true` to actually link the GUI.
//
// See docs/PLAN.md for the master plan and decisions.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----- root-level modules -----

    const config_mod = mod(b, "config", "src/config.zig", target, optimize);

    // Build-time options surface — version string read from build.zig.zon
    // is currently the only entry. UI's Diagnostics screen imports this
    // to show "f69 vX.Y.Z" so bug reports identify the build.
    const app_version: []const u8 = "0.9.0";
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", app_version);
    const build_opts_mod = build_opts.createModule();

    // ----- util modules -----

    const util_paths_mod = mod(b, "util_paths", "src/util/paths.zig", target, optimize);
    const util_kahn_mod = mod(b, "util_kahn", "src/util/kahn.zig", target, optimize);
    // zqlite (karlseguin/zqlite.zig) bundles a static sqlite3 — no system
    // sqlite3 dependency needed. Module name in dvui's pkg cache: "zqlite".
    const zqlite_dep = b.dependency("zqlite", .{ .target = target, .optimize = optimize });
    const util_db_mod = mod(b, "util_db", "src/util/db.zig", target, optimize);
    util_db_mod.addImport("zqlite", zqlite_dep.module("zqlite"));
    const util_crash_mod = mod(b, "util_crash", "src/util/crash.zig", target, optimize);
    const util_version_mod = mod(b, "util_version", "src/util/version.zig", target, optimize);
    const util_renpy_mod = mod(b, "util_renpy", "src/util/renpy.zig", target, optimize);
    const util_atomic_io_mod = mod(b, "util_atomic_io", "src/util/atomic_io.zig", target, optimize);
    const util_domain_mod = mod(b, "util_domain", "src/util/domain.zig", target, optimize);

    // util_archive: thin Zig wrapper around libarchive's read API.
    // Used by downloads/archive.zig for the formats stdlib doesn't
    // cover (.7z, .tar.bz2, .tar.xz, .rar). libarchive itself is the
    // static archive from `pkgs.libarchive-static` in flake.nix —
    // includes bz2 + xz + zlib decompression bundled in.
    const util_archive_mod = b.addModule("util_archive", .{
        .root_source_file = b.path("src/util/archive.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    util_archive_mod.linkSystemLibrary("archive", .{ .preferred_link_mode = .static });
    // libarchive's static .a references undefined symbols from
    // libz / libbz2 / liblzma. Stock nixpkgs ships those as shared
    // libs only; dynamic-link them here. Side effect: the f69 binary
    // depends on libz.so / libbz2.so / liblzma.so at runtime — every
    // mainstream desktop already has them. A "truly static
    // everything" build needs static-overrides for these three
    // (similar to dav1d-static); deferred until the Windows port
    // forces the issue.
    util_archive_mod.linkSystemLibrary("z", .{});
    util_archive_mod.linkSystemLibrary("bz2", .{});
    util_archive_mod.linkSystemLibrary("lzma", .{});

    // util_file_picker: Zig binding around vendored NFDe
    // (`zig-pkg/nfde/`). Wayland-correct file picker via XDG portal
    // on Linux; native dialogs on Windows + macOS. Per-platform
    // backend file + system libraries wired below.
    const file_picker_mod = b.addModule("util_file_picker", .{
        .root_source_file = b.path("src/util/file_picker.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // C++17 backends (portal.cpp, win.cpp); the Cocoa backend is
        // an Objective-C file but still needs libcpp linked for the
        // shared NFDe helpers when targeting macOS.
        .link_libcpp = true,
    });
    file_picker_mod.addIncludePath(b.path("zig-pkg/nfde/src/include"));
    switch (target.result.os.tag) {
        .linux => {
            file_picker_mod.addCSourceFile(.{
                .file = b.path("zig-pkg/nfde/src/nfd_portal.cpp"),
                .flags = &.{ "-std=c++17", "-DNFD_PORTAL=1" },
            });
            // libdbus-1 for the portal D-Bus dance. Provided by
            // `pkgs.dbus.dev` in the flake; runtime resolves the
            // .so from the desktop session.
            file_picker_mod.linkSystemLibrary("dbus-1", .{});
        },
        .windows => {
            file_picker_mod.addCSourceFile(.{
                .file = b.path("zig-pkg/nfde/src/nfd_win.cpp"),
                .flags = &.{"-std=c++17"},
            });
            file_picker_mod.linkSystemLibrary("ole32", .{});
            file_picker_mod.linkSystemLibrary("uuid", .{});
            file_picker_mod.linkSystemLibrary("shell32", .{});
        },
        .macos => {
            file_picker_mod.addCSourceFile(.{
                .file = b.path("zig-pkg/nfde/src/nfd_cocoa.m"),
                .flags = &.{"-fobjc-arc"},
            });
            file_picker_mod.linkFramework("AppKit", .{});
            file_picker_mod.linkFramework("UniformTypeIdentifiers", .{});
        },
        else => {},
    }

    // ----- bounded contexts -----

    const library_mod = mod(b, "library", "src/library/library.zig", target, optimize);
    library_mod.addImport("util_db", util_db_mod);
    library_mod.addImport("util_version", util_version_mod);
    library_mod.addImport("util_domain", util_domain_mod);

    const recipe_mod = mod(b, "recipe", "src/recipe/recipe.zig", target, optimize);
    recipe_mod.addImport("util_version", util_version_mod);
    recipe_mod.addImport("util_atomic_io", util_atomic_io_mod);
    recipe_mod.addImport("util_domain", util_domain_mod);

    const resolver_mod = mod(b, "resolver", "src/resolver/resolver.zig", target, optimize);
    resolver_mod.addImport("recipe", recipe_mod);
    resolver_mod.addImport("util_kahn", util_kahn_mod);
    resolver_mod.addImport("util_version", util_version_mod);

    const f95_mod_ = mod(b, "f95", "src/f95/f95.zig", target, optimize);
    f95_mod_.addImport("util_atomic_io", util_atomic_io_mod);
    f95_mod_.addImport("build_options", build_opts_mod);

    // Image decoding context. Wraps libavif so the sync worker can
    // transcode F95Zone CDN's AVIF screenshots to RGBA and re-encode
    // them as PNG at write time. libavif and its dav1d backend are
    // statically linked (see flake.nix overlays libavif-static /
    // dav1d-static) — the resulting f69 binary doesn't depend on
    // either .so at run time. PNG/JPEG/GIF stay on dvui's stb_image.
    const image_mod = b.addModule("image", .{
        .root_source_file = b.path("src/image/image.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    image_mod.linkSystemLibrary("avif", .{ .preferred_link_mode = .static });
    image_mod.linkSystemLibrary("dav1d", .{ .preferred_link_mode = .static });

    const downloads_mod = mod(b, "downloads", "src/downloads/downloads.zig", target, optimize);
    downloads_mod.addImport("recipe", recipe_mod);
    downloads_mod.addImport("util_version", util_version_mod);
    downloads_mod.addImport("util_archive", util_archive_mod);
    downloads_mod.addImport("util_atomic_io", util_atomic_io_mod);
    downloads_mod.addImport("build_options", build_opts_mod);

    const installer_mod = mod(b, "installer", "src/installer/installer.zig", target, optimize);
    installer_mod.addImport("library", library_mod);
    installer_mod.addImport("recipe", recipe_mod);
    installer_mod.addImport("resolver", resolver_mod);
    installer_mod.addImport("downloads", downloads_mod);
    installer_mod.addImport("util_archive", util_archive_mod);
    installer_mod.addImport("util_atomic_io", util_atomic_io_mod);

    // Importers — read F95Checker SQLite + xLibrary JSON config files
    // and translate to library.Game shape. Settings UI invokes these.
    const importers_mod = mod(b, "importers", "src/importers/importers.zig", target, optimize);
    importers_mod.addImport("util_db", util_db_mod);

    const convert_mod = mod(b, "convert", "src/convert/convert.zig", target, optimize);
    convert_mod.addImport("util_renpy", util_renpy_mod);
    convert_mod.addImport("util_atomic_io", util_atomic_io_mod);
    convert_mod.addImport("util_domain", util_domain_mod);
    convert_mod.addImport("build_options", build_opts_mod);

    const compat_mod = mod(b, "compat", "src/compat/compat.zig", target, optimize);
    compat_mod.addImport("util_version", util_version_mod);
    compat_mod.addImport("util_renpy", util_renpy_mod);
    compat_mod.addImport("util_domain", util_domain_mod);

    const sandbox_mod = mod(b, "sandbox", "src/sandbox/sandbox.zig", target, optimize);
    sandbox_mod.addImport("library", library_mod);
    sandbox_mod.addImport("util_paths", util_paths_mod);
    sandbox_mod.addImport("util_domain", util_domain_mod);

    const server_mod = mod(b, "server", "src/server/server.zig", target, optimize);
    server_mod.addImport("library", library_mod);

    const ui_mod = mod(b, "ui", "src/ui/ui.zig", target, optimize);
    ui_mod.addImport("library", library_mod);
    ui_mod.addImport("recipe", recipe_mod);
    ui_mod.addImport("resolver", resolver_mod);
    ui_mod.addImport("f95", f95_mod_);
    ui_mod.addImport("downloads", downloads_mod);
    ui_mod.addImport("sandbox", sandbox_mod);
    ui_mod.addImport("convert", convert_mod);
    ui_mod.addImport("compat", compat_mod);
    ui_mod.addImport("installer", installer_mod);
    ui_mod.addImport("importers", importers_mod);
    ui_mod.addImport("image", image_mod);
    ui_mod.addImport("util_version", util_version_mod);
    ui_mod.addImport("util_file_picker", file_picker_mod);
    ui_mod.addImport("util_atomic_io", util_atomic_io_mod);
    ui_mod.addImport("build_options", build_opts_mod);

    // ----- executable -----
    //
    // Note: an `app` orchestrator module was sketched here but had
    // dangling-pointer issues (locals captured into a returned struct).
    // Removed in the round-9 review pass; phase-2+ orchestration will
    // need a heap-allocated `App` instead.

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("config", config_mod);
    exe_mod.addImport("library", library_mod);
    exe_mod.addImport("f95", f95_mod_);
    exe_mod.addImport("downloads", downloads_mod);
    exe_mod.addImport("recipe", recipe_mod);
    exe_mod.addImport("sandbox", sandbox_mod);
    exe_mod.addImport("convert", convert_mod);
    exe_mod.addImport("compat", compat_mod);
    exe_mod.addImport("ui", ui_mod);
    exe_mod.addImport("util_crash", util_crash_mod);

    // dvui — opt-in. After `zig fetch --save git+…/dvui`, build with
    // `-Dgui=true` to link the SDL3 backend.
    // dvui is now integral to the UI; default `-Dgui=true`. Pass
    // `-Dgui=false` for headless / CI builds that only need the non-UI
    // modules to compile.
    const enable_gui = b.option(bool, "gui", "Link dvui (default true)") orelse true;
    // Pass `-Dbackend=sdl3gpu` to dvui so it only builds the SDL3 GPU
    // backend; without this it builds all backends and the resulting
    // module names collide ("file exists in modules 'dvui' and 'dvui0'").
    const dvui_dep_opt: ?*std.Build.Dependency = if (enable_gui)
        b.dependency("dvui", .{
            .target = target,
            .optimize = optimize,
            .backend = @as([]const u8, "sdl3gpu"),
        })
    else
        null;
    if (dvui_dep_opt) |dep| {
        ui_mod.addImport("dvui", dep.module("dvui_sdl3gpu"));
        ui_mod.addImport("sdl3gpu-backend", dep.module("sdl3"));
        exe_mod.addImport("dvui", dep.module("dvui_sdl3gpu"));
    }

    const exe = b.addExecutable(.{
        .name = "f69",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Compat resources — directories the compat module's recipes
    // resolve at runtime. Each one is a Nix-built lib bundle landed
    // under `<install>/bin/data/compat-resources/<id>/`. The flake's
    // shellHook exports F69_COMPAT_<NAME> env vars pointing at the
    // built derivations; `zig build run` consumes them. Non-Nix
    // builds will see the env var unset and ship without the
    // bundle — the runtime detector still fires, the apply step
    // then reports `ResourceNotMaterialized` instead of silently
    // doing the wrong thing.
    installCompatResource(b, "renpy7-fhs-libs", "F69_COMPAT_RENPY7_FHS_LIBS");
    installCompatResource(b, "renpy8-fhs-libs", "F69_COMPAT_RENPY8_FHS_LIBS");
    installCompatResource(b, "rpgm-mv-fhs-libs", "F69_COMPAT_RPGM_MV_FHS_LIBS");
    installCompatResource(b, "unity-fhs-libs", "F69_COMPAT_UNITY_FHS_LIBS");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ----- spikes (throwaway PoCs — phase-0 risk validation) -----

    addSpike(b, target, optimize, "spike-bwrap", "spikes/spike-01-bwrap.zig",
        "Run spike 01: bwrap a sandbox launcher (NixOS/Debian/Arch/Fedora)");
    addSpike(b, target, optimize, "spike-flat-copy", "spikes/spike-02-flat-copy.zig",
        "Run spike 02: flat-copy a mod over a base game with file tracker");
    addSpike(b, target, optimize, "spike-renpy-convert", "spikes/spike-03-renpy-convert.zig",
        "Run spike 03: detect Ren'Py version + copy SDK libs + generate launcher");

    // spike-05 needs the downloads module (aria2_rpc.Daemon).
    {
        const spike5_mod = b.createModule(.{
            .root_source_file = b.path("spikes/spike-05-aria2-rpc.zig"),
            .target = target,
            .optimize = optimize,
        });
        spike5_mod.addImport("downloads", downloads_mod);
        const spike5_exe = b.addExecutable(.{
            .name = "spike-aria2-rpc",
            .root_module = spike5_mod,
        });
        const spike5_run = b.addRunArtifact(spike5_exe);
        if (b.args) |args| spike5_run.addArgs(args);
        const spike5_step = b.step("spike-aria2-rpc", "Run spike 05: aria2c JSON-RPC client smoke test");
        spike5_step.dependOn(&spike5_run.step);
    }

    // spike-06 exercises the real sandbox/linux_bwrap.zig code path.
    {
        const spike6_mod = b.createModule(.{
            .root_source_file = b.path("spikes/spike-06-sandbox.zig"),
            .target = target,
            .optimize = optimize,
        });
        spike6_mod.addImport("sandbox", sandbox_mod);
        const spike6_exe = b.addExecutable(.{
            .name = "spike-sandbox",
            .root_module = spike6_mod,
        });
        const spike6_run = b.addRunArtifact(spike6_exe);
        if (b.args) |args| spike6_run.addArgs(args);
        const spike6_step = b.step("spike-sandbox", "Run spike 06: launch a dummy script through the real bwrap backend");
        spike6_step.dependOn(&spike6_run.step);
    }

    // spike-04 needs dvui, only built when -Dgui=true. Reuses dvui_dep_opt.
    if (dvui_dep_opt) |dep| {
        const spike4_mod = b.createModule(.{
            .root_source_file = b.path("spikes/spike-04-dvui-busy-screen.zig"),
            .target = target,
            .optimize = optimize,
        });
        spike4_mod.addImport("dvui", dep.module("dvui_sdl3gpu"));
        spike4_mod.addImport("sdl3gpu-backend", dep.module("sdl3"));
        const spike4_exe = b.addExecutable(.{ .name = "spike-dvui", .root_module = spike4_mod });
        const spike4_run = b.addRunArtifact(spike4_exe);
        if (b.args) |args| spike4_run.addArgs(args);
        const spike4_step = b.step("spike-dvui", "Run spike 04: dvui busy-screen scale test (requires -Dgui=true)");
        spike4_step.dependOn(&spike4_run.step);
    }

    // ----- tests: every module's `test {}` blocks -----

    const test_targets = [_]*std.Build.Module{
        exe_mod,
        library_mod,       recipe_mod,        resolver_mod,    f95_mod_,
        downloads_mod,     installer_mod,     convert_mod,     sandbox_mod,
        server_mod,        ui_mod,            config_mod,      image_mod,
        importers_mod,     compat_mod,
        util_paths_mod,    util_kahn_mod,     util_db_mod,
        util_crash_mod,    util_version_mod,
        util_renpy_mod,    util_atomic_io_mod, util_domain_mod,
        file_picker_mod,   util_archive_mod,
    };
    const test_step = b.step("test", "Run unit tests");
    for (test_targets) |m| {
        const tests = b.addTest(.{ .root_module = m });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}

fn mod(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.addModule(name, .{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

/// Install a compat resource directory into the `<install>/bin/data/
/// compat-resources/<id>/` tree. Reads the absolute source path from
/// `env_var`; no-ops cleanly when the env var is unset (non-Nix
/// build, or the dev shell wasn't sourced).
fn installCompatResource(b: *std.Build, id: []const u8, env_var: []const u8) void {
    const src = b.graph.environ_map.get(env_var) orelse return;
    const subdir = std.fmt.allocPrint(b.allocator, "bin/data/compat-resources/{s}", .{id}) catch return;
    const step = b.addInstallDirectory(.{
        .source_dir = .{ .cwd_relative = src },
        .install_dir = .{ .custom = subdir },
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&step.step);
}

fn addSpike(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step_name: []const u8,
    src_path: []const u8,
    desc: []const u8,
) void {
    const spike_mod = b.createModule(.{
        .root_source_file = b.path(src_path),
        .target = target,
        .optimize = optimize,
    });
    const spike_exe = b.addExecutable(.{
        .name = step_name,
        .root_module = spike_mod,
    });
    const run = b.addRunArtifact(spike_exe);
    if (b.args) |args| run.addArgs(args);
    const step = b.step(step_name, desc);
    step.dependOn(&run.step);
}
