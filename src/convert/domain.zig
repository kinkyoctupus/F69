// Convert specs — what fix-linux-games.sh does, hoisted into typed
// Zig. Per the 2026-05-12 architecture call: engine-keyed handlers in
// the app, recipe just declares `engine + sdk_version + extras`. No
// per-game declarative DSL.

const std = @import("std");

pub const Engine = enum {
    renpy,
    rpgm_mv,
    rpgm_mz,
    unity,
    unknown,
};

/// What `convert_linux` looks like in a recipe. Tagged union over the
/// engine-specific config blocks the handlers consume. `.none` means
/// "the game already has a Linux build" — convert is a no-op.
pub const ConvertSpec = union(enum) {
    none: void,
    renpy: struct {
        /// e.g. "7.5.3" — the SDK that ships matching `lib/{py3-,py2-,}linux-x86_64`.
        /// Recipe may pin or leave null to let convert detect from the
        /// install dir's `renpy/__init__.py` / `vc_version.py`.
        sdk_version: ?[]const u8 = null,
    },
    rpgm: struct {
        /// Pin nwjs version explicitly; null = auto-detect from `nw.dll`'s
        /// embedded Chrome version → `chromeToNwjs` table.
        nwjs_version: ?[]const u8 = null,
        ffmpeg_codecs: bool = true,
        bundle_syslibs: bool = true,
    },
};

pub const Distro = enum {
    nixos,
    arch,
    debian,
    ubuntu,
    fedora,
    other,

    /// Read `ID=...` from /etc/os-release. Falls back to `.other` on
    /// any IO error.
    pub fn detect(io: std.Io, gpa: std.mem.Allocator) Distro {
        const content = std.Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", gpa, .limited(64 * 1024)) catch return .other;
        defer gpa.free(content);
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
