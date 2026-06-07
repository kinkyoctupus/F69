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
    // Default to a portable baseline CPU (x86_64_v1 / equivalent) so
    // CI/release builds run on ANY x86-64 host. Without this, a bare
    // `zig build` resolves to the *build machine's* native CPU model +
    // features — the binary then SIGILLs ("Illegal instruction") on
    // user CPUs lacking those features. Dev can opt back into native
    // codegen with `-Dcpu=native`; `-Dtarget=` also still overrides.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{});

    // ----- root-level modules -----

    const config_mod = mod(b, "config", "src/config.zig", target, optimize);

    // Build-time options surface — version string is currently the only
    // entry. UI's Diagnostics screen and main.zig's `--version` CLI flag
    // import this to show "f69 vX.Y.Z" so bug reports identify the build.
    // Keep in sync with `.version` in build.zig.zon.
    const app_version: []const u8 = "0.9.1";
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
    const util_http_mod = mod(b, "util_http", "src/util/http.zig", target, optimize);
    util_http_mod.addImport("build_options", build_opts_mod);
    const util_proc_mod = mod(b, "util_proc", "src/util/proc.zig", target, optimize);
    const util_setting_mod = mod(b, "util_setting", "src/util/setting.zig", target, optimize);
    const util_test_env_mod = mod(b, "util_test_env", "src/util/test_env.zig", target, optimize);
    // Tests-only fixture. Every module whose test block hand-rolled a
    // tmpdir pre-R11 follow-up now imports `util_test_env` for the
    // shared `TestEnv`. Imports are no-ops at runtime — the type is
    // only referenced inside `test {}` blocks, which the release build
    // drops.
    util_atomic_io_mod.addImport("util_test_env", util_test_env_mod);

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
    // libarchive.a references undefined symbols from a fan of helper
    // libraries — every feature enabled at libarchive build time
    // (and Debian/Fedora/Nix all enable the full set) adds another
    // unresolved dep here. Dynamic-link them so the f69 binary picks
    // them up from the desktop's standard libs at runtime. A "truly
    // static everything" build would need static overrides for each
    // (similar to dav1d-static); deferred until the Windows port
    // forces the issue.
    util_archive_mod.linkSystemLibrary("z", .{});      // gzip
    // bzip2's SONAME splits across distros — libbz2.so.1.0 on
    // Debian/Ubuntu (and the GH-Actions release builder), libbz2.so.1
    // on Fedora/Bazzite. A dynamic link bakes the build-host soname
    // into DT_NEEDED, so the slim bundle (no bundled libs) fails to
    // load on the *other* family. Static-link it instead — the f69
    // binary then carries no libbz2 dependency at all. Needs libbz2.a:
    // Debian/Fedora -dev packages ship it; nix uses `bzip2-static`.
    util_archive_mod.linkSystemLibrary("bz2", .{ .preferred_link_mode = .static }); // bzip2
    util_archive_mod.linkSystemLibrary("lzma", .{});   // xz
    util_archive_mod.linkSystemLibrary("zstd", .{});   // zstd in .7z/.zip
    util_archive_mod.linkSystemLibrary("lz4", .{});    // lz4 filter
    util_archive_mod.linkSystemLibrary("nettle", .{}); // AES / SHA / HMAC
    util_archive_mod.linkSystemLibrary("xml2", .{});   // .xar metadata
    util_archive_mod.linkSystemLibrary("acl", .{});    // POSIX ACL restore

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

    // F95Indexer cache API client — peer of f95_mod_. Auth-free, lives
    // outside `f95/` because it doesn't touch the forum session.
    const f95_indexer_mod = mod(b, "f95_indexer", "src/f95_indexer/f95_indexer.zig", target, optimize);
    f95_indexer_mod.addImport("util_http", util_http_mod);
    f95_indexer_mod.addImport("library", library_mod);
    f95_indexer_mod.addImport("build_options", build_opts_mod);

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
    downloads_mod.addImport("util_http", util_http_mod);
    downloads_mod.addImport("util_proc", util_proc_mod);
    downloads_mod.addImport("util_test_env", util_test_env_mod);
    downloads_mod.addImport("build_options", build_opts_mod);

    const installer_mod = mod(b, "installer", "src/installer/installer.zig", target, optimize);
    installer_mod.addImport("library", library_mod);
    installer_mod.addImport("recipe", recipe_mod);
    installer_mod.addImport("resolver", resolver_mod);
    installer_mod.addImport("downloads", downloads_mod);
    installer_mod.addImport("util_archive", util_archive_mod);
    installer_mod.addImport("util_atomic_io", util_atomic_io_mod);
    installer_mod.addImport("util_proc", util_proc_mod);
    installer_mod.addImport("util_test_env", util_test_env_mod);

    // Importers — read F95Checker SQLite + xLibrary JSON config files
    // and translate to library.Game shape. Settings UI invokes these.
    const importers_mod = mod(b, "importers", "src/importers/importers.zig", target, optimize);
    importers_mod.addImport("util_db", util_db_mod);
    importers_mod.addImport("util_domain", util_domain_mod);
    importers_mod.addImport("util_test_env", util_test_env_mod);

    const convert_mod = mod(b, "convert", "src/convert/convert.zig", target, optimize);
    convert_mod.addImport("util_renpy", util_renpy_mod);
    convert_mod.addImport("util_atomic_io", util_atomic_io_mod);
    convert_mod.addImport("util_domain", util_domain_mod);
    convert_mod.addImport("util_http", util_http_mod);
    convert_mod.addImport("util_proc", util_proc_mod);
    convert_mod.addImport("util_test_env", util_test_env_mod);
    convert_mod.addImport("build_options", build_opts_mod);

    const compat_mod = mod(b, "compat", "src/compat/compat.zig", target, optimize);
    compat_mod.addImport("util_version", util_version_mod);
    compat_mod.addImport("util_renpy", util_renpy_mod);
    compat_mod.addImport("util_domain", util_domain_mod);
    compat_mod.addImport("util_test_env", util_test_env_mod);

    const sandbox_mod = mod(b, "sandbox", "src/sandbox/sandbox.zig", target, optimize);
    sandbox_mod.addImport("library", library_mod);
    sandbox_mod.addImport("util_paths", util_paths_mod);
    sandbox_mod.addImport("util_domain", util_domain_mod);
    sandbox_mod.addImport("util_proc", util_proc_mod);

    const server_mod = mod(b, "server", "src/server/server.zig", target, optimize);
    server_mod.addImport("library", library_mod);

    const ui_mod = mod(b, "ui", "src/ui/ui.zig", target, optimize);
    ui_mod.addImport("library", library_mod);
    ui_mod.addImport("recipe", recipe_mod);
    ui_mod.addImport("resolver", resolver_mod);
    ui_mod.addImport("f95", f95_mod_);
    ui_mod.addImport("f95_indexer", f95_indexer_mod);
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
    exe_mod.addImport("f95_indexer", f95_indexer_mod);
    exe_mod.addImport("downloads", downloads_mod);
    exe_mod.addImport("recipe", recipe_mod);
    exe_mod.addImport("sandbox", sandbox_mod);
    exe_mod.addImport("convert", convert_mod);
    exe_mod.addImport("compat", compat_mod);
    exe_mod.addImport("ui", ui_mod);
    exe_mod.addImport("util_crash", util_crash_mod);
    exe_mod.addImport("util_setting", util_setting_mod);
    exe_mod.addImport("build_options", build_opts_mod);

    // dvui — opt-in. After `zig fetch --save git+…/dvui`, build with
    // `-Dgui=true` to link the SDL3 backend.
    // dvui is now integral to the UI; default `-Dgui=true`. Pass
    // `-Dgui=false` for headless / CI builds that only need the non-UI
    // modules to compile.
    const enable_gui = b.option(bool, "gui", "Link dvui (default true)") orelse true;
    // Install data trees (mkxp-z bundle + compat resources) under
    // `<prefix>/share/f69/data/` instead of the default
    // `<prefix>/bin/data/`. Set this when packaging for a Linux distro
    // that follows FHS — putting 50 MB of Ruby stdlib under /usr/bin
    // makes rpm/dpkg's shebang-mangler walk the bundle and rewrite
    // `/usr/bin/env ruby` to `/usr/bin/ruby`, breaking the embedded
    // mkxp-z runtime. Portable builds keep the default.
    const fhs_layout = b.option(bool, "fhs-layout", "Install data under share/f69/data/ (FHS) instead of bin/data/ (portable)") orelse false;
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
    // Emit a GNU build-ID note (`.note.gnu.build-id`). Fedora's
    // rpmbuild + Debian's debian-policy require this for every
    // installed ELF — otherwise `find-debuginfo` aborts the .rpm
    // build with "No build ID note found". `.sha1` is deterministic
    // over the binary content (same input → same id), good for
    // crash-dump symbol matching.
    exe.build_id = .sha1;
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
    const data_prefix: []const u8 = if (fhs_layout) "share/f69/data" else "bin/data";
    installCompatResource(b, "renpy7-fhs-libs", "F69_COMPAT_RENPY7_FHS_LIBS", data_prefix);
    installCompatResource(b, "renpy8-fhs-libs", "F69_COMPAT_RENPY8_FHS_LIBS", data_prefix);
    installCompatResource(b, "rpgm-mv-fhs-libs", "F69_COMPAT_RPGM_MV_FHS_LIBS", data_prefix);
    installCompatResource(b, "mkxp-z-fhs-libs", "F69_COMPAT_MKXP_Z_FHS_LIBS", data_prefix);
    installCompatResource(b, "unity-fhs-libs", "F69_COMPAT_UNITY_FHS_LIBS", data_prefix);

    // Vendored mkxp-z (RGSS reimplementation — runs RPGM XP/VX/VX Ace
    // games natively on Linux). Source tree is checked into
    // `third_party/mkxp-z/linux-x86_64/` per its README.md; we copy it
    // verbatim into the install tree. Linux x86_64 only — the convert
    // dispatch in `src/convert/rpgm.zig` no-ops on other targets.
    if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) {
        const mkxp_subdir = std.fmt.allocPrint(b.allocator, "{s}/mkxp-z", .{data_prefix}) catch @panic("OOM");
        const mkxp_install = b.addInstallDirectory(.{
            .source_dir = b.path("third_party/mkxp-z/linux-x86_64"),
            .install_dir = .{ .custom = mkxp_subdir },
            .install_subdir = "",
        });
        b.getInstallStep().dependOn(&mkxp_install.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);



    // ----- distribution targets -----
    //
    // Each named step is a custom Step.MakeFn callback that runs at
    // `zig build <step>` time with full std.fs / std.process access. No
    // shell scripts anywhere — manifest text is in DIST_TEMPLATES below,
    // ldd parsing + patchelf invocation is in the makePortable helper.
    //
    // Outputs (all relative to repo root):
    //   portable      → zig-out/bin/         binary + bundled libs + run.sh
    //   portable-slim → zig-out/portable-slim/  binary + run.sh + DEPS.md
    //   aur           → zig-out/aur/PKGBUILD    Arch source manifest
    //   deb           → zig-out/debian/         Debian source manifest
    //   rpm           → zig-out/rpm/f69.spec    Fedora/RHEL spec
    //   flake         → no fs output — invokes `nix flake check`
    //
    // The portable steps re-invoke `zig build install -Doptimize=ReleaseSafe`
    // as a sub-build so they always operate on a ReleaseSafe binary
    // regardless of the user's -Doptimize flag for the outer invocation.
    const version = readVersion(b) catch "0.0.0";

    // Container builds (aur/deb/rpm → real .pkg/.deb/.rpm via podman/docker)
    // are OPT-IN. Default is manifest-only — fast, reliable, no container
    // engine required. Pass `-Dcontainer-build=true` to actually invoke
    // the target distro's packaging tool inside a container.
    //
    // Why opt-in: each distro's static-libarchive / glibc / linker setup
    // diverges from the build host's, so the container path needs
    // per-distro polish (currently only AUR is fully working). Treating
    // it as opt-in keeps `zig build packages` quick and reliable, and
    // lets devs iterate on container packaging when they're shipping.
    const enable_container = b.option(bool, "container-build", "Invoke podman/docker for aur/deb/rpm — currently only AUR is fully working") orelse false;

    const packages_step = b.step("packages", "Build every distribution target");

    inline for (.{
        .{ .kind = DistKind.aur,   .name = "aur",   .desc = "Generate Arch PKGBUILD (zig-out/aur/) — add -Dcontainer-build=true to also build .pkg.tar.zst" },
        .{ .kind = DistKind.deb,   .name = "deb",   .desc = "Generate Debian source pkg (zig-out/debian/) — container build incomplete" },
        .{ .kind = DistKind.rpm,   .name = "rpm",   .desc = "Generate RPM spec (zig-out/rpm/) — container build untested" },
        .{ .kind = DistKind.flake, .name = "flake", .desc = "Sanity-check flake.nix (nix flake check)" },
    }) |t| {
        const dist = DistStep.create(b, t.kind, version, enable_container);
        const named = b.step(t.name, t.desc);
        named.dependOn(&dist.step);
        packages_step.dependOn(&dist.step);
    }

    // Portable (full + slim) both need a ReleaseSafe binary on disk
    // BEFORE the bundling pass runs. Wire each as: sub-build → bundle.
    // has_side_effects suppresses cache for the sub-build because it
    // writes into the same zig-out/bin/ the outer step post-processes.
    inline for (.{
        .{ .kind = DistKind.portable_full, .name = "portable",      .desc = "Portable bundle with libs (zig-out/bin/)" },
        .{ .kind = DistKind.portable_slim, .name = "portable-slim", .desc = "Portable bundle WITHOUT libs (zig-out/portable-slim/)" },
    }) |t| {
        const sub_build = b.addSystemCommand(&.{"zig"});
        sub_build.addArgs(&.{ "build", "install", "-Doptimize=ReleaseSafe", "-Dgui=true" });
        sub_build.has_side_effects = true;

        const dist = DistStep.create(b, t.kind, version, enable_container);
        dist.step.dependOn(&sub_build.step);

        const named = b.step(t.name, t.desc);
        named.dependOn(&dist.step);
        packages_step.dependOn(&dist.step);
    }

    // ----- prefetch nwjs SDKs -----
    //
    // Populates `zig-out/bin/data/cache/convert/sdks/nwjs-<v>/` with
    // tarballs from dl.nwjs.io. The runtime sdk_cache walks the same
    // path, so any cached version is consumed without a network round
    // trip when Convert runs. Intended use: `zig build prefetch-nwjs
    // -Dnwjs-versions="0.29.4,0.44.6,0.83.0"` before `zig build
    // portable`, so the resulting portable bundle ships with the SDKs
    // pre-extracted.
    //
    // No default version list — each tarball is ~200 MiB extracted,
    // shipping all 50 entries in chromeToNwjs would be 7+ GiB and
    // surprise users. Force them to opt in by spelling out the set
    // they care about.
    const nwjs_versions_csv = b.option(
        []const u8,
        "nwjs-versions",
        "Comma-separated list of nwjs versions (e.g. \"0.29.4,0.44.6,0.83.0\") for prefetch-nwjs.",
    ) orelse "";
    const prefetch_step = b.step("prefetch-nwjs", "Download nwjs SDKs into the portable cache (see -Dnwjs-versions=…)");
    const prefetch_helper = PrefetchNwjsStep.create(b, nwjs_versions_csv);
    prefetch_step.dependOn(&prefetch_helper.step);

    // ----- tests: every module's `test {}` blocks -----

    // Pure UI logic modules (no dvui) — fast standalone tests.
    const ui_tokens_mod = mod(b, "ui_tokens", "src/ui/tokens.zig", target, optimize);
    const ui_sortx_mod = mod(b, "ui_sortx", "src/ui/sortx.zig", target, optimize);
    const ui_columns_mod = mod(b, "ui_columns", "src/ui/columns.zig", target, optimize);
    const util_argv_mod = mod(b, "util_argv", "src/util/argv.zig", target, optimize);
    const util_reltime_mod = mod(b, "util_reltime", "src/util/reltime.zig", target, optimize);

    // Theme-driven dvui component layer (Design B). Imports dvui (gui builds) + tokens.
    const ui_comp_mod = mod(b, "ui_comp", "src/ui/comp.zig", target, optimize);
    ui_comp_mod.addImport("ui_tokens", ui_tokens_mod);
    if (dvui_dep_opt) |dep| ui_comp_mod.addImport("dvui", dep.module("dvui_sdl3gpu"));
    // The main UI module uses the runtime theme too (consoleTheme).
    ui_mod.addImport("ui_tokens", ui_tokens_mod);
    ui_mod.addImport("util_argv", util_argv_mod);

    // Theme persistence module — used by both main (load at startup) and the
    // settings screen (save on change).
    const ui_theme_store_mod = mod(b, "ui_theme_store", "src/ui/theme_store.zig", target, optimize);
    ui_theme_store_mod.addImport("ui_tokens", ui_tokens_mod);
    ui_theme_store_mod.addImport("util_atomic_io", util_atomic_io_mod);
    ui_mod.addImport("ui_theme_store", ui_theme_store_mod);
    exe_mod.addImport("ui_theme_store", ui_theme_store_mod);

    const test_targets = [_]*std.Build.Module{
        exe_mod,           ui_tokens_mod,     ui_sortx_mod,     ui_columns_mod,  util_argv_mod,
        util_reltime_mod,  ui_comp_mod,
        library_mod,       recipe_mod,        resolver_mod,    f95_mod_,
        f95_indexer_mod,
        downloads_mod,     installer_mod,     convert_mod,     sandbox_mod,
        server_mod,        ui_mod,            config_mod,      image_mod,
        importers_mod,     compat_mod,
        util_paths_mod,    util_kahn_mod,     util_db_mod,
        util_crash_mod,    util_version_mod,
        util_renpy_mod,    util_atomic_io_mod, util_domain_mod,
        util_http_mod,     util_proc_mod,      util_setting_mod,
        util_test_env_mod,
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
fn installCompatResource(b: *std.Build, id: []const u8, env_var: []const u8, data_prefix: []const u8) void {
    const src = b.graph.environ_map.get(env_var) orelse return;
    const subdir = std.fmt.allocPrint(b.allocator, "{s}/compat-resources/{s}", .{ data_prefix, id }) catch return;
    const step = b.addInstallDirectory(.{
        .source_dir = .{ .cwd_relative = src },
        .install_dir = .{ .custom = subdir },
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&step.step);
}

// ============================================================
//  Distribution targets — pure-Zig Step.MakeFn callbacks.
//
//  Everything below runs at `zig build <step>` time. No shell scripts,
//  no auxiliary tool binary. The custom-step pattern: each DistStep
//  owns a std.Build.Step whose makeFn is `DistStep.make`, which uses
//  `@fieldParentPtr` to recover the wrapping struct and dispatch on
//  `kind`. Templates live at the bottom of this file as multiline
//  string literals.
// ============================================================

const DistKind = enum {
    aur,
    deb,
    rpm,
    portable_full,
    portable_slim,
    flake,
};

const DistStep = struct {
    step: std.Build.Step,
    kind: DistKind,
    version: []const u8,
    /// User passed `-Dcontainer-build=true`. When false, aur/deb/rpm
    /// only emit the manifest; the container build is skipped.
    enable_container: bool,

    fn create(b: *std.Build, kind: DistKind, version: []const u8, enable_container: bool) *DistStep {
        const self = b.allocator.create(DistStep) catch @panic("OOM");
        const name = b.fmt("dist-{s}", .{@tagName(kind)});
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = name,
                .owner = b,
                .makeFn = make,
            }),
            .kind = kind,
            .version = version,
            .enable_container = enable_container,
        };
        return self;
    }

    fn make(step: *std.Build.Step, opts: std.Build.Step.MakeOptions) anyerror!void {
        _ = opts;
        const self: *DistStep = @fieldParentPtr("step", step);
        const b = step.owner;
        switch (self.kind) {
            .aur => try makeAur(b, self.version, self.enable_container),
            .deb => try makeDeb(b, self.version, self.enable_container),
            .rpm => try makeRpm(b, self.version, self.enable_container),
            .portable_full => try makePortable(b, .full),
            .portable_slim => try makePortable(b, .slim),
            .flake => try makeFlake(b),
        }
    }
};

