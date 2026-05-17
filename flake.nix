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
        # copied to `<data_root>/compat-resources/<id>/lib/`. The
        # compat recipes prepend `<that>/lib` to LD_LIBRARY_PATH so the
        # game's bundled runtime (SDL2 dlopen, nwjs, Unity loader) can
        # find libX11.so.6, libwayland-client.so.0, etc. — the
        # libraries missing from standard loader paths on NixOS / musl
        # / minimal containers.
        #
        # `bundleFhsLibs id paths` re-packs a symlinkJoin so the `lib/`
        # tree is inner-self-contained (no dangling links into the
        # store) — `zig build install`'s Dir.walk skips dangling
        # symlinks. Each engine version gets its own bundle so a NixOS
        # user pulling one engine's compat doesn't get every other
        # engine's transitive libs.
        bundleFhsLibs = id: paths:
          let
            joined = pkgs.symlinkJoin { name = "${id}-symlinks"; inherit paths; };
          in
          pkgs.runCommand id { } ''
            mkdir -p $out/lib
            cp -rL ${joined}/lib/. $out/lib/
          '';

        # ----- Ren'Py 7 ----------------------------------------------
        # GL renderer (`gldraw.so`, `gl.so`) links libGLEW.so.1.7
        # statically into the Ren'Py runtime — its transitive deps
        # libXmu.so.6 + libGLU.so.1 must therefore be on the loader
        # path. Ren'Py 8 dropped GLEW (uses SDL2 directly) — see the
        # `renpy8-fhs-libs` bundle below for the leaner set.
        renpy7-fhs-libs = bundleFhsLibs "renpy7-fhs-libs" (with pkgs; [
          libx11 libxext libxi libxcursor libxrandr libxinerama libxxf86vm
          libxmu libGLU
          libxkbcommon wayland libdecor
          libGL libglvnd
          fontconfig freetype alsa-lib libpulseaudio zlib
        ]);

        # ----- Ren'Py 8 ----------------------------------------------
        # SDL2 video deps only — no GLEW/GLU/Xmu. Same X11/Wayland +
        # GL surface as renpy7 but without the renderer-shim
        # transitives that Ren'Py 8 doesn't load.
        renpy8-fhs-libs = bundleFhsLibs "renpy8-fhs-libs" (with pkgs; [
          libx11 libxext libxi libxcursor libxrandr libxinerama libxxf86vm
          libxkbcommon wayland libdecor
          libGL libglvnd
          fontconfig freetype alsa-lib libpulseaudio zlib
        ]);

        # ----- RPGM-MV / RPGM-MZ (nwjs runtime) ----------------------
        # Lib set distilled from the `fix-linux-games.sh` / `nixos-
        # libs.sh` field-tested helpers: everything the bundled nwjs
        # (Chromium runtime) dlopens on a stripped host, plus the NSS
        # internals (`libsoftokn3`, `libfreebl3`, `libssl3`,
        # `libnssckbi`) that Chrome resolves lazily after process
        # start. The X11 surface is wide because nwjs uses Chromium's
        # full X11 backend (composite/damage/randr/screensaver/etc.),
        # not just a basic X11 hook.
        rpgm-mv-fhs-libs = bundleFhsLibs "rpgm-mv-fhs-libs" (with pkgs; [
          # ---- X11 surface (Chromium X11 backend) ----
          libx11 libxcb
          xorg.libXcomposite xorg.libXcursor xorg.libXdamage xorg.libXext
          xorg.libXfixes xorg.libXi xorg.libXrender xorg.libXtst
          xorg.libXScrnSaver xorg.libXrandr xorg.libXau xorg.libXdmcp
          libxkbcommon
          # ---- GTK3 + accessibility + image stack ----
          gtk3 glib pango cairo gdk-pixbuf at-spi2-atk at-spi2-core atk
          fribidi fontconfig freetype harfbuzz pixman libpng
          # ---- Chromium sandbox / security stack ----
          # nss exposes libnss3 + the dlopen'd libsoftokn3/libfreebl3/
          # libssl3/libnssckbi internals as files inside its lib/.
          nss nspr cups dbus expat
          # ---- GPU / video output ----
          libdrm libxshmfence mesa libgbm libGL libglvnd
          # ---- Audio ----
          alsa-lib libpulseaudio
          # ---- Misc ----
          zlib
        ]);

        # ----- Unity (Linux player) ----------------------------------
        # SCAFFOLD — typical Unity-on-Linux pain points are libstdc++
        # version skew, libcurl-gnutls vs libcurl-openssl, and
        # missing libpng12. Real list emerges from `ldd <Game.x86_64>`
        # on the first failing game. Seed with the historically
        # painful set so the bundle is non-empty for the recipe.
        unity-fhs-libs = bundleFhsLibs "unity-fhs-libs" (with pkgs; [
          # X11 / window surface
          libx11 libxext libxcursor libxrandr libxi libxinerama libxkbcommon
          # GL
          libGL libglvnd
          # Audio
          alsa-lib libpulseaudio
          # Fonts / misc
          fontconfig freetype zlib
          # Common offender: many older Unity titles link libcurl-gnutls
          curl
        ]);
      in {
        packages.renpy7-fhs-libs = renpy7-fhs-libs;
        packages.renpy8-fhs-libs = renpy8-fhs-libs;
        packages.rpgm-mv-fhs-libs = rpgm-mv-fhs-libs;
        packages.unity-fhs-libs = unity-fhs-libs;

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

            # Paths to the compat resource bundles. build.zig reads
            # each one and copies it into
            # `zig-out/bin/data/compat-resources/<id>/` so `zig build
            # run` picks up the FHS libs automatically.
            export F69_COMPAT_RENPY7_FHS_LIBS="${renpy7-fhs-libs}"
            export F69_COMPAT_RENPY8_FHS_LIBS="${renpy8-fhs-libs}"
            export F69_COMPAT_RPGM_MV_FHS_LIBS="${rpgm-mv-fhs-libs}"
            export F69_COMPAT_UNITY_FHS_LIBS="${unity-fhs-libs}"

            echo "f69 dev shell  (target: f69 0.9.0)"
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
