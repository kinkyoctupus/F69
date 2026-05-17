pub const Error = error{
    UnsatisfiedDependency,
    DependencyConflict,
    LoadOrderCycle,
    UnknownMod,
    OutOfMemory,
};