/// `zig build prefetch-nwjs` step. Downloads nwjs SDK tarballs into
/// the runtime cache location (`zig-out/bin/data/cache/convert/sdks/
/// nwjs-<v>/`) so a subsequent `zig build portable` ships them
/// pre-extracted. Idempotent — already-cached versions are skipped.
const PrefetchNwjsStep = struct {
    step: std.Build.Step,
    versions_csv: []const u8,

    fn create(b: *std.Build, versions_csv: []const u8) *PrefetchNwjsStep {
        const self = b.allocator.create(PrefetchNwjsStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "prefetch-nwjs",
                .owner = b,
                .makeFn = make,
            }),
            .versions_csv = versions_csv,
        };
        return self;
    }

    fn make(step: *std.Build.Step, opts: std.Build.Step.MakeOptions) anyerror!void {
        _ = opts;
        const self: *PrefetchNwjsStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const csv = std.mem.trim(u8, self.versions_csv, " \t,");
        if (csv.len == 0) {
            std.log.err(
                "prefetch-nwjs: pass -Dnwjs-versions=\"0.29.4,0.44.6,…\" (no default — each tarball is ~200 MiB)",
                .{},
            );
            return error.NoVersionsRequested;
        }
        try prefetchNwjs(b, csv);
    }
};

