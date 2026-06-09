let
  pkgs = import <nixpkgs> { };
  cross = pkgs.pkgsCross.mingwW64;
  dav1d = cross.dav1d.overrideAttrs (o: {
    mesonFlags = (o.mesonFlags or [ ]) ++ [ "-Ddefault_library=static" "-Denable_tools=false" "-Denable_tests=false" ];
  });
  # decode-only libavif — clean custom derivation (avoids nixpkgs' aom/yuv/gtest/pixbuf deps
  # that fail to cross-build for mingw). libyuv is vendored into libavif itself.
  libavif = cross.stdenv.mkDerivation {
    pname = "libavif";
    inherit (pkgs.libavif) version src;
    nativeBuildInputs = [ pkgs.buildPackages.cmake pkgs.buildPackages.pkg-config ];
    buildInputs = [ dav1d ];
    cmakeFlags = [
      "-DBUILD_SHARED_LIBS=OFF" "-DAVIF_CODEC_DAV1D=SYSTEM" "-DAVIF_CODEC_AOM=OFF"
      "-DAVIF_BUILD_APPS=OFF" "-DAVIF_BUILD_GDK_PIXBUF=OFF" "-DAVIF_BUILD_TESTS=OFF"
      "-DAVIF_LIBYUV=OFF" "-DAVIF_LIBSHARPYUV=OFF" "-DAVIF_LIBXML2=OFF"
    ];
    outputs = [ "out" "dev" ];
  };
  libs = [
    cross.libarchive cross.zlib cross.bzip2 cross.xz cross.zstd cross.lz4
    cross.nettle cross.libxml2 libavif dav1d
  ];
  outs = pkgs.lib.concatMap
    (p: builtins.filter (x: x != null) [ (p.dev or null) (p.lib or null) p ])
    libs;
in pkgs.symlinkJoin { name = "f69-win-deps"; paths = outs; }
