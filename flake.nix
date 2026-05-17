{
  description = "F69 — F95Zone-focused game library, written in Zig + dvui";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # AV1 decoder — bundled statically into f69 so end-user binaries
        # don't need libdav1d.so on their machine. Strip CLI tools and
        # tests for a tighter closure.
        dav1d-static = pkgs.dav1d.overrideAttrs (old: {
          mesonFlags = (old.mesonFlags or [ ]) ++ [
            "-Ddefault_library=static"
            "-Denable_tools=false"
            "-Denable_tests=false"
          ];
        });

        # AVIF container decoder, dav1d-backed. Static archive only —
        # no apps, no gdk-pixbuf loader, no tests, no encoder backend
        # (we never write AVIF, only decode at sync time).
        libavif-static = (pkgs.libavif.override {
          dav1d = dav1d-static;
        }).overrideAttrs (old: {
          cmakeFlags = [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DAVIF_CODEC_DAV1D=SYSTEM"
            "-DAVIF_CODEC_AOM=OFF"
            "-DAVIF_BUILD_APPS=OFF"
            "-DAVIF_BUILD_GDK_PIXBUF=OFF"
            "-DAVIF_BUILD_TESTS=OFF"
            "-DAVIF_LIBYUV=OFF"
            "-DAVIF_LIBSHARPYUV=OFF"
            "-DAVIF_LIBXML2=OFF"
          ];
          buildInputs = with pkgs; [ zlib libpng libjpeg dav1d-static ];
          nativeBuildInputs = with pkgs; [ cmake pkg-config ];
          outputs = [ "out" "dev" ];
          # Drop the gdk-pixbuf hooks the upstream derivation injects;
          # without -DAVIF_BUILD_GDK_PIXBUF=ON they reference nothing.
          postPatch = "";
          postInstall = "";
          postFixup = "";
        });

        # libarchive — multi-format archive read/write. Used by
        # src/util/archive.zig to extract .7z / .tar.bz2 / .tar.xz /
        # .rar (the formats Zig stdlib doesn't cover). Static-only —
        # the resulting f69 binary doesn't depend on libarchive.so at
        # run time. Disable bsdcat/bsdtar/bsdcpio CLI tools we don't
        # ship and the xattr/acl extras we don't need.
        # Stock nixpkgs libarchive — autotools-based build with
        # bzip2/xz/zlib/zstd/lzo/acl all enabled. Ships a static .a
        # alongside the shared .so so `preferred_link_mode = .static`
        # on the Zig side picks the static archive. Overriding to a
        # leaner config trips nixpkgs' generic fixupPhase which
        # expects a `libarchive.la` from autotools.
        libarchive-static = pkgs.libarchive;

        # Compat resource: FHS-style bundle of X11/Wayland/GL/audio/
        # font client libraries. Materialised at app build time and
        # copied to `<data_root>/compat-resources/renpy-fhs-libs/lib/`.
        # The Ren'Py compat recipe prepends `<that>/lib` to
        # LD_LIBRARY_PATH so the game's bundled SDL2 dlopen finds
        # libX11.so.6, libwayland-client.so.0, etc. — the libraries
        # missing from the standard loader paths on NixOS / musl /
        # minimal containers.
        renpy-fhs-libs =
          let
            joined = pkgs.symlinkJoin {
              name = "renpy-fhs-libs-symlinks";
              paths = with pkgs; [
                xorg.libX11
                xorg.libXext
                xorg.libXi
                xorg.libXcursor
                xorg.libXrandr
                xorg.libXinerama
                xorg.libXxf86vm
                # Ren'Py's gl renderer (gldraw.so, gl.so, …) links
                # libGLEW.so.1.7, which transitively needs libXmu.so.6
                # and libGLU.so.1. Without these, Python's __import__
                # of the renderer module fails and Ren'Py falls back
                # to its software renderer.
                xorg.libXmu
                libGLU
                libxkbcommon
                wayland
                libdecor
                libGL
                libglvnd
                fontconfig
                freetype
                alsa-lib
                libpulseaudio
                zlib
              ];
            };
          in
          # Re-pack the symlinkJoin output so the `lib/` directory
          # holds real files (or symlinks within the resource itself).
          # `zig build install` copies file-by-file via Dir.walk which
          # skips dangling symlinks; we need an inner-self-contained
          # tree.
          pkgs.runCommand "renpy-fhs-libs" { } ''
            mkdir -p $out/lib
            cp -rL ${joined}/lib/. $out/lib/
          '';
      in {
        packages.renpy-fhs-libs = renpy-fhs-libs;

        devShells.default = pkgs.mkShell {
          # Build-time tools for the Zig project.
          nativeBuildInputs = with pkgs; [
            zig                # latest stable
            zls                # LSP for editor integration
            pkg-config
            wayland-scanner    # SDL3's Wayland support build step (dvui SDL3 backend)
            wayland-protocols  # ditto
          ];

          # Native libraries the build links against. dvui's SDL3 backend
          # pulls in SDL3; SQLite is for the game library; OpenSSL is wired
          # in for HTTPS via std.crypto.tls (Zig 0.15 has TLS in std but
          # libssl.so is handy for cert bundle path).
          buildInputs = with pkgs; [
            SDL2.dev           # dvui can target SDL2 or SDL3 — keep both available
            sdl3
            sqlite.dev
            openssl
            cacert             # CA bundle for TLS to f95zone, googleapis, etc.
            aria2              # multi-protocol downloader, driven via JSON-RPC
            # X11 + Wayland client libs SDL3 may dlopen at runtime
            libx11
            libxext
            libxrandr
            libxcursor
            libxi
            wayland
            libxkbcommon
            libdecor

            # AVIF screenshots from F95Zone CDN — see decode wrapper in
            # src/image/avif.zig. Statically linked; the resulting f69
            # binary doesn't depend on libavif.so or libdav1d.so at run time.
            libavif-static
            libavif-static.dev
            dav1d-static
            dav1d-static.dev

            # libarchive — static archive for .7z / .tar.bz2 / .tar.xz
            # / .rar extraction (the formats stdlib doesn't cover).
            # See `util_archive` module in build.zig. libarchive's
            # static .a references libz / libbz2 / liblzma symbols;
            # those three are pulled in dynamically (universally
            # present on any Linux desktop).
            libarchive-static
            libarchive-static.dev
            zlib
            zlib.dev
            bzip2
            bzip2.dev
            xz
            xz.dev

            # libdbus — needed by the vendored NFDe portal backend
            # (zig-pkg/nfde) so the file picker talks XDG portal over
            # D-Bus. Dynamically linked at runtime (dbus is always a
            # system service on a desktop session).
            dbus
            dbus.dev
          ];

          # Make sure pkg-config sees the .dev outputs + SDL3 dlopens
          # libwayland-client/libxkbcommon/libX11 etc. at runtime.
          shellHook = ''
            export PKG_CONFIG_PATH="${pkgs.sdl3}/lib/pkgconfig:${pkgs.SDL2.dev}/lib/pkgconfig:${pkgs.sqlite.dev}/lib/pkgconfig:${pkgs.openssl.dev}/lib/pkgconfig:${libavif-static.dev}/lib/pkgconfig:${dav1d-static.dev}/lib/pkgconfig:${libarchive-static.dev}/lib/pkgconfig:${pkgs.zlib.dev}/share/pkgconfig:${pkgs.bzip2.dev}/lib/pkgconfig:${pkgs.xz.dev}/lib/pkgconfig:${pkgs.dbus.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [
              pkgs.wayland
              pkgs.libxkbcommon
              pkgs.libdecor
              pkgs.libx11
              pkgs.libxext
              pkgs.libxrandr
              pkgs.libxcursor
              pkgs.libxi
              pkgs.libGL
              pkgs.vulkan-loader
            ]}:''${LD_LIBRARY_PATH:-}"

            # Path to the compat resource bundle. build.zig reads this
            # and copies it into zig-out/bin/data/compat-resources/ so
            # `zig build run` picks up the FHS libs automatically.
            export F69_COMPAT_RENPY_FHS_LIBS="${renpy-fhs-libs}"

            echo "f69 dev shell"
            echo "  zig:    $(zig version)"
            echo "  zls:    $(zls --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  sdl3:   ${pkgs.sdl3.version}"
            echo "  sqlite: ${pkgs.sqlite.version}"
            echo
            if [ ! -d .zig-cache ] && ! grep -q 'dvui' build.zig.zon 2>/dev/null; then
              echo "First-time setup: fetch dvui (and any other deps) via:"
              echo "    zig fetch --save git+https://github.com/david-vanderson/dvui#main"
              echo
            fi
            echo "Next: zig build run"
          '';
        };
      });
}