/// Per-version: skip if `zig-out/bin/data/cache/convert/sdks/nwjs-<v>/`
/// exists; otherwise curl the tarball to a temp path, tar-extract into
/// the dest with `--strip-components=1` (the upstream tarball wraps
/// everything in `nwjs-v<v>-linux-x64/`). Stays best-effort: a single
/// failing version logs a warning and the loop continues — partial
/// caches are still useful.
fn prefetchNwjs(b: *std.Build, versions_csv: []const u8) !void {
    const alloc = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();

    const cache_root = "zig-out/bin/data/cache/convert/sdks";
    try cwd.createDirPath(io, cache_root);

    var ok: u32 = 0;
    var skipped: u32 = 0;
    var failed: u32 = 0;

    var it = std.mem.tokenizeAny(u8, versions_csv, ", \t\n");
    while (it.next()) |raw_ver| {
        const ver = std.mem.trim(u8, raw_ver, " \t");
        if (ver.len == 0) continue;

        const dest = try std.fmt.allocPrint(alloc, "{s}/nwjs-{s}", .{ cache_root, ver });
        defer alloc.free(dest);

        // Idempotency probe — any file inside is enough; the tarball
        // always contains many.
        const probe = try std.fmt.allocPrint(alloc, "{s}/credits.html", .{dest});
        defer alloc.free(probe);
        if (cwd.access(io, probe, .{})) |_| {
            std.log.info("prefetch-nwjs: nwjs-{s} already cached, skipping", .{ver});
            skipped += 1;
            continue;
        } else |_| {}

        const url = try std.fmt.allocPrint(
            alloc,
            "https://dl.nwjs.io/v{s}/nwjs-v{s}-linux-x64.tar.gz",
            .{ ver, ver },
        );
        defer alloc.free(url);

        const tar_path = try std.fmt.allocPrint(alloc, "{s}.tar.gz", .{dest});
        defer alloc.free(tar_path);
        defer cwd.deleteFile(io, tar_path) catch {};

        std.log.info("prefetch-nwjs: downloading {s}", .{url});
        runQuiet(b, &.{ "curl", "-fL", "--retry", "3", "-o", tar_path, url }) catch |e| {
            std.log.warn("prefetch-nwjs: nwjs-{s} download failed: {s}", .{ ver, @errorName(e) });
            failed += 1;
            continue;
        };

        try cwd.createDirPath(io, dest);
        runQuiet(b, &.{
            "tar", "-xzf", tar_path,
            "-C",  dest,
            "--strip-components=1",
        }) catch |e| {
            std.log.warn("prefetch-nwjs: nwjs-{s} extract failed: {s}", .{ ver, @errorName(e) });
            // Half-extracted dir is worse than nothing — wipe it so
            // the next run retries cleanly.
            cwd.deleteTree(io, dest) catch {};
            failed += 1;
            continue;
        };

        std.log.info("prefetch-nwjs: nwjs-{s} cached at {s}", .{ ver, dest });
        ok += 1;
    }

    std.log.info("prefetch-nwjs: {d} cached, {d} already-present, {d} failed", .{ ok, skipped, failed });
}

const PortableMode = enum { full, slim };

/// Parse `version = "X.Y.Z"` out of build.zig.zon at build-script start.
/// One source of truth — bump version in the .zon and every package
/// manifest tracks it.
fn readVersion(b: *std.Build) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var buf: [16 * 1024]u8 = undefined;
    const text = try cwd.readFile(b.graph.io, "build.zig.zon", &buf);
    const needle = ".version = \"";
    const start = std.mem.indexOf(u8, text, needle) orelse return error.NoVersionInZon;
    const rest = text[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.NoVersionInZon;
    return try b.allocator.dupe(u8, rest[0..end]);
}

/// Write `content` to `path`, creating parent dirs as needed.
/// `executable=true` sets +x on the resulting file (for run.sh, debian/rules).
fn writeFileEnsureDir(b: *std.Build, path: []const u8, content: []const u8, executable: bool) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(b.graph.io, dir);
    const perms: std.Io.File.Permissions = if (executable) .executable_file else .default_file;
    try cwd.writeFile(b.graph.io, .{
        .sub_path = path,
        .data = content,
        .flags = .{ .permissions = perms },
    });
}

// ----- AUR ----------------------------------------------------------

fn makeAur(b: *std.Build, version: []const u8, enable_container: bool) !void {
    const pkgbuild = try std.fmt.allocPrint(b.allocator, PKGBUILD_TEMPLATE, .{version});
    defer b.allocator.free(pkgbuild);
    try writeFileEnsureDir(b, "zig-out/aur/PKGBUILD", pkgbuild, false);
    try writeFileEnsureDir(b, "zig-out/aur/README.txt", AUR_README, false);
    std.log.info("aur: wrote zig-out/aur/ (version {s})", .{version});
    if (enable_container) try buildInContainer(b, .aur, version);
}

// ----- Debian -------------------------------------------------------

fn makeDeb(b: *std.Build, version: []const u8, enable_container: bool) !void {
    const alloc = b.allocator;
    // RFC2822 date for debian/changelog. Subprocess `date -R` is fine
    // (date is in every base install) and avoids manual TZ formatting.
    const date = try runCapture(b, &.{ "date", "-R" });
    defer alloc.free(date);
    const date_trimmed = std.mem.trim(u8, date, " \n\r\t");

    const control = try std.fmt.allocPrint(alloc, DEBIAN_CONTROL, .{});
    defer alloc.free(control);
    try writeFileEnsureDir(b, "zig-out/debian/control", control, false);
    try writeFileEnsureDir(b, "zig-out/debian/rules", DEBIAN_RULES, true);

    const changelog = try std.fmt.allocPrint(alloc, DEBIAN_CHANGELOG, .{ version, date_trimmed });
    defer alloc.free(changelog);
    try writeFileEnsureDir(b, "zig-out/debian/changelog", changelog, false);
    // No debian/compat — `debhelper-compat (= 13)` in control supersedes it.
    try writeFileEnsureDir(b, "zig-out/debian/source/format", "3.0 (quilt)\n", false);
    try writeFileEnsureDir(b, "zig-out/debian/README.txt", DEBIAN_README, false);
    std.log.info("deb: wrote zig-out/debian/ (version {s})", .{version});
    if (enable_container) try buildInContainer(b, .deb, version);
}

// ----- RPM ----------------------------------------------------------

fn makeRpm(b: *std.Build, version: []const u8, enable_container: bool) !void {
    const alloc = b.allocator;
    const date = try runCapture(b, &.{ "date", "+%a %b %d %Y" });
    defer alloc.free(date);
    const date_trimmed = std.mem.trim(u8, date, " \n\r\t");

    const spec = try std.fmt.allocPrint(alloc, RPM_SPEC, .{ version, date_trimmed, version });
    defer alloc.free(spec);
    try writeFileEnsureDir(b, "zig-out/rpm/f69.spec", spec, false);
    try writeFileEnsureDir(b, "zig-out/rpm/README.txt", RPM_README, false);
    std.log.info("rpm: wrote zig-out/rpm/f69.spec (version {s})", .{version});
    if (enable_container) try buildInContainer(b, .rpm, version);
}

// ----- Nix flake ----------------------------------------------------

fn makeFlake(b: *std.Build) !void {
    // Try `nix flake check --no-build` if nix is on PATH; otherwise
    // print consumer hints. Either way doesn't fail the build.
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "nix", "flake", "check", "--no-build" },
    }) catch {
        std.log.info("flake: nix not on PATH — skipping `nix flake check`", .{});
        std.log.info("flake: consumers use `nix build .#f69` (see README.md)", .{});
        return;
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.warn("flake: nix flake check exited {d}\n{s}", .{ code, result.stderr });
            return;
        },
        else => {
            std.log.warn("flake: nix flake check terminated abnormally", .{});
            return;
        },
    }
    std.log.info("flake: ok — consumers use `nix build .#f69`", .{});
}

// ----- Portable bundle (full + slim) --------------------------------
//
// Full mode: bundle binary + every transitive .so + display libs + ld-linux,
// patchelf RUNPATHs to $ORIGIN, write run.sh that execs the bundled loader.
// Output: zig-out/bin/ (binary written there by the sub-build).
//
// Slim mode: copy binary to zig-out/portable-slim/, write run.sh + DEPS.md.
// User installs deps via their distro package manager.

