// Convert specs — what fix-linux-games.sh does, hoisted into typed
// Zig. Per the 2026-05-12 architecture call: engine-keyed handlers in
// the app, recipe just declares `engine + sdk_version + extras`. No
// per-game declarative DSL.

const std = @import("std");

/// Engine + Distro live in `util_domain` so every context shares the
/// same enums (with the same `fromBracket` / `parseOsReleaseId`
/// parsers).
pub const Engine = @import("util_domain").Engine;
pub const Distro = @import("util_domain").Distro;

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
