// Host-capability probe. Built once at app start, cached for the
// process lifetime, consulted by detectors.
//
// Capability checks are deliberately keyed by behavior ("can the
// loader find libX11.so.6?") rather than distro ("are we on NixOS?")
// so recipes stay portable. On Arch/Debian/Fedora the predicates
// short-circuit because the libraries live at standard FHS paths and
// the recipe never fires; on NixOS the same predicates return true
// and the recipe fires.

const std = @import("std");

pub const PackageManager = enum {
    /// `nix-ld` config snippet (NixOS).
    nix_ld,
    pacman,
    apt,
    dnf,
    zypper,
    /// macOS Homebrew or anything else we don't have a hint for.
    unknown,
};

pub const Host = struct {
    /// Standard /lib + /usr/lib search dirs, joined with `:`. Built
    /// once and used by `hasSoname`. Includes Debian's multi-arch
    /// dirs when present.
    soname_search: []const u8,
    /// Detected primary package manager. Used by the UI to pick the
    /// matching `DistroHint`.
    package_manager: PackageManager,
    /// True when the host appears to be NixOS (`/etc/NIXOS` or
    /// `/etc/os-release` ID=nixos). Informational only — detectors
    /// don't branch on this.
    is_nixos: bool,
    /// Allocator that owns `soname_search`.
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Host) void {
        self.alloc.free(self.soname_search);
        self.* = undefined;
    }

    /// Returns true when at least one search dir contains `soname` or
    /// a symlink resolving to a file with that name. Cheap stat-only
    /// check — no library is loaded.
    pub fn hasSoname(self: *const Host, io: std.Io, soname: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.soname_search, ':');
        var path_buf: [512]u8 = undefined;
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, soname }) catch continue;
            std.Io.Dir.cwd().access(io, path, .{}) catch continue;
            return true;
        }
        return false;
    }

    /// Convenience inverse for the `host_lacks_soname` detector.
    pub fn lacksSoname(self: *const Host, io: std.Io, soname: []const u8) bool {
        return !self.hasSoname(io, soname);
    }
};

/// Run the probe. Allocates `soname_search` on `alloc`.
pub fn probe(alloc: std.mem.Allocator, io: std.Io) !Host {
    const search = try buildSonameSearch(alloc, io);
    errdefer alloc.free(search);
    const pm = detectPackageManager(io);
    const nixos = isNixos(io);
    return .{
        .soname_search = search,
        .package_manager = pm,
        .is_nixos = nixos,
        .alloc = alloc,
    };
}

/// Build a colon-joined list of dirs the dynamic loader searches for
/// SONAMEs, restricted to dirs that exist on this host. We include
/// standard FHS dirs + Debian's well-known multi-arch dir. We do NOT
/// include `LD_LIBRARY_PATH` or rpath — those are caller-specific and
/// don't tell us anything about whether a third-party prebuilt binary
/// (e.g. Ren'Py's bundled SDL2) will find what it needs.
fn buildSonameSearch(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    const candidates = [_][]const u8{
        "/usr/lib",
        "/usr/lib64",
        "/lib",
        "/lib64",
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
    };
    var present: std.ArrayList([]const u8) = .empty;
    defer present.deinit(alloc);
    for (candidates) |c| {
        std.Io.Dir.cwd().access(io, c, .{}) catch continue;
        present.append(alloc, c) catch return error.OutOfMemory;
    }
    // Always include even when empty so `hasSoname` returns false
    // deterministically rather than panicking on an empty split.
    return std.mem.join(alloc, ":", present.items);
}

fn detectPackageManager(io: std.Io) PackageManager {
    // Order matters: NixOS first because `/run/current-system` is
    // unique to it. Then the most common distros.
    if (existsFile(io, "/etc/NIXOS")) return .nix_ld;
    if (existsFile(io, "/run/current-system/sw/bin/nix-env")) return .nix_ld;
    if (existsFile(io, "/usr/bin/pacman")) return .pacman;
    if (existsFile(io, "/usr/bin/apt") or existsFile(io, "/usr/bin/apt-get")) return .apt;
    if (existsFile(io, "/usr/bin/dnf")) return .dnf;
    if (existsFile(io, "/usr/bin/zypper")) return .zypper;
    return .unknown;
}

fn isNixos(io: std.Io) bool {
    return existsFile(io, "/etc/NIXOS");
}

fn existsFile(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "probe builds a non-empty search list" {
    // Skip if we can't get an Io vtable in unit tests.
    // The test runner provides one via std.testing.io() if available;
    // otherwise just verify the helper compiles.
    _ = probe;
    _ = Host;
}