fn makePortable(b: *std.Build, mode: PortableMode) !void {
    const alloc = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const bin_src = "zig-out/bin/f69";
    cwd.access(io, bin_src, .{}) catch {
        std.log.err("portable: {s} not found — run `zig build install -Doptimize=ReleaseSafe -Dgui=true` first", .{bin_src});
        return error.BinaryMissing;
    };

    const dist_dir = if (mode == .full) "zig-out/bin" else "zig-out/portable-slim";
    const lib_dir = try std.fmt.allocPrint(alloc, "{s}/lib", .{dist_dir});
    defer alloc.free(lib_dir);
    const run_sh_path = try std.fmt.allocPrint(alloc, "{s}/run.sh", .{dist_dir});
    defer alloc.free(run_sh_path);

    if (mode == .slim) {
        cwd.deleteTree(io, dist_dir) catch {};
        try cwd.createDirPath(io, dist_dir);
        const dst_bin = try std.fmt.allocPrint(alloc, "{s}/f69", .{dist_dir});
        defer alloc.free(dst_bin);
        try cwd.copyFile(bin_src, cwd, dst_bin, io, .{
            .permissions = .executable_file,
            .make_path = false,
            .replace = true,
        });
        try writeFileEnsureDir(b, run_sh_path, RUN_SH_SLIM, true);
        const deps_path = try std.fmt.allocPrint(alloc, "{s}/DEPS.md", .{dist_dir});
        defer alloc.free(deps_path);
        try writeFileEnsureDir(b, deps_path, DEPS_MD, false);
        std.log.info("portable-slim: wrote {s}/ (deps in DEPS.md)", .{dist_dir});
        return;
    }

    // Full mode below. DIST is zig-out/bin which also contains the
    // freshly-built binary — surgical cleanup, not nuke.
    cwd.deleteTree(io, lib_dir) catch {};
    cwd.deleteFile(io, run_sh_path) catch {};
    try cwd.createDirPath(io, lib_dir);

    // Step 1: ldd the binary, copy each resolved .so into lib/.
    var bundled = std.StringHashMap(void).init(alloc);
    defer bundled.deinit();
    var ld_linux: ?[]const u8 = null;
    {
        const ldd_out = try runCapture(b, &.{ "ldd", bin_src });
        defer alloc.free(ldd_out);
        var it = std.mem.tokenizeAny(u8, ldd_out, "\n");
        while (it.next()) |line| {
            const path = parseLddLine(line) orelse continue;
            const base = std.fs.path.basename(path);
            if (skipGpuVendor(base)) continue;
            try copyResolveSymlink(b, path, lib_dir);
            try bundled.put(try alloc.dupe(u8, base), {});
            if (std.mem.startsWith(u8, base, "ld-linux")) {
                ld_linux = try alloc.dupe(u8, base);
            }
        }
    }
    // PT_INTERP fallback: ask patchelf if ldd missed it.
    if (ld_linux == null) {
        const interp = try runCapture(b, &.{ "patchelf", "--print-interpreter", bin_src });
        defer alloc.free(interp);
        const trimmed = std.mem.trim(u8, interp, " \n\r\t");
        try copyResolveSymlink(b, trimmed, lib_dir);
        ld_linux = try alloc.dupe(u8, std.fs.path.basename(trimmed));
    }

    // Step 2: display + Vulkan-loader libs that SDL3 dlopens at runtime.
    // ldd doesn't see these. We grab them from $LD_LIBRARY_PATH on the
    // build host (set by direnv on NixOS, or the global ld.so cache on
    // other distros) and recurse via ldd for their transitives.
    const ld_path = b.graph.environ_map.get("LD_LIBRARY_PATH") orelse "";
    for (DLOPEN_LIBS) |libname| {
        const found = findInLdPath(b, libname, ld_path) catch null;
        if (found) |path| {
            defer alloc.free(path);
            try copyWithTransitives(b, path, lib_dir, &bundled);
        } else {
            std.log.info("portable: skip {s} — not on build-host LD_LIBRARY_PATH", .{libname});
        }
    }

    // Step 2b: bundle aria2c (the download daemon). Spawned as a
    // subprocess at runtime; without bundling, the portable bundle's
    // download path breaks on hosts that don't have it on $PATH.
    // Slim mode skips this — DEPS.md tells the user to install it.
    {
        const aria2_dst = try std.fmt.allocPrint(alloc, "{s}/aria2c", .{dist_dir});
        defer alloc.free(aria2_dst);
        if (locateOnPath(b, "aria2c") catch null) |aria2_src| {
            defer alloc.free(aria2_src);
            const real = try cwd.realPathFileAlloc(io, aria2_src, alloc);
            defer alloc.free(real);
            try cwd.copyFile(real, cwd, aria2_dst, io, .{
                .permissions = .executable_file,
                .make_path = false,
                .replace = true,
            });
            // ldd aria2c, pick up any .so deps not already bundled
            // through the main binary. copyWithTransitives recurses
            // and skips duplicates via the `bundled` set.
            const ldd_out = try runCapture(b, &.{ "ldd", aria2_dst });
            defer alloc.free(ldd_out);
            var aria_ldd_it = std.mem.tokenizeAny(u8, ldd_out, "\n");
            while (aria_ldd_it.next()) |line| {
                const path = parseLddLine(line) orelse continue;
                try copyWithTransitives(b, path, lib_dir, &bundled);
            }
            // RUNPATH $ORIGIN/lib so the bundled aria2c finds its
            // .so deps next to the main binary's lib/ dir.
            runQuiet(b, &.{ "patchelf", "--set-rpath", "$ORIGIN/lib", aria2_dst }) catch {};
            std.log.info("portable: bundled aria2c from {s}", .{aria2_src});
        } else {
            // Best-effort: don't fail the bundle if aria2c isn't
            // installed on the build host. The bundle still ships;
            // downloads just won't work without aria2c on the
            // runtime host's $PATH.
            cwd.deleteFile(io, aria2_dst) catch {};
            std.log.warn("portable: aria2c not on $PATH — bundle won't auto-download. Install it on the build host (`nix profile add nixpkgs#aria2`) and re-run `zig build portable`.", .{});
        }
    }

    // Step 3: patchelf RUNPATHs. Binary gets $ORIGIN/lib; each bundled
    // .so gets $ORIGIN. The loader itself doesn't use RUNPATH, so skip.
    try runQuiet(b, &.{ "patchelf", "--set-rpath", "$ORIGIN/lib", bin_src });
    var dir = try cwd.openDir(io, lib_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = dir.iterate();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "ld-linux")) continue;
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ lib_dir, entry.name });
        defer alloc.free(full);
        runQuiet(b, &.{ "patchelf", "--set-rpath", "$ORIGIN", full }) catch {};
    }

    // Step 4: launcher.
    try writeFileEnsureDir(b, run_sh_path, RUN_SH_FULL, true);

    // Step 5: project-root convenience launcher. A thin delegator so
    // `./run.sh` from the repo root just execs the bundle's launcher.
    // Single source of truth for env / ICD / data-dir setup stays in
    // `zig-out/bin/run.sh`; the root one only knows how to find it.
    try writeFileEnsureDir(b, "run.sh", RUN_SH_ROOT_DELEGATOR, true);

    std.log.info("portable: wrote {s}/ ({} files in lib/, loader={s}); plus ./run.sh delegator", .{ dist_dir, bundled.count(), ld_linux orelse "?" });
}

// ----- portable helpers ---------------------------------------------

/// Spawn `argv[0]` with `argv[1..]`, return stdout (UTF-8). Caller owns
/// the returned slice. Errors on non-zero exit code.
fn runCapture(b: *std.Build, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(b.allocator, b.graph.io, .{ .argv = argv });
    b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) {
            b.allocator.free(result.stdout);
            return error.NonZeroExit;
        },
        else => {
            b.allocator.free(result.stdout);
            return error.AbnormalTermination;
        },
    }
    return result.stdout;
}

/// Spawn `argv`, discard stdout/stderr. Best-effort — caller decides
/// whether to swallow the error (patchelf sometimes fails on .so files
/// it considers malformed; we want non-fatal).
fn runQuiet(b: *std.Build, argv: []const []const u8) !void {
    const result = try std.process.run(b.allocator, b.graph.io, .{ .argv = argv });
    b.allocator.free(result.stdout);
    b.allocator.free(result.stderr);
}

/// Parse one line of `ldd` output. Returns the resolved absolute path
/// for entries like `libfoo.so.1 => /path/to/libfoo.so.1 (0x...)` and
/// `/lib64/ld-linux-x86-64.so.2 (0x...)`. Skips vdso and unresolved.
fn parseLddLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOf(u8, trimmed, "linux-vdso") != null) return null;

    if (std.mem.indexOf(u8, trimmed, " => ")) |arrow| {
        const after = trimmed[arrow + 4 ..];
        if (!std.mem.startsWith(u8, after, "/")) return null; // "not found" or shared
        const paren = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
        return after[0..paren];
    }
    // PT_INTERP form: `/path/to/ld-linux-x86-64.so.2 (0x...)`
    if (std.mem.startsWith(u8, trimmed, "/")) {
        const paren = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        return trimmed[0..paren];
    }
    return null;
}

fn skipGpuVendor(base: []const u8) bool {
    // Vendor-suffixed backends (`libGLX_nvidia`, `libGLX_mesa`,
    // `libGLESv2_nvidia`, `libEGL_mesa`, …) MUST come from the host's
    // own NVIDIA / Mesa install at runtime — shipping them locks the
    // bundle to one driver version and one card vendor.
    //
    // Bare glvnd dispatchers (`libGL.so.1`, `libGLX.so.0`,
    // `libEGL.so.1`, `libGLdispatch.so.0`) are vendor-neutral and
    // SHIP because game binaries (Ren'Py / Unity / godot) link them
    // by SONAME and crash on NixOS hosts where the system loader
    // can't find them. We point the games at our bundled glvnd via
    // LD_LIBRARY_PATH at launch time.
    if (std.mem.startsWith(u8, base, "libGLX_")) return true;
    if (std.mem.startsWith(u8, base, "libGLESv1_CM_")) return true;
    if (std.mem.startsWith(u8, base, "libGLESv2_")) return true;
    if (std.mem.startsWith(u8, base, "libEGL_")) return true;
    return false;
}

fn copyResolveSymlink(b: *std.Build, src: []const u8, dst_dir: []const u8) !void {
    const alloc = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    // Resolve symlinks so we ship the real file's BYTES, but keep the
    // SRC's basename for the destination name. On NixOS,
    // /nix/store/.../libarchive.so.13 is a symlink to libarchive.so.13.8.6;
    // we want the FILE content but the loader's DT_NEEDED references
    // `libarchive.so.13` (the SONAME), so the destination must be
    // named after `src`, not `real`. Same story for ld-linux which is
    // also a symlink chain on NixOS.
    const real = try cwd.realPathFileAlloc(io, src, alloc);
    defer alloc.free(real);
    const base = std.fs.path.basename(src);
    const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dst_dir, base });
    defer alloc.free(dst);
    try cwd.copyFile(real, cwd, dst, io, .{
        .permissions = .executable_file,
        .make_path = false,
        .replace = true,
    });
}

