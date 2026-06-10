# Pinned nixpkgs source — same revision as flake.lock.
#
# CLI nix builds (the Windows cross-dep prefix, the packaging tools) must NOT
# depend on an ambient `<nixpkgs>` channel or the `nixpkgs#` flake registry:
# a bare CI runner (cachix/install-nix-action) has neither, and even when a
# channel exists it is an unpinned nixpkgs that drifts from flake.lock.
#
# This reads the locked rev + narHash straight out of flake.lock and fetches
# that exact tree. Pure (fixed sha256), so callers can drop `--impure`, and it
# stays in lockstep with `nix build .#f69` automatically.
#
# Returns the nixpkgs SOURCE (a path); callers do `import (import ./pinned.nix) { ... }`
# so each can pass its own config/overlays.
let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  node = lock.nodes.nixpkgs.locked;
in
builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/${node.rev}.tar.gz";
  # flake.lock's narHash is the NAR hash of the unpacked tree — exactly what
  # fetchTarball verifies after stripping the archive's top-level dir.
  sha256 = node.narHash;
}
