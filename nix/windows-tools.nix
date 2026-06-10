# Host-side tools the Windows packaging step shells out to, pinned to
# flake.lock so they resolve without the `nixpkgs#` flake registry on a bare
# CI runner. Use via: nix shell -f nix/windows-tools.nix <attr> -c <cmd>
let
  pkgs = import (import ./pinned.nix) { };
in
{
  # Provides x86_64-w64-mingw32-objdump for walking the PE import table.
  mingwBinutils = pkgs.pkgsCross.mingwW64.buildPackages.binutils;
  zip = pkgs.zip;
}