/// Search the colon-separated `$PATH` for an executable named `name`.
/// Returns an owned path or null if not found. Used by the portable
/// step to locate aria2c (or other tools) on the build host.
fn locateOnPath(b: *std.Build, name: []const u8) !?[]u8 {
    const alloc = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const path_env = b.graph.environ_map.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        cwd.access(io, candidate, .{}) catch {
            alloc.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Search the colon-separated LD_LIBRARY_PATH for `name`. Returns an
/// owned path or null if not found.
fn findInLdPath(b: *std.Build, name: []const u8, ld_path: []const u8) !?[]u8 {
    if (ld_path.len == 0) return null;
    const alloc = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    var it = std.mem.tokenizeScalar(u8, ld_path, ':');
    while (it.next()) |dir| {
        const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        cwd.access(io, candidate, .{}) catch {
            alloc.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Copy `src` into `dst_dir/<basename(src)>`, then ldd it and recurse
/// for every non-GPU-vendor transitive that isn't already bundled.
fn copyWithTransitives(
    b: *std.Build,
    src: []const u8,
    dst_dir: []const u8,
    bundled: *std.StringHashMap(void),
) anyerror!void {
    const alloc = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const real = try cwd.realPathFileAlloc(io, src, alloc);
    defer alloc.free(real);
    // Use SRC's basename (the SONAME-style name the loader expects),
    // not REAL's (which on NixOS is often the unversioned filename
    // libfoo.so.X.Y.Z that nobody links against). Same bug as in
    // copyResolveSymlink above — symlink chain meets DT_NEEDED mismatch.
    const base_dup = try alloc.dupe(u8, std.fs.path.basename(src));
    if (skipGpuVendor(base_dup)) {
        alloc.free(base_dup);
        return;
    }
    if (bundled.contains(base_dup)) {
        alloc.free(base_dup);
        return;
    }
    const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dst_dir, base_dup });
    defer alloc.free(dst);
    try cwd.copyFile(real, cwd, dst, io, .{
        .permissions = .executable_file,
        .make_path = false,
        .replace = true,
    });
    try bundled.put(base_dup, {});

    // Walk transitives. ldd of a .so resolves against the build host's
    // RUNPATHs / LD_LIBRARY_PATH — exactly what we want.
    const ldd_out = runCapture(b, &.{ "ldd", real }) catch return;
    defer alloc.free(ldd_out);
    var it = std.mem.tokenizeAny(u8, ldd_out, "\n");
    while (it.next()) |line| {
        const dep = parseLddLine(line) orelse continue;
        try copyWithTransitives(b, dep, dst_dir, bundled);
    }
}

// ----- container builds (aur/deb/rpm → real package via podman/docker) -----
//
// After writing each distro's manifest, optionally spin up a container
// of the target distro, stage a clean source tarball + the manifest,
// and run the distro's native packaging tool. Output lands in
// zig-out/<distro>/out/ alongside the manifest.
//
// Graceful skip when no engine is available: the manifest itself is
// still useful (downstream packagers consume it), so we never abort
// the build on container failure.
//
// Engine preference: podman first (rootless ownership maps cleanly),
// docker second (works but writes root-owned files unless the script
// chowns them back; we do that).

const Distro = enum { aur, deb, rpm };

fn buildInContainer(b: *std.Build, distro: Distro, version: []const u8) !void {
    const engine = findContainerEngine(b) orelse {
        std.log.info("{s}: no podman/docker on PATH — manifest only (no .{s} built)", .{
            @tagName(distro),
            switch (distro) { .aur => "pkg.tar.zst", .deb => "deb", .rpm => "rpm" },
        });
        return;
    };

    // Stage a clean source tarball via `git archive`. Excludes
    // zig-cache, zig-out, dist, .git — the index only.
    const tarball_rel = try std.fmt.allocPrint(b.allocator, "f69-{s}.tar.gz", .{version});
    defer b.allocator.free(tarball_rel);

    const work_dir = try std.fmt.allocPrint(b.allocator, "zig-out/{s}/work", .{
        switch (distro) { .aur => "aur", .deb => "debian", .rpm => "rpm" },
    });
    defer b.allocator.free(work_dir);

    const cwd = std.Io.Dir.cwd();
    // `std.Io.Dir.deleteTree` AccessDenies on a directory we own when
    // a docker bind-mount left files inside that we don't quite have
    // the same UID for. Shell to `rm -rf` instead — works for every
    // ownership situation we'll hit.
    runQuiet(b, &.{ "rm", "-rf", work_dir }) catch {};
    try cwd.createDirPath(b.graph.io, work_dir);

    const tarball_path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ work_dir, tarball_rel });
    defer b.allocator.free(tarball_path);

    gitArchive(b, version, tarball_path) catch |e| {
        std.log.warn("{s}: git archive failed ({s}) — skipping container build", .{ @tagName(distro), @errorName(e) });
        return;
    };

    // Drop the per-distro build script into work/. Bind-mounting one
    // file is awkward across podman/docker quirks; easier to copy the
    // script into the work dir and bind-mount the whole dir.
    const script_body = switch (distro) {
        .aur => AUR_CONTAINER_SCRIPT,
        .deb => DEB_CONTAINER_SCRIPT,
        .rpm => RPM_CONTAINER_SCRIPT,
    };
    const script_path = try std.fmt.allocPrint(b.allocator, "{s}/build-in-container.sh", .{work_dir});
    defer b.allocator.free(script_path);
    try writeFileEnsureDir(b, script_path, script_body, true);

    // Each distro needs different files staged into work/ alongside
    // the tarball. For aur: copy PKGBUILD. For deb: nothing extra
    // (debian/ rides inside the tarball... no, wait — debian/ is in
    // zig-out/debian/, not in the source. Copy it in.). For rpm: copy
    // the .spec.
    try stageDistroFiles(b, distro, work_dir);

    const image = switch (distro) {
        .aur => "archlinux:latest",
        .deb => "debian:bookworm-slim",
        .rpm => "fedora:latest",
    };

    // Bind-mount work_dir at /work (read-write) inside the container.
    // The script runs there. Output also lands in /work — accessible
    // from the host at zig-out/<distro>/work/.
    const abs_work = try cwd.realPathFileAlloc(b.graph.io, work_dir, b.allocator);
    defer b.allocator.free(abs_work);
    const mount_arg = try std.fmt.allocPrint(b.allocator, "{s}:/work:rw,z", .{abs_work});
    defer b.allocator.free(mount_arg);

    const version_env = try std.fmt.allocPrint(b.allocator, "FVERSION={s}", .{version});
    defer b.allocator.free(version_env);

    // Pass host UID/GID into the container so the final chown maps the
    // root-owned build output back to the user who ran `zig build`.
    // Without this, docker writes root-owned files that the host user
    // can't `rm` next run. (Podman rootless wouldn't need this — but
    // we support both.)
    const host_uid = std.os.linux.getuid();
    const host_gid = std.os.linux.getgid();
    const uid_env = try std.fmt.allocPrint(b.allocator, "HOST_UID={d}", .{host_uid});
    defer b.allocator.free(uid_env);
    const gid_env = try std.fmt.allocPrint(b.allocator, "HOST_GID={d}", .{host_gid});
    defer b.allocator.free(gid_env);

    std.log.info("{s}: building inside {s} ({s})…", .{ @tagName(distro), image, engine });

    const argv = [_][]const u8{
        engine, "run", "--rm",
        "-v",   mount_arg,
        "-e",   version_env,
        "-e",   uid_env,
        "-e",   gid_env,
        "-w",   "/work",
        image,  "bash",
        "/work/build-in-container.sh",
    };
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &argv,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch |e| {
        std.log.warn("{s}: container invocation failed ({s}) — manifest only", .{ @tagName(distro), @errorName(e) });
        return;
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.warn("{s}: container exited {d} — manifest only", .{ @tagName(distro), code });
            std.log.warn("{s}: stderr tail:\n{s}", .{ @tagName(distro), tail(result.stderr, 8000) });
            return;
        },
        else => {
            std.log.warn("{s}: container terminated abnormally — manifest only", .{@tagName(distro)});
            return;
        },
    }

    // Move output package(s) from work/ to zig-out/<distro>/. Patterns:
    //   aur: *.pkg.tar.zst
    //   deb: *.deb
    //   rpm: *.rpm
    const out_pattern = switch (distro) {
        .aur => ".pkg.tar.zst",
        .deb => ".deb",
        .rpm => ".rpm",
    };
    const moved = try collectAndMove(b, work_dir, "dist", @tagName(distro), out_pattern);
    if (moved > 0) {
        std.log.info("{s}: built {d} package(s) into zig-out/{s}/", .{ @tagName(distro), moved, @tagName(distro) });
    } else {
        std.log.warn("{s}: container exited cleanly but produced no {s} files", .{ @tagName(distro), out_pattern });
    }
}

fn findContainerEngine(b: *std.Build) ?[]const u8 {
    const candidates = [_][]const u8{ "podman", "docker" };
    for (candidates) |engine| {
        const result = std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ engine, "--version" },
        }) catch continue;
        defer b.allocator.free(result.stdout);
        defer b.allocator.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) return engine;
    }
    return null;
}

/// Tarball the working tree (not git HEAD) into `out_path`, prefixed
/// with `f69-<version>/`. We use `tar` rather than `git archive` so
/// uncommitted local changes still package — important during dev
/// iteration where the user hasn't run `git commit` yet.
fn gitArchive(b: *std.Build, version: []const u8, out_path: []const u8) !void {
    const transform = try std.fmt.allocPrint(b.allocator, "s,^\\./,f69-{s}/,", .{version});
    defer b.allocator.free(transform);

    // Excludes: VCS dir, Zig caches, build outputs. `dist/` (legacy) is excluded — only zig-out/ is generated now
    // so we don't loop our own staging dir back into the tarball.
    const result = try std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{
            "tar", "-czf", out_path,
            "--exclude=./.git",
            "--exclude=./.zig-cache",
            "--exclude=./zig-out",
            "--exclude=./dist",
            "--exclude=./.direnv",
            "--transform", transform,
            ".",
        },
    });
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) {
            std.log.warn("tar archive stderr: {s}", .{result.stderr});
            return error.TarArchiveFailed;
        },
        else => return error.TarArchiveAbnormal,
    }
}

