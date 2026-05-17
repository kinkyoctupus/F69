pub const Error = error{
    ZonParseError,
    MissingRequiredField,
    InvalidVersionConstraint,
    InvalidHash,
    UnknownEngine,
    UnsafePath,
    RecipeNotFound,
    SaveFailed,
    OutOfMemory,
};
