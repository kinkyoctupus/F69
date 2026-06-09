//! Bundled + user-dropped fonts.
//!
//! Two nerd fonts are baked into the binary via `@embedFile` so the
//! portable bundle Just Works — no font dependency on the host. Users
//! who want more can drop additional `.ttf` / `.otf` files into
//! `<exe_dir>/fonts/`; `scanUserFonts` registers each at startup.
//!
//! All registered fonts become available by family name throughout
//! dvui (`Font.find({.family = "..."})`, `theme.font_body.withFamily
//! ("...")`, etc.). The current default body font is set from the
//! bundled JetBrainsMono Nerd Font — gives the whole UI proper glyph
//! coverage out of the box (replacement for the previous Latin-only
//! default that rendered ✓ / ⚠ / ✕ / 📁 as empty boxes).

const std = @import("std");
const dvui = @import("dvui");

const log = std.log.scoped(.fonts);

pub const DEFAULT_FAMILY: []const u8 = "JetBrainsMono Nerd Font";

// Design B font families (OFL, bundled). Headings/titles use Archivo
// (geometric grotesque); body/caption use IBM Plex Sans; mono uses
// IBM Plex Mono. ui.zig maps the theme's font slots onto these.
pub const FAMILY_HEADING: []const u8 = "Archivo";
pub const FAMILY_BODY: []const u8 = "IBM Plex Sans";
pub const FAMILY_MONO: []const u8 = "IBM Plex Mono";

const JETBRAINS_BYTES = @embedFile("assets/fonts/JetBrainsMonoNerdFont-Regular.ttf");
const JETBRAINS_BOLD_BYTES = @embedFile("assets/fonts/JetBrainsMonoNerdFont-Bold.ttf");
const FIRACODE_BYTES = @embedFile("assets/fonts/FiraCodeNerdFont-Regular.ttf");

const ARCHIVO_BYTES = @embedFile("assets/fonts/Archivo-Regular.ttf");
const ARCHIVO_BOLD_BYTES = @embedFile("assets/fonts/Archivo-Bold.ttf");
const PLEX_SANS_BYTES = @embedFile("assets/fonts/IBMPlexSans-Regular.ttf");
const PLEX_SANS_BOLD_BYTES = @embedFile("assets/fonts/IBMPlexSans-Bold.ttf");
const PLEX_MONO_BYTES = @embedFile("assets/fonts/IBMPlexMono-Regular.ttf");

/// Register the bundled fonts on `win`. Idempotent on the dvui side —
/// re-registering an already-known family is a no-op. Errors are
/// logged but never fatal (we'd rather render with the default font
/// than refuse to start).
pub fn registerBundled(win: *dvui.Window) void {
    win.addFont("JetBrainsMono Nerd Font", JETBRAINS_BYTES, null) catch |e| {
        log.warn("addFont JetBrainsMono failed: {s}", .{@errorName(e)});
    };
    win.addFont("FiraCode Nerd Font", FIRACODE_BYTES, null) catch |e| {
        log.warn("addFont FiraCode failed: {s}", .{@errorName(e)});
    };
    // dvui's `addFont` doesn't accept a weight argument — every entry
    // it pushes has `weight = .normal`. To register the Bold variant
    // as the bold-weight font for the same family, push the Source
    // directly with `weight = .bold`. dvui's `findSource` then exact-
    // matches on (family, weight, style) for bold-text lookups, which
    // silences the `Font ... Bold not in dvui database` error.
    win.fonts.database.append(win.gpa, .{
        .family = dvui.Font.array("JetBrainsMono Nerd Font"),
        .weight = .bold,
        .style = .normal,
        .bytes = JETBRAINS_BOLD_BYTES,
        .allocator = null,
    }) catch |e| {
        log.warn("register JetBrainsMono Bold failed: {s}", .{@errorName(e)});
    };

    // Design B families (Archivo / IBM Plex Sans / IBM Plex Mono).
    registerFamily(win, FAMILY_HEADING, ARCHIVO_BYTES, ARCHIVO_BOLD_BYTES);
    registerFamily(win, FAMILY_BODY, PLEX_SANS_BYTES, PLEX_SANS_BOLD_BYTES);
    registerFamily(win, FAMILY_MONO, PLEX_MONO_BYTES, null);
}

/// Register a family's regular weight via `addFont`, then (if present) its
/// bold weight directly in the database so dvui's exact (family, weight)
/// lookup resolves bold text without the "Font ... Bold not in database" warn.
fn registerFamily(win: *dvui.Window, name: []const u8, regular: []const u8, bold: ?[]const u8) void {
    win.addFont(name, regular, null) catch |e| {
        log.warn("addFont {s} failed: {s}", .{ name, @errorName(e) });
        return;
    };
    if (bold) |b| {
        win.fonts.database.append(win.gpa, .{
            .family = dvui.Font.array(name),
            .weight = .bold,
            .style = .normal,
            .bytes = b,
            .allocator = null,
        }) catch |e| log.warn("register {s} Bold failed: {s}", .{ name, @errorName(e) });
    }
}

/// Scan `<exe_dir>/fonts/` for `.ttf` / `.otf` and register each with
/// dvui. Font family is derived from the filename (stem) so the user
/// can drop e.g. `IosevkaNerdFont-Regular.ttf` and refer to it as
/// `"IosevkaNerdFont-Regular"`. Missing directory is fine.
///
/// Caller-owned: nothing. The bytes are owned by `alloc` and handed
/// to dvui — dvui frees them via `ttf_bytes_allocator` (which we set
/// to `alloc` here).
pub fn scanUserFonts(
    win: *dvui.Window,
    alloc: std.mem.Allocator,
    io: std.Io,
    exe_dir: []const u8,
) void {
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/fonts", .{exe_dir}) catch return;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => {
            log.warn("scanUserFonts: open {s} failed: {s}", .{ dir_path, @errorName(e) });
            return;
        },
    };
    defer dir.close(io);

    var registered: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!hasFontExt(entry.name)) continue;

        var path_buf: [768]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            alloc,
            .limited(32 * 1024 * 1024),
        ) catch |e| {
            log.warn("scanUserFonts: read {s} failed: {s}", .{ path, @errorName(e) });
            continue;
        };
        // Family name = filename stem (drop the extension). dvui's
        // addFont takes a name argument independent of the file
        // contents, so this is just our convention.
        const dot = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse entry.name.len;
        const stem = entry.name[0..dot];
        win.addFont(stem, bytes, alloc) catch |e| {
            log.warn("scanUserFonts: addFont {s} failed: {s}", .{ stem, @errorName(e) });
            alloc.free(bytes);
            continue;
        };
        log.info("scanUserFonts: registered '{s}' ({d} bytes) from {s}", .{ stem, bytes.len, path });
        registered += 1;
    }
    if (registered > 0) log.info("scanUserFonts: registered {d} user font(s) from {s}", .{ registered, dir_path });
}

fn hasFontExt(name: []const u8) bool {
    const ext_lower = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
        const ext = name[dot..];
        if (ext.len > 8) return false;
        var buf: [8]u8 = undefined;
        var i: usize = 0;
        while (i < ext.len) : (i += 1) buf[i] = std.ascii.toLower(ext[i]);
        break :blk buf[0..ext.len];
    };
    return std.mem.eql(u8, ext_lower, ".ttf") or std.mem.eql(u8, ext_lower, ".otf");
}