/// Copy the per-distro manifest files into work_dir so the container's
/// build script finds them via the /work bind mount. Each distro
/// expects a slightly different layout — encapsulated here.
fn stageDistroFiles(b: *std.Build, distro: Distro, work_dir: []const u8) !void {
    const alloc = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();

    const copyOne = struct {
        fn f(bb: *std.Build, src: []const u8, dst: []const u8) !void {
            try std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dst, bb.graph.io, .{
                .permissions = .default_file,
                .make_path = true,
                .replace = true,
            });
        }
    }.f;

    switch (distro) {
        .aur => {
            const dst = try std.fmt.allocPrint(alloc, "{s}/PKGBUILD", .{work_dir});
            defer alloc.free(dst);
            try copyOne(b, "zig-out/aur/PKGBUILD", dst);
        },
        .deb => {
            // Need every file under zig-out/debian/ except README.txt and
            // any prior `work/` (recursion). Re-walk the tree and copy.
            const debian_dst = try std.fmt.allocPrint(alloc, "{s}/debian", .{work_dir});
            defer alloc.free(debian_dst);
            try cwd.createDirPath(io, debian_dst);
            const files = [_][]const u8{ "control", "rules", "changelog" };
            for (files) |f| {
                const src = try std.fmt.allocPrint(alloc, "zig-out/debian/{s}", .{f});
                defer alloc.free(src);
                const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ debian_dst, f });
                defer alloc.free(dst);
                try copyOne(b, src, dst);
            }
            // rules must stay executable
            const rules_path = try std.fmt.allocPrint(alloc, "{s}/rules", .{debian_dst});
            defer alloc.free(rules_path);
            // Re-read rules content and rewrite with executable bit
            // (copyFile preserved 0644 from the source). Cheap.
            const rules_content = try cwd.readFileAlloc(io, "zig-out/debian/rules", alloc, .limited(64 * 1024));
            defer alloc.free(rules_content);
            try writeFileEnsureDir(b, rules_path, rules_content, true);
            // source/format
            const sf_dst = try std.fmt.allocPrint(alloc, "{s}/source/format", .{debian_dst});
            defer alloc.free(sf_dst);
            try writeFileEnsureDir(b, sf_dst, "3.0 (quilt)\n", false);
        },
        .rpm => {
            const dst = try std.fmt.allocPrint(alloc, "{s}/f69.spec", .{work_dir});
            defer alloc.free(dst);
            try copyOne(b, "zig-out/rpm/f69.spec", dst);
        },
    }
}

/// Walk `from_dir` for files matching the trailing `suffix` (e.g.
/// ".deb"), copy them into `to_root/<distro>/`. Returns the number of
/// matching files moved.
fn collectAndMove(b: *std.Build, from_dir: []const u8, to_root: []const u8, distro_name: []const u8, suffix: []const u8) !u32 {
    const alloc = b.allocator;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, from_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var moved: u32 = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const src = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ from_dir, entry.name });
        defer alloc.free(src);
        const dst = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ to_root, distro_name, entry.name });
        defer alloc.free(dst);
        try cwd.copyFile(src, cwd, dst, io, .{
            .permissions = .default_file,
            .make_path = true,
            .replace = true,
        });
        moved += 1;
    }
    return moved;
}

fn tail(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[s.len - max ..];
}

// ----- container build scripts ---------------------------------------

const AUR_CONTAINER_SCRIPT =
    \\#!/bin/bash
    \\set -euxo pipefail
    \\
    \\# Wipe stale build artifacts from previous runs. Container runs as
    \\# root and bind-mount may contain root-owned files the host user
    \\# can't `rm`. Preserve the freshly-staged tarball + manifest + this
    \\# script.
    \\find /work -mindepth 1 -maxdepth 1 \
    \\    ! -name 'f69-*.tar.gz' ! -name 'PKGBUILD' \
    \\    ! -name 'build-in-container.sh' \
    \\    -exec rm -rf {} +
    \\
    \\# Refresh pacman, install base-devel + both runtime + build deps.
    \\# makepkg checks both lists by default; skipping with --nodeps would
    \\# also work but installing them lets us run the binary in the
    \\# container if we ever want to smoke-test pre-package.
    \\pacman -Sy --noconfirm --needed base-devel sudo zig pkg-config \
    \\    wayland-protocols sqlite openssl dav1d libavif libarchive dbus \
    \\    vulkan-icd-loader wayland libxkbcommon libdecor libx11 libxext \
    \\    libxcursor libxi libxrandr
    \\
    \\# makepkg refuses to run as root. Make a build user that owns /work.
    \\useradd -m -s /bin/bash build
    \\chown -R build:build /work
    \\
    \\# Pass FVERSION through sudo (sudo strips env by default).
    \\sudo -u build FVERSION="$FVERSION" bash <<'EOSU'
    \\set -euxo pipefail
    \\cd /work
    \\# Patch PKGBUILD to use the local tarball we just staged (no AUR
    \\# fetch, no sha256 verify — local source we control).
    \\sed -i "s|^source=.*|source=(\"f69-${FVERSION}.tar.gz\")|" PKGBUILD
    \\sed -i "s|^sha256sums=.*|sha256sums=('SKIP')|" PKGBUILD
    \\makepkg --noconfirm -f --skipchecksums
    \\EOSU
    \\
    \\# Reassign ownership so the host user can rm/move files later.
    \\chown -R "${HOST_UID}:${HOST_GID}" /work
    \\
;

