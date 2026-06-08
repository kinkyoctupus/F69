// Mod resolver. BFS expansion from `requested`, version-constraint
// enforcement (`for_game_version` + `requires.version`), declared-
// conflict detection at each step, Kahn-based topological sort over
// `load_after` / `load_before`.
//
// Still deferred:
//   - Backtracking-with-learning. Only matters when multiple
//     candidate versions of a single mod id exist in the pool;
//     today each `available` row pins one version per `id`. If
//     multi-version pools land later, a `version_mismatch` becomes
//     a backtrack signal instead of a terminal failure.
//   - File-level conflict detection (separate pass in `files.zig`).
//
// Error reporting: `solve` collapses failures into errs.Error,
// `solveExplained` returns a `SolveResult` union with a causal
// `chain` (root user-request → … → failing mod) so the UI can
// render "A → B → C: incompatible" rather than just "conflict".

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");
const recipe = @import("recipe");
const kahn = @import("util_kahn");
const version_mod = @import("util_version");

pub const Input = struct {
    /// Mods explicitly selected by the user.
    requested: []const recipe.ModRecipe,
    /// Pool of all known mod recipes (for resolving `requires`).
    /// Indexed by `id`; multiple versions of the same `id` not yet
    /// supported (we'll pick the first hit).
    available: []const recipe.ModRecipe,
    /// Game version we're solving against. Empty string skips the
    /// `for_game_version` enforcement entirely (useful for unit
    /// tests that don't care about game-version compatibility).
    game_version: []const u8 = "",
};

pub const SolveResult = union(enum) {
    ok: domain.Plan,
    conflict: ConflictExplained,
    missing: MissingExplained,
    version_mismatch: VersionMismatchExplained,
    cycle: void,

    /// Causal chain (root → … → mod) is a `[]const []const u8` —
    /// outer slice is allocator-owned, inner strings borrow from the
    /// ModRecipe.id fields (caller keeps those alive until deinit).
    pub const ConflictExplained = struct {
        a: []const u8,
        b: []const u8,
        reason: domain.ConflictReason,
        detail: ?[]const u8 = null,
        chain: []const []const u8,
    };

    pub const MissingExplained = struct {
        /// Mod id that pulled in the missing dep.
        wanted_by: []const u8,
        /// The id we couldn't find in `available`.
        missing_id: []const u8,
        /// Constraint declared on the missing requires (e.g.
        /// ">=2.0"); empty when the requires had no version pin.
        constraint: []const u8 = "",
        chain: []const []const u8,
    };

    pub const VersionMismatchExplained = struct {
        pub const Source = enum {
            /// `mod.for_game_version` rejected the current game
            /// version. `mod_id` is the mod itself; `found_version`
            /// is the current game version.
            for_game_version,
            /// A `requires.version` constraint rejected the
            /// candidate pool entry. `mod_id` is the candidate;
            /// `found_version` is its declared `version`.
            requires_version,
        };
        mod_id: []const u8,
        wanted_constraint: []const u8,
        found_version: []const u8,
        source: Source,
        chain: []const []const u8,
    };

    /// Free heap allocations owned by the result, if any. Pass the
    /// same allocator handed to `solveExplained`.
    pub fn deinit(self: *SolveResult, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |p| alloc.free(p.steps),
            .conflict => |c| alloc.free(c.chain),
            .missing => |m| alloc.free(m.chain),
            .version_mismatch => |v| alloc.free(v.chain),
            .cycle => {},
        }
        self.* = undefined;
    }
};

/// Render a failed `SolveResult` as a one-line human explanation, or null
/// for `.ok`. Pure — formats into the caller's buffer. Used by the mods page
/// to tell the user *why* a mod plan won't resolve.
pub fn explain(buf: []u8, result: SolveResult) ?[]const u8 {
    return switch (result) {
        .ok => null,
        .conflict => |c| std.fmt.bufPrint(
            buf,
            "Conflict: '{s}' and '{s}' are incompatible ({s}).",
            .{ c.a, c.b, @tagName(c.reason) },
        ) catch null,
        .missing => |m| if (m.constraint.len > 0)
            std.fmt.bufPrint(buf, "'{s}' requires '{s}' {s}, which isn't available.", .{ m.wanted_by, m.missing_id, m.constraint }) catch null
        else
            std.fmt.bufPrint(buf, "'{s}' requires '{s}', which isn't available.", .{ m.wanted_by, m.missing_id }) catch null,
        .version_mismatch => |v| std.fmt.bufPrint(
            buf,
            "'{s}' needs version {s} but found {s}.",
            .{ v.mod_id, v.wanted_constraint, v.found_version },
        ) catch null,
        .cycle => std.fmt.bufPrint(buf, "These mods form a dependency cycle.", .{}) catch null,
    };
}

