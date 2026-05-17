// libsecret wrapper for cookie / token storage.
//
// Linux: org.freedesktop.secrets D-Bus interface (KWallet, GNOME Keyring,
// kdewallet, etc. all expose this). Bindings via the `libsecret-1` C lib.
// Windows: defer to wincred (CredRead/CredWrite).
//
// Schema:
//   service: "xlibrary-zig"
//   account: provider id (e.g. "f95zone")
//   secret:  cookie string ("xf_user=...; xf_session=...")

const std = @import("std");

pub const Error = error{
    BackendUnavailable,
    NotFound,
    StorageFailed,
    OutOfMemory,
};

pub const Backend = enum {
    libsecret,
    wincred,
    plaintext_fallback, // ~/.config/xlibrary-zig/secrets.json — dev only
    none,               // refuse to store
};

pub fn store(backend: Backend, service: []const u8, account: []const u8, secret: []const u8) Error!void {
    _ = backend;
    _ = service;
    _ = account;
    _ = secret;
    return Error.BackendUnavailable; // TODO
}

/// Caller frees the returned slice.
pub fn lookup(alloc: std.mem.Allocator, backend: Backend, service: []const u8, account: []const u8) Error!?[]const u8 {
    _ = alloc;
    _ = backend;
    _ = service;
    _ = account;
    return null; // TODO
}

pub fn delete(backend: Backend, service: []const u8, account: []const u8) Error!void {
    _ = backend;
    _ = service;
    _ = account;
    return Error.BackendUnavailable; // TODO
}
