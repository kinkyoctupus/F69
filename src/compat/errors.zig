// Compat module's public error set.

pub const Error = error{
    OutOfMemory,
    ZonParseError,
    FileNotFound,
    PermissionDenied,
    IoError,
    UnsafePath,
    MissingRequiredField,
    UnknownResource,
    ResourceNotMaterialized,
    InvalidRecipe,
    DiskFull,
    BackupMismatch,
    AlreadyApplied,
    NotApplied,
    NotImplemented,
    DatabaseError,
};