test "explain renders each failure variant; null for ok" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(explain(&buf, .{ .ok = .{ .steps = &.{} } }) == null);
    try std.testing.expectEqualStrings(
        "'modA' requires 'modB' >=2.0, which isn't available.",
        explain(&buf, .{ .missing = .{ .wanted_by = "modA", .missing_id = "modB", .constraint = ">=2.0", .chain = &.{} } }).?,
    );
    try std.testing.expectEqualStrings(
        "These mods form a dependency cycle.",
        explain(&buf, .cycle).?,
    );
}

/// Compatibility shim — collapses the explained variants into errs.
pub fn solve(alloc: std.mem.Allocator, in: Input) errs.Error!domain.Plan {
    var r = try solveExplained(alloc, in);
    defer r.deinit(alloc);
    return switch (r) {
        .ok => |p| .{ .steps = try alloc.dupe(domain.PlanStep, p.steps) },
        .conflict => errs.Error.DependencyConflict,
        .missing => errs.Error.UnsatisfiedDependency,
        .version_mismatch => errs.Error.DependencyConflict,
        .cycle => errs.Error.LoadOrderCycle,
    };
}

/// Full result with explanation payload — caller deinits.
pub fn solveExplained(alloc: std.mem.Allocator, in: Input) errs.Error!SolveResult {
    // ---- 1. Build the pool of mod_id → *const ModRecipe ----
    var pool = std.StringHashMap(*const recipe.ModRecipe).init(alloc);
    defer pool.deinit();
    for (in.available) |*m| {
        pool.put(m.id, m) catch return errs.Error.OutOfMemory;
    }

    // ---- 2. BFS from requested ----
    var chosen = std.StringHashMap(*const recipe.ModRecipe).init(alloc);
    defer chosen.deinit();

    // parent_of[child_id] = parent_id (empty string = user-requested
    // root). Used to build the causal chain on failure.
    var parent_of = std.StringHashMap([]const u8).init(alloc);
    defer parent_of.deinit();

    const QueueEntry = struct { mod: *const recipe.ModRecipe, wanted_by: []const u8 };
    var queue: std.ArrayList(QueueEntry) = .empty;
    defer queue.deinit(alloc);

    for (in.requested) |*m| {
        queue.append(alloc, .{ .mod = m, .wanted_by = "" }) catch return errs.Error.OutOfMemory;
        parent_of.put(m.id, "") catch return errs.Error.OutOfMemory;
    }

    while (queue.items.len > 0) {
        const entry = queue.orderedRemove(0);
        const m = entry.mod;

        // Skip duplicates (BFS can hit the same mod through two paths).
        if (chosen.contains(m.id)) continue;

        // ---- 2a. for_game_version check ----
        // Skipped silently when in.game_version is empty (lets unit
        // tests + offline derivations focus on dep graph).
        if (in.game_version.len > 0) {
            if (m.for_game_version) |constraint| {
                if (constraint.len > 0 and !version_mod.satisfies(in.game_version, constraint)) {
                    const chain = try buildChain(alloc, parent_of, m.id);
                    return SolveResult{ .version_mismatch = .{
                        .mod_id = m.id,
                        .wanted_constraint = constraint,
                        .found_version = in.game_version,
                        .source = .for_game_version,
                        .chain = chain,
                    } };
                }
            }
        }

        // ---- 2b. Declared-conflict check (both directions) ----
        for (m.conflicts) |c| {
            if (chosen.contains(c)) {
                const chain = try buildChain(alloc, parent_of, m.id);
                return SolveResult{ .conflict = .{
                    .a = m.id,
                    .b = c,
                    .reason = .declared_conflict,
                    .detail = "mod's `conflicts` list",
                    .chain = chain,
                } };
            }
        }
        var ci = chosen.iterator();
        while (ci.next()) |existing_kv| {
            for (existing_kv.value_ptr.*.conflicts) |c| {
                if (std.mem.eql(u8, c, m.id)) {
                    const chain = try buildChain(alloc, parent_of, m.id);
                    return SolveResult{ .conflict = .{
                        .a = existing_kv.value_ptr.*.id,
                        .b = m.id,
                        .reason = .declared_conflict,
                        .detail = "existing mod's `conflicts` list",
                        .chain = chain,
                    } };
                }
            }
        }

        // ---- 2b'. Provides-capability collision check ----
        // Two mods declaring the same `provides.capability` can't
        // coexist — they're swapping the same plug. Surface as a
        // declared conflict so the UI can render it the same way.
        if (m.provides.len > 0) {
            var pi = chosen.iterator();
            while (pi.next()) |existing_kv| {
                const other = existing_kv.value_ptr.*;
                for (m.provides) |pm| {
                    for (other.provides) |po| {
                        if (std.mem.eql(u8, pm.capability, po.capability)) {
                            const chain = try buildChain(alloc, parent_of, m.id);
                            return SolveResult{ .conflict = .{
                                .a = other.id,
                                .b = m.id,
                                .reason = .declared_conflict,
                                .detail = "both provide the same capability",
                                .chain = chain,
                            } };
                        }
                    }
                }
            }
        }

        chosen.put(m.id, m) catch return errs.Error.OutOfMemory;

        // ---- 2c. Expand requires ----
        for (m.requires) |req| {
            const dep = pool.get(req.target) orelse {
                // Record provisional parent for the missing id so the
                // chain ends at it. Don't overwrite if already present.
                if (!parent_of.contains(req.target)) {
                    parent_of.put(req.target, m.id) catch return errs.Error.OutOfMemory;
                }
                const chain = try buildChain(alloc, parent_of, req.target);
                const constraint_text: []const u8 = req.version orelse "";
                return SolveResult{ .missing = .{
                    .wanted_by = m.id,
                    .missing_id = req.target,
                    .constraint = constraint_text,
                    .chain = chain,
                } };
            };

            // Version-constraint enforcement on the pool match.
            if (req.version) |constraint| {
                if (constraint.len > 0 and !version_mod.satisfies(dep.version, constraint)) {
                    if (!parent_of.contains(dep.id)) {
                        parent_of.put(dep.id, m.id) catch return errs.Error.OutOfMemory;
                    }
                    const chain = try buildChain(alloc, parent_of, dep.id);
                    return SolveResult{ .version_mismatch = .{
                        .mod_id = dep.id,
                        .wanted_constraint = constraint,
                        .found_version = dep.version,
                        .source = .requires_version,
                        .chain = chain,
                    } };
                }
            }

            if (!parent_of.contains(dep.id)) {
                parent_of.put(dep.id, m.id) catch return errs.Error.OutOfMemory;
            }
            queue.append(alloc, .{ .mod = dep, .wanted_by = m.id }) catch return errs.Error.OutOfMemory;
        }
    }

    // ---- 3. Topological sort over load_after / load_before ----
    var node_list: std.ArrayList([]const u8) = .empty;
    defer node_list.deinit(alloc);
    var edge_list: std.ArrayList(kahn.Edge) = .empty;
    defer edge_list.deinit(alloc);

    var it2 = chosen.iterator();
    while (it2.next()) |entry| {
        const m = entry.value_ptr.*;
        node_list.append(alloc, m.id) catch return errs.Error.OutOfMemory;
        for (m.load_after) |after| {
            if (chosen.contains(after)) {
                edge_list.append(alloc, .{ .from = after, .to = m.id }) catch return errs.Error.OutOfMemory;
            }
        }
        for (m.load_before) |before| {
            if (chosen.contains(before)) {
                edge_list.append(alloc, .{ .from = m.id, .to = before }) catch return errs.Error.OutOfMemory;
            }
        }
    }

    // Deterministic tie-break: HashMap iteration order is randomized
    // per-run. Sort node_list alphabetically so Kahn's BFS picks a
    // stable order when constraints don't fully disambiguate.
    std.mem.sort([]const u8, node_list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    const ordered = kahn.sort(alloc, node_list.items, edge_list.items) catch |e| switch (e) {
        kahn.Error.CycleDetected => return SolveResult{ .cycle = {} },
        kahn.Error.OutOfMemory => return errs.Error.OutOfMemory,
    };
    defer alloc.free(ordered);

    // ---- 4. Build the Plan ----
    var steps: std.ArrayList(domain.PlanStep) = .empty;
    errdefer steps.deinit(alloc);
    for (ordered, 0..) |mod_id, i| {
        const m = chosen.get(mod_id).?;
        steps.append(alloc, .{
            .mod_id = m.id,
            .mod_version = m.version,
            .load_index = @intCast(i),
        }) catch return errs.Error.OutOfMemory;
    }

    return SolveResult{ .ok = .{
        .steps = steps.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory,
    } };
}

/// Walk `parent_of` backward from `leaf_id` to the root (empty-string
/// parent) and return the ancestry as `[]const []const u8` ordered
/// root-first. Caller-owned slice; the inner strings borrow from
/// ModRecipe.id lifetimes.
fn buildChain(
    alloc: std.mem.Allocator,
    parent_of: std.StringHashMap([]const u8),
    leaf_id: []const u8,
) errs.Error![]const []const u8 {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(alloc);

    var cur: []const u8 = leaf_id;
    var safety: u32 = 0;
    while (true) {
        stack.append(alloc, cur) catch return errs.Error.OutOfMemory;
        const parent = parent_of.get(cur) orelse break;
        if (parent.len == 0) break; // root
        // Cycle guard — shouldn't happen if BFS is correct, but a
        // malformed parent_of would otherwise loop forever.
        safety += 1;
        if (safety > 1024) break;
        cur = parent;
    }
    // stack is leaf-first; reverse so root comes first.
    const out = alloc.alloc([]const u8, stack.items.len) catch return errs.Error.OutOfMemory;
    var i: usize = 0;
    while (i < stack.items.len) : (i += 1) {
        out[i] = stack.items[stack.items.len - 1 - i];
    }
    return out;
}

/// Format a `chain` ([root, ..., leaf]) into a single human-readable
/// arrow-joined string. Writes into `buf`; returns the populated
/// slice (or a truncated tail if `buf` is too small). Used by the UI
/// to flatten the chain into a one-line toast / status message.
pub fn formatChain(buf: []u8, chain: []const []const u8) []const u8 {
    if (chain.len == 0) return buf[0..0];
    var w: usize = 0;
    for (chain, 0..) |id, i| {
        if (i > 0) {
            const sep = " \u{2192} "; // " → "
            if (w + sep.len > buf.len) break;
            @memcpy(buf[w .. w + sep.len], sep);
            w += sep.len;
        }
        const room = buf.len - w;
        const take = @min(id.len, room);
        @memcpy(buf[w .. w + take], id[0..take]);
        w += take;
        if (take < id.len) break;
    }
    return buf[0..w];
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

fn makeMod(id: []const u8, version: []const u8) recipe.ModRecipe {
    return .{
        .id = id,
        .name = id,
        .f95_thread = 0,
        .version = version,
        .for_game = "test-game",
    };
}

test "solve: empty input → empty plan" {
    var r = try solveExplained(testing.allocator, .{
        .requested = &.{},
        .available = &.{},
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .ok => |p| try testing.expectEqual(@as(usize, 0), p.steps.len),
        else => return error.TestExpectedEqual,
    }
}

test "solve: single requested mod, no deps" {
    const mods = [_]recipe.ModRecipe{makeMod("a", "1.0")};
    var r = try solveExplained(testing.allocator, .{
        .requested = mods[0..],
        .available = mods[0..],
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .ok => |p| {
            try testing.expectEqual(@as(usize, 1), p.steps.len);
            try testing.expectEqualStrings("a", p.steps[0].mod_id);
        },
        else => return error.TestExpectedEqual,
    }
}

test "solve: requires chain a → b → c" {
    var a = makeMod("a", "1.0");
    var b = makeMod("b", "1.0");
    const c = makeMod("c", "1.0");
    a.requires = &.{.{ .target = "b" }};
    b.requires = &.{.{ .target = "c" }};
    const available = [_]recipe.ModRecipe{ a, b, c };
    const requested = [_]recipe.ModRecipe{a};

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .ok => |p| try testing.expectEqual(@as(usize, 3), p.steps.len),
        else => return error.TestExpectedEqual,
    }
}

test "solve: declared conflict" {
    var a = makeMod("a", "1.0");
    const b = makeMod("b", "1.0");
    a.conflicts = &.{"b"};
    const available = [_]recipe.ModRecipe{ a, b };
    const requested = [_]recipe.ModRecipe{ a, b };

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .conflict => |c| {
            const matched = (std.mem.eql(u8, c.a, "a") and std.mem.eql(u8, c.b, "b")) or
                (std.mem.eql(u8, c.a, "b") and std.mem.eql(u8, c.b, "a"));
            try testing.expect(matched);
            try testing.expectEqual(domain.ConflictReason.declared_conflict, c.reason);
            try testing.expect(c.chain.len >= 1);
        },
        else => return error.TestExpectedEqual,
    }
}

test "solve: missing required mod" {
    var a = makeMod("a", "1.0");
    a.requires = &.{.{ .target = "ghost", .version = ">=2.0" }};
    const available = [_]recipe.ModRecipe{a};
    const requested = [_]recipe.ModRecipe{a};

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .missing => |m| {
            try testing.expectEqualStrings("a", m.wanted_by);
            try testing.expectEqualStrings("ghost", m.missing_id);
            try testing.expectEqualStrings(">=2.0", m.constraint);
            // Chain: a → ghost (root user-request → missing)
            try testing.expectEqual(@as(usize, 2), m.chain.len);
            try testing.expectEqualStrings("a", m.chain[0]);
            try testing.expectEqualStrings("ghost", m.chain[1]);
        },
        else => return error.TestExpectedEqual,
    }
}

test "solve: for_game_version mismatch" {
    var a = makeMod("a", "1.0");
    a.for_game_version = ">=0.20,<0.21";
    const available = [_]recipe.ModRecipe{a};
    const requested = [_]recipe.ModRecipe{a};

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
        .game_version = "0.19",
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .version_mismatch => |v| {
            try testing.expectEqualStrings("a", v.mod_id);
            try testing.expectEqualStrings(">=0.20,<0.21", v.wanted_constraint);
            try testing.expectEqualStrings("0.19", v.found_version);
            try testing.expectEqual(SolveResult.VersionMismatchExplained.Source.for_game_version, v.source);
        },
        else => return error.TestExpectedEqual,
    }
}

