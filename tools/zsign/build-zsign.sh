#!/usr/bin/env bash
#
# Reproducibly builds a modern zsign.exe for Windows (x86-64) from source using
# MSYS2 / MinGW-w64. "Modern" = SHA256-only CodeDirectory + canonical DER
# entitlements by default (required by current iOS; older dual-SHA1 output gets
# AMFI-killed on launch).
#
# We build zsign ourselves rather than ship a prebuilt binary because it signs
# with the user's Apple certificate: an auditable, reproducible build is the
# trustworthy choice.
#
# Prerequisites: MSYS2 (https://www.msys2.org/, or `winget install MSYS2.MSYS2`).
# Run from an MSYS2 shell:  bash tools/zsign/build-zsign.sh
#
# Output: src/iPASide.Engine/ipaside_engine/vendor/zsign.exe (git-ignored).
set -euo pipefail
export PATH="/mingw64/bin:/usr/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$HERE/.build/zsign-src"
VENDOR="$REPO/src/iPASide.Engine/ipaside_engine/vendor"

echo "== installing MinGW-w64 toolchain (OpenSSL/zlib/minizip prebuilt) =="
pacman -S --noconfirm --needed \
  mingw-w64-x86_64-gcc mingw-w64-x86_64-openssl \
  mingw-w64-x86_64-zlib mingw-w64-x86_64-minizip mingw-w64-x86_64-make git

echo "== cloning zsign =="
rm -rf "$WORK"
git clone --depth 1 https://github.com/zhlynn/zsign.git "$WORK"
cd "$WORK"

# MinGW already provides ssize_t; zsign only needs its own typedef under MSVC.
echo "== patching certcheck.cpp (ssize_t guard for MinGW) =="
sed -i 's/^typedef int ssize_t;/#ifdef _MSC_VER\ntypedef int ssize_t;\n#endif/' src/certcheck.cpp

# Windows minizip defaults to 32-bit fseek (USE_FILE32API in ioapi.h), so zsign cannot
# seek to the central directory of an IPA larger than ~2GB - large games (e.g. a 4GB PUBG
# IPA) fail immediately with "Unzip failed!". Route archive read/write through iowin32's
# 64-bit Win32 file API instead. Fails loudly if upstream drifts, rather than silently
# reverting to the 32-bit path.
echo "== patching archive.cpp (64-bit file I/O for >2GB IPAs) =="
git apply "$HERE/win-largefile.patch"

echo "== compiling =="
WIN=build/windows/vs2022/zsign/src
OBJ=.obj
rm -rf "$OBJ"
mkdir -p "$OBJ"
INC="-I$WIN -Isrc -Isrc/common -Isrc/third-party/zlib -Isrc/third-party/minizip $(pkg-config --cflags openssl)"

# C sources (vendored zlib + minizip, incl. Windows iowin32).
for f in src/third-party/zlib/*.c \
         src/third-party/minizip/ioapi.c src/third-party/minizip/iowin32.c \
         src/third-party/minizip/zip.c src/third-party/minizip/unzip.c; do
  gcc -O3 $INC -c "$f" -o "$OBJ/$(echo "$f" | tr '/' '_').o"
done

# C++ sources. MSVC pulls in libc headers transitively; GCC needs them forced.
for f in src/*.cpp src/common/*.cpp "$WIN/getopt.cpp" "$WIN/iconv.cpp"; do
  g++ -std=c++11 -O3 -DZSIGN_VERSION=iPASide -include cstdint -include cstring -include cstdio -include cstdlib \
      -Wno-unused-result -Wno-deprecated-declarations $INC -c "$f" -o "$OBJ/$(echo "$f" | tr '/' '_').o"
done

echo "== linking (static) =="
mkdir -p "$VENDOR"
g++ -O3 -static -static-libgcc -static-libstdc++ -o "$VENDOR/zsign.exe" "$OBJ"/*.o \
  $(pkg-config --libs --static openssl) -lshlwapi -lws2_32 -lcrypt32 -lbcrypt

echo "== done -> $VENDOR/zsign.exe =="
"$VENDOR/zsign.exe" -v
