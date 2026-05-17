// Shared-kernel value objects — types so ubiquitous they belong above
// any single bounded context. Centralising them here removes the
// "redeclare-with-subtly-different-variants" failure mode that bit us
// before (compat's `Engine` was missing `unknown`; library knew about
// 15 engines while recipe/convert knew only 5; etc).
//
// Each context can still alias what it needs:
//
//     // src/recipe/domain.zig
//     pub const Engine = @import("util_domain").Engine;
//
// or expose a narrower subset via a re-export with renames if a strong
// case appears later. For now every consumer takes the full enum.

const std = @import("std");

/// Visual-novel / RPG engines we recognise on F95. Driven by:
///   - F95 thread title bracket tokens ("[Ren'Py]", "[Unity]", …)
///   - Engine-fingerprint heuristics in `convert/detect.zig`
///   - Compat / convert handler dispatch
///
/// `unknown` is the sentinel for "couldn't detect" / "not yet
/// classified" rows. Recipes can declare `engine = .unknown` to opt
/// out of auto-detection.
pub const Engine = enum {
    renpy,
    rpgm_mv,
    rpgm_mz,
    rpgm_vx,
    unity,
    unreal,
    html,
    flash,
    java,
    wolf_rpg,
    qsp,
    tyranobuilder,
    twine,
    other,
    unknown,

    /// Match the kebab / snake / underscore variants users type into
    /// recipe `.engine` fields.
    pub fn fromStr(s: []const u8) Engine {
        if (std.mem.eql(u8, s, "renpy")) return .renpy;
        if (std.mem.eql(u8, s, "rpgm-mv") or std.mem.eql(u8, s, "rpgm_mv")) return .rpgm_mv;
        if (std.mem.eql(u8, s, "rpgm-mz") or std.mem.eql(u8, s, "rpgm_mz")) return .rpgm_mz;
        if (std.mem.eql(u8, s, "rpgm-vx") or std.mem.eql(u8, s, "rpgm_vx")) return .rpgm_vx;
        if (std.mem.eql(u8, s, "unity")) return .unity;
        if (std.mem.eql(u8, s, "unreal")) return .unreal;
        if (std.mem.eql(u8, s, "html")) return .html;
        if (std.mem.eql(u8, s, "flash")) return .flash;
        if (std.mem.eql(u8, s, "java")) return .java;
        if (std.mem.eql(u8, s, "wolf_rpg") or std.mem.eql(u8, s, "wolf-rpg")) return .wolf_rpg;
        if (std.mem.eql(u8, s, "qsp")) return .qsp;
        if (std.mem.eql(u8, s, "tyranobuilder")) return .tyranobuilder;
        if (std.mem.eql(u8, s, "twine")) return .twine;
        if (std.mem.eql(u8, s, "other")) return .other;
        return .unknown;
    }

    /// Best-effort match for the kind of bracket tokens F95 thread
    /// titles use ("Ren'Py", "RPGM MV", "Unity"). Strips apostrophes
    /// and whitespace so "Ren'Py" / "RenPy" / "Ren Py" all match.
    pub fn fromBracket(token: []const u8) Engine {
        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (token) |c| {
            if (std.ascii.isAlphanumeric(c) and n < buf.len) {
                buf[n] = std.ascii.toLower(c);
                n += 1;
            }
        }
        const norm = buf[0..n];
        if (std.mem.eql(u8, norm, "renpy")) return .renpy;
        if (std.mem.eql(u8, norm, "rpgmmv") or std.mem.eql(u8, norm, "rpgmakermv")) return .rpgm_mv;
        if (std.mem.eql(u8, norm, "rpgmmz") or std.mem.eql(u8, norm, "rpgmakermz")) return .rpgm_mz;
        if (std.mem.eql(u8, norm, "rpgmvx") or std.mem.eql(u8, norm, "rpgmakervx") or std.mem.eql(u8, norm, "rpgmakervxace")) return .rpgm_vx;
        if (std.mem.eql(u8, norm, "rpgm") or std.mem.eql(u8, norm, "rpgmaker")) return .rpgm_mv;
        if (std.mem.eql(u8, norm, "unity")) return .unity;
        if (std.mem.eql(u8, norm, "unrealengine") or std.mem.eql(u8, norm, "unreal") or std.mem.eql(u8, norm, "ue4") or std.mem.eql(u8, norm, "ue5")) return .unreal;
        if (std.mem.eql(u8, norm, "html") or std.mem.eql(u8, norm, "html5")) return .html;
        if (std.mem.eql(u8, norm, "flash")) return .flash;
        if (std.mem.eql(u8, norm, "java")) return .java;
        if (std.mem.eql(u8, norm, "wolfrpg") or std.mem.eql(u8, norm, "wolfrpgeditor")) return .wolf_rpg;
        if (std.mem.eql(u8, norm, "qsp")) return .qsp;
        if (std.mem.eql(u8, norm, "tyranobuilder") or std.mem.eql(u8, norm, "tyrano")) return .tyranobuilder;
        if (std.mem.eql(u8, norm, "twine")) return .twine;
        if (std.mem.eql(u8, norm, "others") or std.mem.eql(u8, norm, "other")) return .other;
        return .unknown;
    }
};