const DEB_CONTAINER_SCRIPT =
    \\#!/bin/bash
    \\set -euxo pipefail
    \\
    \\# Wipe stale build artifacts from previous runs.
    \\find /work -mindepth 1 -maxdepth 1 \
    \\    ! -name 'f69-*.tar.gz' ! -name 'debian' \
    \\    ! -name 'build-in-container.sh' \
    \\    -exec rm -rf {} +
    \\
    \\# Minimal apt env: don't prompt, don't recommend, don't suggest.
    \\export DEBIAN_FRONTEND=noninteractive
    \\apt-get update
    \\apt-get install -y --no-install-recommends \
    \\    build-essential debhelper devscripts \
    \\    pkg-config curl ca-certificates xz-utils \
    \\    libwayland-dev libxkbcommon-dev libdecor-0-dev \
    \\    libavif-dev libdav1d-dev libsqlite3-dev libssl-dev \
    \\    libarchive-dev libdbus-1-dev \
    \\    liblzma-dev libbz2-dev zlib1g-dev libxml2-dev
    \\
    \\# Zig isn't in Debian's apt yet — fetch the official 0.16 tarball.
    \\# Pin to whatever the project's flake.nix uses; bump as needed.
    \\ZIG_VER=0.16.0
    \\curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz" \
    \\    | tar -xJf - -C /usr/local
    \\export PATH="/usr/local/zig-x86_64-linux-${ZIG_VER}:$PATH"
    \\zig version
    \\
    \\# Extract our source tarball, drop the staged debian/ into it,
    \\# build with dpkg-buildpackage. Result lands in /work/.
    \\cd /work
    \\tar -xzf "f69-${FVERSION}.tar.gz"
    \\cp -r debian "f69-${FVERSION}/debian"
    \\cd "f69-${FVERSION}"
    \\# -d skips apt's check for Build-Depends. We install zig from
    \\# upstream tarball above (debian/sid has zig but bookworm doesn't),
    \\# so apt can't satisfy `Build-Depends: zig` from its index even
    \\# though the binary IS present and works. Published .deb sources
    \\# keep the dep listed so downstream packagers see it.
    \\dpkg-buildpackage -us -uc -b -d
    \\
    \\# `.deb` lands a level up.
    \\mv ../*.deb /work/
    \\
    \\# Hand ownership back to the host user.
    \\chown -R "${HOST_UID}:${HOST_GID}" /work
    \\
;

const RPM_CONTAINER_SCRIPT =
    \\#!/bin/bash
    \\set -euxo pipefail
    \\
    \\# Wipe stale build artifacts from previous runs.
    \\find /work -mindepth 1 -maxdepth 1 \
    \\    ! -name 'f69-*.tar.gz' ! -name 'f69.spec' \
    \\    ! -name 'build-in-container.sh' \
    \\    -exec rm -rf {} +
    \\
    \\dnf install -y rpm-build rpmdevtools zig pkgconfig \
    \\    wayland-devel libxkbcommon-devel libdecor-devel \
    \\    libavif-devel dav1d-devel sqlite-devel openssl-devel \
    \\    libarchive-devel dbus-devel
    \\
    \\# Set up the rpmbuild tree, stage tarball + spec, build.
    \\rpmdev-setuptree
    \\cp "/work/f69-${FVERSION}.tar.gz" ~/rpmbuild/SOURCES/
    \\cp /work/f69.spec ~/rpmbuild/SPECS/
    \\rpmbuild -bb ~/rpmbuild/SPECS/f69.spec
    \\
    \\# Copy result back into the bind mount.
    \\cp ~/rpmbuild/RPMS/x86_64/*.rpm /work/
    \\
    \\# Hand ownership back to the host user.
    \\chown -R "${HOST_UID}:${HOST_GID}" /work
    \\
;

// ----- dlopen lib list ----------------------------------------------

const DLOPEN_LIBS = [_][]const u8{
    // Wayland client surface
    "libwayland-client.so.0",
    "libwayland-cursor.so.0",
    "libwayland-egl.so.1",
    "libxkbcommon.so.0",
    "libdecor-0.so.0",
    // X11 client surface
    "libX11.so.6",
    "libX11-xcb.so.1",
    "libXext.so.6",
    "libXcursor.so.1",
    "libXi.so.6",
    "libXrandr.so.2",
    "libXfixes.so.3",
    "libXrender.so.1",
    "libxcb.so.1",
    // Vulkan loader (vendor-neutral). The actual GPU driver
    // (libGLX_nvidia / libvulkan_radeon / etc.) stays on the host.
    "libvulkan.so.1",
    // libglvnd entry points. f69 itself doesn't dlopen these (SDL3
    // is Vulkan-first for our GPU backend), but bundling them lets
    // the launch-time host-GPU fix point game binaries (Ren'Py /
    // Unity / godot) at the bundled glvnd so they don't blow up on
    // NixOS hosts where the system loader can't find these libs by
    // name. Vendor backends (libGLX_nvidia, libGLESv2_mesa, …)
    // still live on /run/opengl-driver/lib and aren't bundled.
    "libGL.so.1",
    "libGLX.so.0",
    "libEGL.so.1",
    "libGLdispatch.so.0",
};

// ============================================================
//  Templates — package manifests and launcher scripts.
//
//  Kept at the bottom of build.zig to keep the build logic above
//  readable. Format-string placeholders use Zig's `{s}` syntax; raw
//  templates use no placeholders.
// ============================================================

const PKGBUILD_TEMPLATE =
    \\# Maintainer: f69 contributors
    \\# shellcheck disable=SC2034,SC2154
    \\pkgname=f69
    \\pkgver={s}
    \\pkgrel=1
    \\pkgdesc='F95Zone-focused game library manager (Zig + dvui)'
    \\arch=('x86_64')
    \\url='https://github.com/your-org/f69'
    \\license=('MIT')
    \\depends=(
    \\    'vulkan-icd-loader'
    \\    'wayland'
    \\    'libxkbcommon'
    \\    'libdecor'
    \\    'libx11'
    \\    'libxext'
    \\    'libxcursor'
    \\    'libxi'
    \\    'libxrandr'
    \\    'dbus'
    \\    'libarchive'
    \\)
    \\makedepends=(
    \\    'zig'
    \\    'pkg-config'
    \\    'wayland-protocols'
    \\    'sqlite'
    \\    'openssl'
    \\    'dav1d'
    \\    'libavif'
    \\)
    \\optdepends=(
    \\    'aria2: multi-protocol downloads (auto-launched as RPC daemon)'
    \\    'bubblewrap: launch installed games inside a sandbox'
    \\)
    \\source=("$pkgname-$pkgver.tar.gz::https://github.com/your-org/f69/archive/v$pkgver.tar.gz")
    \\sha256sums=('SKIP')  # replace via `updpkgsums` once a real tarball exists
    \\
    \\# `$pkgdir` is ONLY set during package() — build() must compile only.
    \\build() {{
    \\    cd "$pkgname-$pkgver"
    \\    zig build -Doptimize=ReleaseSafe -Dgui=true
    \\}}
    \\
    \\package() {{
    \\    cd "$pkgname-$pkgver"
    \\    zig build install \
    \\        --prefix "$pkgdir/usr" \
    \\        -Doptimize=ReleaseSafe \
    \\        -Dgui=true
    \\    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    \\    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
    \\}}
    \\
;

const AUR_README =
    \\Generated PKGBUILD for f69. Publishing on the AUR:
    \\
    \\  1. cd zig-out/aur
    \\  2. updpkgsums            # recompute sha256 after a real release tarball exists
    \\  3. makepkg --printsrcinfo > .SRCINFO
    \\  4. push to aur.archlinux.org
    \\
    \\Local install without AUR:
    \\
    \\  cd zig-out/aur && makepkg -si
    \\
    \\If makepkg complains about zig: sudo pacman -S zig
    \\
;

const DEBIAN_CONTROL =
    \\Source: f69
    \\Section: games
    \\Priority: optional
    \\Maintainer: f69 contributors <noreply@example.com>
    \\Build-Depends: debhelper-compat (= 13), zig, pkg-config, libwayland-dev,
    \\ libxkbcommon-dev, libdecor-0-dev, libavif-dev, libdav1d-dev,
    \\ libsqlite3-dev, libssl-dev, libarchive-dev, libdbus-1-dev
    \\Standards-Version: 4.6.2
    \\Homepage: https://github.com/your-org/f69
    \\
    \\Package: f69
    \\Architecture: amd64
    \\Depends: ${{shlibs:Depends}}, ${{misc:Depends}},
    \\ libvulkan1, libwayland-client0, libxkbcommon0, libdecor-0-0,
    \\ libx11-6, libxext6, libxcursor1, libxi6, libxrandr2,
    \\ libdbus-1-3, libarchive13
    \\Recommends: aria2, bubblewrap
    \\Description: F95Zone-focused game library manager
    \\ f69 is a desktop game library and download manager for F95Zone content,
    \\ written in Zig with a dvui GUI. It tracks installs, manages mod recipes,
    \\ and runs games through an optional bwrap sandbox.
    \\
;

// Makefile recipe lines must start with TAB (\t) — multiline `\\`
// literals don't permit raw tabs in the source, so use a regular
// string literal with explicit escapes.
const DEBIAN_RULES =
    "#!/usr/bin/make -f\n" ++
    "export DH_VERBOSE = 1\n" ++
    "\n" ++
    "%:\n" ++
    "\tdh $@\n" ++
    "\n" ++
    "override_dh_auto_configure:\n" ++
    "\n" ++
    "# Compile in %build-equivalent (just emits to zig-out/), install in\n" ++
    "# %install-equivalent. dh sequences may clean the staging dir\n" ++
    "# between phases — keeping the install-into-staging in the install\n" ++
    "# target is the safe pattern (same reason as the RPM .spec).\n" ++
    "override_dh_auto_build:\n" ++
    "\tzig build -Doptimize=ReleaseSafe -Dgui=true\n" ++
    "\n" ++
    "override_dh_auto_install:\n" ++
    "\tzig build install --prefix debian/f69/usr -Doptimize=ReleaseSafe -Dgui=true\n" ++
    "\tinstall -Dm644 LICENSE debian/f69/usr/share/doc/f69/copyright\n";

const DEBIAN_CHANGELOG =
    \\f69 ({s}-1) UNRELEASED; urgency=medium
    \\
    \\  * Initial release.
    \\
    \\ -- f69 contributors <noreply@example.com>  {s}
    \\
;

const DEBIAN_README =
    \\Debian source package skeleton for f69. Build the .deb:
    \\
    \\  1. Copy this debian/ directory into a clean f69 source tree (or
    \\     dpkg-source --extract a debian-source.tar.gz that includes it).
    \\  2. From the source tree root:
    \\       dpkg-buildpackage -us -uc -b
    \\     produces ../f69_<version>-1_amd64.deb.
    \\  3. Install: sudo dpkg -i ../f69_<version>-1_amd64.deb
    \\
    \\Build tools on Debian/Ubuntu:
    \\  sudo apt install build-essential devscripts debhelper zig pkg-config \
    \\    libwayland-dev libxkbcommon-dev libdecor-0-dev libavif-dev \
    \\    libdav1d-dev libsqlite3-dev libssl-dev libarchive-dev libdbus-1-dev
    \\
;

const RPM_SPEC =
    \\Name:           f69
    \\Version:        {s}
    \\Release:        1%{{?dist}}
    \\Summary:        F95Zone-focused game library manager (Zig + dvui)
    \\License:        MIT
    \\URL:            https://github.com/your-org/f69
    \\Source0:        %{{name}}-%{{version}}.tar.gz
    \\
    \\# Disable shebang mangling on our bundled data tree: mkxp-z ships
    \\# a vendored Ruby stdlib whose `#!/usr/bin/env ruby` shebangs must
    \\# remain pointing at env (mkxp-z embeds its own ruby, not the
    \\# system one). Without this, brp-mangle-shebangs rewrites every
    \\# `bin/racc`, `libexec/bundle`, etc. to `#!/usr/bin/ruby` — wrong
    \\# interpreter, breaks mkxp-z's RGSS script loader at runtime.
    \\%global __brp_mangle_shebangs_exclude_from ^%{{_datadir}}/%{{name}}/
    \\
    \\BuildRequires:  zig
    \\BuildRequires:  pkgconfig
    \\BuildRequires:  patchelf
    \\BuildRequires:  wayland-devel
    \\BuildRequires:  libxkbcommon-devel
    \\BuildRequires:  libdecor-devel
    \\BuildRequires:  libavif-devel
    \\BuildRequires:  libdav1d-devel
    \\BuildRequires:  sqlite-devel
    \\BuildRequires:  openssl-devel
    \\BuildRequires:  libarchive-devel
    \\BuildRequires:  dbus-devel
    \\# libarchive.a's transitive deps + the compression triple
    \\BuildRequires:  bzip2-devel
    \\BuildRequires:  zlib-devel
    \\BuildRequires:  xz-devel
    \\BuildRequires:  libzstd-devel
    \\BuildRequires:  lz4-devel
    \\BuildRequires:  nettle-devel
    \\BuildRequires:  libxml2-devel
    \\BuildRequires:  libacl-devel
    \\
    \\Requires:       vulkan-loader
    \\Requires:       libwayland-client
    \\Requires:       libxkbcommon
    \\Requires:       libdecor
    \\Requires:       libX11
    \\Requires:       libXext
    \\Requires:       libXcursor
    \\Requires:       libXi
    \\Requires:       libXrandr
    \\Requires:       dbus-libs
    \\Requires:       libarchive
    \\Recommends:     aria2
    \\Recommends:     bubblewrap
    \\
    \\%description
    \\f69 is a desktop game library and download manager for F95Zone content,
    \\written in Zig with a dvui GUI. It tracks installs, manages mod recipes,
    \\and runs games through an optional bwrap sandbox.
    \\
    \\%prep
    \\%setup -q
    \\
    \\# RPM wipes %{{buildroot}} between %build and %install — anything we
    \\# write to the buildroot in %build gets nuked. So %build compiles
    \\# only; %install does the actual prefix-into-buildroot install.
    \\%build
    \\# -Dfhs-layout=true installs the mkxp-z bundle + compat resources
    \\# under %{{_datadir}}/f69/ instead of %{{_bindir}}/data/. Putting
    \\# 50 MB of Ruby stdlib under /usr/bin/ is non-FHS and trips
    \\# rpm's `check-files` (and the brp shebang mangler).
    \\zig build -Doptimize=ReleaseSafe -Dgui=true -Dfhs-layout=true
    \\
    \\%install
    \\zig build install --prefix %{{buildroot}}%{{_prefix}} -Doptimize=ReleaseSafe -Dgui=true -Dfhs-layout=true
    \\# Strip baked-in RUNPATH — system installs resolve libs via
    \\# /etc/ld.so.cache, not via RPATH. pkg-config on Fedora sneaks
    \\# `/usr/lib64/pkgconfig/../../lib64` into the linker line, which
    \\# Zig propagates to DT_RUNPATH; rpm's check-rpaths fails on the
    \\# absolute-path-with-`..` pattern.
    \\patchelf --remove-rpath %{{buildroot}}%{{_bindir}}/f69
    \\install -Dm644 LICENSE %{{buildroot}}%{{_datadir}}/licenses/%{{name}}/LICENSE
    \\
    \\%files
    \\%license LICENSE
    \\%doc README.md
    \\%{{_bindir}}/f69
    \\# Bundled mkxp-z runtime + (when materialised by the build env)
    \\# compat-resource lib bundles. Wildcard is intentional: the
    \\# compat-resources subtree is only present when the build env
    \\# exported the matching F69_COMPAT_* paths (NixOS dev shell);
    \\# omitting it would break the spec on dev shells, while listing
    \\# it as %dir would break the regular Fedora container build.
    \\%{{_datadir}}/%{{name}}/
    \\
    \\%changelog
    \\* {s} f69 contributors <noreply@example.com> - {s}-1
    \\- Initial release.
    \\
;

const RPM_README =
    \\RPM .spec for f69. Build the binary RPM:
    \\
    \\  1. rpmdev-setuptree
    \\  2. (cd /path/to/f69 && git archive --prefix=f69-<ver>/ HEAD | \
    \\       gzip > ~/rpmbuild/SOURCES/f69-<ver>.tar.gz)
    \\  3. cp zig-out/rpm/f69.spec ~/rpmbuild/SPECS/
    \\  4. rpmbuild -bb ~/rpmbuild/SPECS/f69.spec
    \\
    \\Build tools on Fedora / openSUSE:
    \\  sudo dnf install rpm-build rpmdevtools zig pkgconfig \
    \\    wayland-devel libxkbcommon-devel libdecor-devel libavif-devel \
    \\    dav1d-devel sqlite-devel openssl-devel libarchive-devel dbus-devel
    \\
;

const RUN_SH_FULL =
    \\#!/bin/sh
    \\# f69 portable launcher — execs the bundled glibc loader explicitly so
    \\# we don't depend on the host having a compatible /lib64/ld-linux.
    \\# POSIX parameter expansion (no `dirname` dependency) so a minimal
    \\# PATH still launches us.
    \\case "$0" in
    \\    */*) DIR=${0%/*} ;;
    \\    *)   DIR=. ;;
    \\esac
    \\DIR=$(CDPATH= cd -- "$DIR" && pwd)
    \\
    \\# Pin the bundle root + data dir next to *this script*. When the
    \\# loader is invoked directly (the `exec ld-linux …` line below),
    \\# /proc/self/exe inside the child resolves to the loader (in
    \\# lib/), so the app's exe-discovery would otherwise place every
    \\# `<exe_dir>/foo` lookup inside lib/. F69_EXE_DIR overrides that
    \\# (used to find the bundled aria2c); F69_DATA_DIR handles data/.
    \\export F69_EXE_DIR="$DIR"
    \\export F69_DATA_DIR="$DIR/data"
    \\
    \\# Prepend our bundled lib/ but PRESERVE the host's LD_LIBRARY_PATH
    \\# so SDL3 can dlopen vendor GPU libs (libGL_*, libGLX_nvidia, …).
    \\# Also append standard GPU driver dirs as fallbacks — harmless on
    \\# systems where the path doesn't exist.
    \\GPU_PATHS=/run/opengl-driver/lib:/usr/lib/x86_64-linux-gnu:/usr/lib64:/usr/lib
    \\if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    \\    LD_LIBRARY_PATH="$DIR/lib:$LD_LIBRARY_PATH:$GPU_PATHS"
    \\else
    \\    LD_LIBRARY_PATH="$DIR/lib:$GPU_PATHS"
    \\fi
    \\export LD_LIBRARY_PATH
    \\
    \\# Vulkan + EGL driver discovery. SDL3's GPU backend needs the ICD
    \\# JSONs (separate from the .so files) to know which GPU stack to
    \\# use. NixOS hides them under /run/opengl-driver/share/; standard
    \\# distros put them in /usr/share/ and /etc/. Probe NixOS first,
    \\# fall back to the standard paths so the same launcher works
    \\# everywhere.
    \\NIXOS_VK_ICD=/run/opengl-driver/share/vulkan/icd.d
    \\STD_VK_ICD=/usr/share/vulkan/icd.d:/etc/vulkan/icd.d
    \\if [ -d "$NIXOS_VK_ICD" ]; then
    \\    VK_DRIVER_FILES="$NIXOS_VK_ICD"
    \\else
    \\    VK_DRIVER_FILES="$STD_VK_ICD"
    \\fi
    \\export VK_DRIVER_FILES
    \\export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
    \\NIXOS_EGL=/run/opengl-driver/share/glvnd/egl_vendor.d
    \\STD_EGL=/usr/share/glvnd/egl_vendor.d
    \\if [ -d "$NIXOS_EGL" ]; then
    \\    __EGL_VENDOR_LIBRARY_DIRS="$NIXOS_EGL:$STD_EGL"
    \\else
    \\    __EGL_VENDOR_LIBRARY_DIRS="$STD_EGL"
    \\fi
    \\export __EGL_VENDOR_LIBRARY_DIRS
    \\
    \\exec "$DIR/lib/ld-linux-x86-64.so.2" "$DIR/f69" "$@"
    \\
;

/// Thin delegator written to project root by `zig build portable`.
/// Lets the developer run `./run.sh` from the repo root instead of
/// `./zig-out/bin/run.sh`. The bundle's launcher carries every
/// LD_LIBRARY_PATH / VK_DRIVER_FILES / data-dir detail; this script
/// only locates it and forwards args. Regenerated on every build —
/// safe to commit but also gitignored if the user prefers.
const RUN_SH_ROOT_DELEGATOR =
    \\#!/bin/sh
    \\# f69 dev-convenience launcher (project root).
    \\# Delegates to `zig-out/bin/run.sh` which carries the actual
    \\# env / ICD / data-dir setup. Regenerated by `zig build portable`.
    \\case "$0" in
    \\    */*) DIR=${0%/*} ;;
    \\    *)   DIR=. ;;
    \\esac
    \\DIR=$(CDPATH= cd -- "$DIR" && pwd)
    \\exec "$DIR/zig-out/bin/run.sh" "$@"
    \\
;

const RUN_SH_SLIM =
    \\#!/bin/sh
    \\# f69 slim launcher — relies on host-supplied libs. See DEPS.md for
    \\# the runtime package list. Pin data dir next to this script.
    \\case "$0" in
    \\    */*) DIR=${0%/*} ;;
    \\    *)   DIR=. ;;
    \\esac
    \\DIR=$(CDPATH= cd -- "$DIR" && pwd)
    \\export F69_EXE_DIR="$DIR"
    \\export F69_DATA_DIR="$DIR/data"
    \\
    \\GPU_PATHS=/run/opengl-driver/lib:/usr/lib/x86_64-linux-gnu:/usr/lib64:/usr/lib
    \\if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    \\    LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$GPU_PATHS"
    \\else
    \\    LD_LIBRARY_PATH="$GPU_PATHS"
    \\fi
    \\export LD_LIBRARY_PATH
    \\
    \\# Vulkan + EGL driver discovery. SDL3's GPU backend needs the
    \\# ICD JSONs (separate from the .so files); without them you get
    \\# "No supported SDL_GPU backend found". NixOS hides them under
    \\# /run/opengl-driver/share/; standard distros use /usr/share/.
    \\NIXOS_VK_ICD=/run/opengl-driver/share/vulkan/icd.d
    \\STD_VK_ICD=/usr/share/vulkan/icd.d:/etc/vulkan/icd.d
    \\if [ -d "$NIXOS_VK_ICD" ]; then
    \\    VK_DRIVER_FILES="$NIXOS_VK_ICD"
    \\else
    \\    VK_DRIVER_FILES="$STD_VK_ICD"
    \\fi
    \\export VK_DRIVER_FILES
    \\export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
    \\NIXOS_EGL=/run/opengl-driver/share/glvnd/egl_vendor.d
    \\STD_EGL=/usr/share/glvnd/egl_vendor.d
    \\if [ -d "$NIXOS_EGL" ]; then
    \\    __EGL_VENDOR_LIBRARY_DIRS="$NIXOS_EGL:$STD_EGL"
    \\else
    \\    __EGL_VENDOR_LIBRARY_DIRS="$STD_EGL"
    \\fi
    \\export __EGL_VENDOR_LIBRARY_DIRS
    \\
    \\exec "$DIR/f69" "$@"
    \\
;

const DEPS_MD =
    \\# f69 slim — required host packages
    \\
    \\This slim bundle does NOT carry shared libraries. Install the runtime
    \\deps via your distro package manager.
    \\
    \\## Arch Linux
    \\
    \\```sh
    \\sudo pacman -S vulkan-icd-loader wayland libxkbcommon libdecor \
    \\    libx11 libxext libxcursor libxi libxrandr \
    \\    dbus libarchive
    \\```
    \\
    \\## Debian / Ubuntu
    \\
    \\```sh
    \\sudo apt install libvulkan1 libwayland-client0 libxkbcommon0 libdecor-0-0 \
    \\    libx11-6 libxext6 libxcursor1 libxi6 libxrandr2 \
    \\    libdbus-1-3 libarchive13
    \\```
    \\
    \\## Fedora / RHEL / openSUSE
    \\
    \\```sh
    \\sudo dnf install vulkan-loader libwayland-client libxkbcommon libdecor \
    \\    libX11 libXext libXcursor libXi libXrandr \
    \\    dbus-libs libarchive
    \\```
    \\
    \\## NixOS — one-shot shell
    \\
    \\```sh
    \\nix-shell -p vulkan-loader wayland libxkbcommon libdecor \
    \\    xorg.libX11 xorg.libXext xorg.libXcursor xorg.libXi xorg.libXrandr \
    \\    dbus libarchive \
    \\    --run ./run.sh
    \\```
    \\
    \\Or pin via `programs.nix-ld.enable = true;` + the libs on
    \\`programs.nix-ld.libraries`, then `./run.sh` works system-wide.
    \\
    \\## NixOS — flake
    \\
    \\`nix build .#f69` from a checkout. The flake's `packages.f69`
    \\derivation pulls every dep automatically.
    \\
    \\## aria2 (recommended — needed for in-app downloads)
    \\
    \\f69 spawns `aria2c` as an RPC daemon when the user starts a
    \\download. The slim bundle does not carry it; install via:
    \\
    \\- Arch:     `sudo pacman -S aria2`
    \\- Debian:   `sudo apt install aria2`
    \\- Fedora:   `sudo dnf install aria2`
    \\- NixOS:    `nix profile add nixpkgs#aria2`
    \\
    \\If absent, the rest of the app works but the Download button
    \\errors with `aria2 spawn failed (FileNotFound)`.
    \\
    \\## GPU drivers (NEVER bundled — vendor-specific)
    \\
    \\- NVIDIA: proprietary driver + `nvidia-utils` (Arch) /
    \\  `libnvidia-gl-*` (Debian) / `xorg-x11-drv-nvidia-libs` (Fedora).
    \\  NixOS: `hardware.graphics.enable = true;` +
    \\  `services.xserver.videoDrivers = [ "nvidia" ];`.
    \\- AMD / Intel: Mesa — `mesa` / `vulkan-radeon` / `vulkan-intel`.
    \\
;