test "solve: for_game_version satisfied → ok" {
    var a = makeMod("a", "1.0");
    a.for_game_version = ">=0.20,<0.21";
    const available = [_]recipe.ModRecipe{a};
    const requested = [_]recipe.ModRecipe{a};

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
        .game_version = "0.20.5",
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .ok => |p| try testing.expectEqual(@as(usize, 1), p.steps.len),
        else => return error.TestExpectedEqual,
    }
}

test "solve: requires.version mismatch" {
    var a = makeMod("a", "1.0");
    const b = makeMod("b", "1.5");
    a.requires = &.{.{ .target = "b", .version = ">=2.0" }};
    const available = [_]recipe.ModRecipe{ a, b };
    const requested = [_]recipe.ModRecipe{a};

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .version_mismatch => |v| {
            try testing.expectEqualStrings("b", v.mod_id);
            try testing.expectEqualStrings(">=2.0", v.wanted_constraint);
            try testing.expectEqualStrings("1.5", v.found_version);
            try testing.expectEqual(SolveResult.VersionMismatchExplained.Source.requires_version, v.source);
            // Chain: a → b
            try testing.expectEqual(@as(usize, 2), v.chain.len);
            try testing.expectEqualStrings("a", v.chain[0]);
            try testing.expectEqualStrings("b", v.chain[1]);
        },
        else => return error.TestExpectedEqual,
    }
}