/// Linux distro family. Drives per-distro install-hint pickers in the
/// compat module + lib-bundling paths in `convert/syslibs.zig`.
pub const Distro = enum {
    nixos,
    arch,
    debian,
    ubuntu,
    fedora,
    other,

    /// Read `ID=...` from `/etc/os-release`. Falls back to `.other` on
    /// any IO error.
    pub fn detect(io: std.Io, alloc: std.mem.Allocator) Distro {
        const content = std.Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", alloc, .limited(64 * 1024)) catch return .other;
        defer alloc.free(content);
        return parseOsReleaseId(content);
    }

    /// Pure — split out for unit testing without touching /etc/.
    pub fn parseOsReleaseId(content: []const u8) Distro {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "ID=")) continue;
            const v = std.mem.trim(u8, line[3..], "\"' \t");
            if (std.mem.eql(u8, v, "nixos")) return .nixos;
            if (std.mem.eql(u8, v, "arch")) return .arch;
            if (std.mem.eql(u8, v, "debian")) return .debian;
            if (std.mem.eql(u8, v, "ubuntu")) return .ubuntu;
            if (std.mem.eql(u8, v, "fedora")) return .fedora;
            return .other;
        }
        return .other;
    }
};

/// Operating system. Used by compat recipes' `platforms` array and
/// by the launcher to pick `launch.linux` vs `launch.windows`.
pub const Os = enum { linux, windows, macos };

const testing = std.testing;

test "Engine.fromBracket: common F95 spellings" {
    try testing.expectEqual(Engine.renpy, Engine.fromBracket("Ren'Py"));
    try testing.expectEqual(Engine.renpy, Engine.fromBracket("RenPy"));
    try testing.expectEqual(Engine.rpgm_mv, Engine.fromBracket("RPGM MV"));
    try testing.expectEqual(Engine.rpgm_mz, Engine.fromBracket("RPGMaker MZ"));
    try testing.expectEqual(Engine.unity, Engine.fromBracket("Unity"));
    try testing.expectEqual(Engine.unreal, Engine.fromBracket("UE4"));
    try testing.expectEqual(Engine.unknown, Engine.fromBracket("Custom"));
}

test "Engine.fromStr: kebab + snake variants" {
    try testing.expectEqual(Engine.renpy, Engine.fromStr("renpy"));
    try testing.expectEqual(Engine.rpgm_mv, Engine.fromStr("rpgm-mv"));
    try testing.expectEqual(Engine.rpgm_mv, Engine.fromStr("rpgm_mv"));
    try testing.expectEqual(Engine.unknown, Engine.fromStr("garbage"));
}
