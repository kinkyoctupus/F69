// Public API of the resolver context.

const dom = @import("domain.zig");
const slv = @import("solver.zig");

pub const errors = @import("errors.zig");

pub const PlanStep = dom.PlanStep;
pub const Plan = dom.Plan;
pub const Conflict = dom.Conflict;
pub const ConflictReason = dom.ConflictReason;

pub const Input = slv.Input;
pub const SolveResult = slv.SolveResult;
pub const solve = slv.solve;
pub const solveExplained = slv.solveExplained;
pub const formatChain = slv.formatChain;
pub const explain = slv.explain;

// Test discovery — pull in nested test {} blocks (Zig 0.16 doesn't
// walk transitive imports for tests).
test {
    _ = @import("solver.zig");
}