test "solve: explanation chain depth a → b → c → missing" {
    var a = makeMod("a", "1.0");
    var b = makeMod("b", "1.0");
    var c = makeMod("c", "1.0");
    a.requires = &.{.{ .target = "b" }};
    b.requires = &.{.{ .target = "c" }};
    c.requires = &.{.{ .target = "ghost" }};
    const available = [_]recipe.ModRecipe{ a, b, c };
    const requested = [_]recipe.ModRecipe{a};

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .missing => |m| {
            // a (root) → b → c → ghost
            try testing.expectEqual(@as(usize, 4), m.chain.len);
            try testing.expectEqualStrings("a", m.chain[0]);
            try testing.expectEqualStrings("b", m.chain[1]);
            try testing.expectEqualStrings("c", m.chain[2]);
            try testing.expectEqualStrings("ghost", m.chain[3]);
        },
        else => return error.TestExpectedEqual,
    }
}

test "solve: load_after ordering" {
    const loader = makeMod("loader", "1.0");
    var patch = makeMod("patch", "1.0");
    patch.load_after = &.{"loader"};

    const available = [_]recipe.ModRecipe{ loader, patch };
    const requested = [_]recipe.ModRecipe{ patch, loader };

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .ok => |p| {
            try testing.expectEqual(@as(usize, 2), p.steps.len);
            try testing.expectEqualStrings("loader", p.steps[0].mod_id);
            try testing.expectEqualStrings("patch", p.steps[1].mod_id);
        },
        else => return error.TestExpectedEqual,
    }
}

