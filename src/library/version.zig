// Version comparator + range parser. F95Zone versions are messy:
//   "v0.5.7", "Episode 12 Public", "Final-1.0", "v21.0.0 wip.7164"
// We try semver-ish parse first, fall back to natural sort on the
// numeric runs in the string.

const std = @import("std");

pub const Error = error{ InvalidRange, OutOfMemory };

pub const Cmp = enum { lt, eq, gt };

/// Three-way compare. Returns `.eq` only for byte-equal strings; numeric
/// equivalence (e.g. "1.0" vs "1.0.0") is also `.eq`.
pub fn compare(a: []const u8, b: []const u8) Cmp {
    _ = a;
    _ = b;
    return .eq; // TODO: real impl
}

pub const Op = enum { ge, gt, le, lt, eq };

pub const Constraint = struct {
    op: Op,
    operand: []const u8,
};

/// Parses a constraint string like ">=0.5,<0.6" into an array of
/// AND-combined constraints. Caller frees the returned slice.
pub fn parseRange(alloc: std.mem.Allocator, s: []const u8) Error![]Constraint {
    _ = alloc;
    _ = s;
    return Error.InvalidRange; // TODO
}

pub fn satisfies(version: []const u8, constraints: []const Constraint) bool {
    _ = version;
    _ = constraints;
    return false; // TODO
}