test "solve: load order cycle" {
    var a = makeMod("a", "1.0");
    var b = makeMod("b", "1.0");
    a.load_after = &.{"b"};
    b.load_after = &.{"a"};

    const available = [_]recipe.ModRecipe{ a, b };
    const requested = [_]recipe.ModRecipe{ a, b };

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .cycle => {},
        else => return error.TestExpectedEqual,
    }
}

test "solve: duplicate requires don't double-add" {
    var a = makeMod("a", "1.0");
    var b = makeMod("b", "1.0");
    const c = makeMod("c", "1.0");
    a.requires = &.{ .{ .target = "c" }, .{ .target = "c" } };
    b.requires = &.{.{ .target = "c" }};
    const available = [_]recipe.ModRecipe{ a, b, c };
    const requested = [_]recipe.ModRecipe{ a, b };

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .ok => |p| try testing.expectEqual(@as(usize, 3), p.steps.len),
        else => return error.TestExpectedEqual,
    }
}

test "solve: provides-capability collision" {
    var a = makeMod("a", "1.0");
    var b = makeMod("b", "1.0");
    a.provides = &.{.{ .capability = "renpy-mod-loader" }};
    b.provides = &.{.{ .capability = "renpy-mod-loader" }};
    const available = [_]recipe.ModRecipe{ a, b };
    const requested = [_]recipe.ModRecipe{ a, b };

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .conflict => |c| {
            try testing.expectEqual(domain.ConflictReason.declared_conflict, c.reason);
            const both = (std.mem.eql(u8, c.a, "a") and std.mem.eql(u8, c.b, "b")) or
                (std.mem.eql(u8, c.a, "b") and std.mem.eql(u8, c.b, "a"));
            try testing.expect(both);
        },
        else => return error.TestExpectedEqual,
    }
}

test "solve: load_after referencing absent mod is a no-op" {
    // `load_after = ghost` where ghost isn't installed — resolver
    // skips the edge, install proceeds normally.
    var a = makeMod("a", "1.0");
    a.load_after = &.{"ghost"};
    const available = [_]recipe.ModRecipe{a};
    const requested = [_]recipe.ModRecipe{a};

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .ok => |p| try testing.expectEqual(@as(usize, 1), p.steps.len),
        else => return error.TestExpectedEqual,
    }
}

test "solve: deterministic tie-break by id" {
    // Two mods with no ordering edges — output must be alphabetical.
    const z = makeMod("z-mod", "1.0");
    const a = makeMod("a-mod", "1.0");
    const available = [_]recipe.ModRecipe{ z, a };
    const requested = [_]recipe.ModRecipe{ z, a };

    var r = try solveExplained(testing.allocator, .{
        .requested = &requested,
        .available = &available,
    });
    defer r.deinit(testing.allocator);
    switch (r) {
        .ok => |p| {
            try testing.expectEqual(@as(usize, 2), p.steps.len);
            try testing.expectEqualStrings("a-mod", p.steps[0].mod_id);
            try testing.expectEqualStrings("z-mod", p.steps[1].mod_id);
        },
        else => return error.TestExpectedEqual,
    }
}

test "formatChain: arrow-joined" {
    var buf: [128]u8 = undefined;
    const chain = [_][]const u8{ "a", "b", "ghost" };
    const s = formatChain(&buf, &chain);
    try testing.expectEqualStrings("a \u{2192} b \u{2192} ghost", s);
}
