#!/usr/bin/env bash
# Build libvips and its reviewed dependency set from source, then stage a
# relocatable runtime closure for one Maven classifier.
#
# Usage:
#   build-natives/build-platform.sh PLATFORM [PDFIUM_ROOT]
#
# PDFIUM_ROOT defaults to build/pdfium-PLATFORM and must be populated by
# build-pdfium.sh or the pinned GitHub reusable PDFium workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/build-natives/versions.env"

# Host developer shells commonly export package-manager include/library flags.
# All target dependencies must come from the private prefix or pinned vcpkg
# tree, so discard those ambient search paths before configuring anything.
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS CPATH C_INCLUDE_PATH \
  CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH \
  DYLD_LIBRARY_PATH LD_LIBRARY_PATH INCLUDE LIB LIBPATH
RUSTUP_PATH="$(command -v rustup || true)"
GIT_PATH="$(command -v git || true)"
RUST_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
if [ -z "$RUSTUP_PATH" ] && [ -x "$RUST_CARGO_HOME/bin/rustup" ]; then
  RUSTUP_PATH="$RUST_CARGO_HOME/bin/rustup"
fi
if [ -n "$RUSTUP_PATH" ]; then
  RUST_BIN_DIR="${RUSTUP_PATH%/*}"
else
  RUST_BIN_DIR=/__libvips_ffm_missing_rustup__
fi
if [ -n "$GIT_PATH" ]; then
  GIT_BIN_DIR="${GIT_PATH%/*}"
else
  GIT_BIN_DIR=/__libvips_ffm_missing_git__
fi

PLATFORM="${1:?usage: $0 PLATFORM [PDFIUM_ROOT]}"
PDFIUM_ROOT="${2:-$ROOT/build/pdfium-$PLATFORM}"
RUST_TOOLCHAIN="$RUST_VERSION"
BUILD_ROOT="$ROOT/build/native-$PLATFORM"
SOURCES="$BUILD_ROOT/sources"
PREFIX="$BUILD_ROOT/prefix"
VCPKG_ROOT="$ROOT/build/vcpkg"
VCPKG_INSTALLED="$BUILD_ROOT/vcpkg_installed"
DEST="$ROOT/natives/src/main/resources/libvips-natives/$PLATFORM"
MANIFEST_ROOT="$ROOT/build-natives/vcpkg"
TRIPLET_DIR="$ROOT/build-natives/triplets"

case "$PLATFORM" in
  macos-arm64)
    TRIPLET=arm64-osx-dynamic
    JOBS="$(sysctl -n hw.logicalcpu)"
    export MACOSX_DEPLOYMENT_TARGET=12.0
    HOST_TOOL_BIN="$(dirname "$(command -v meson)")"
    export PATH="$RUST_BIN_DIR:$HOST_TOOL_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    ;;
  linux-x64)
    TRIPLET=x64-linux-dynamic
    JOBS="$(nproc)"
    export PATH="$RUST_BIN_DIR:/usr/local/bin:/usr/bin:/bin"
    ;;
  windows-x64)
    TRIPLET=x64-mingw-dynamic
    RUST_TOOLCHAIN="$RUST_VERSION-x86_64-pc-windows-gnu"
    JOBS="${NUMBER_OF_PROCESSORS:-4}"
    if [ "$GIT_BIN_DIR" = /__libvips_ffm_missing_git__ ] &&
       [ -x '/c/Program Files/Git/cmd/git.exe' ]; then
      GIT_BIN_DIR='/c/Program Files/Git/cmd'
    fi
    export PATH="$RUST_BIN_DIR:$GIT_BIN_DIR:/mingw64/bin:/usr/bin:/c/Windows/System32:/c/Windows:/c/Windows/System32/WindowsPowerShell/v1.0"
    # vcpkg.exe launches native Windows CMake, which cannot reliably discover
    # an MSYS2 compiler from the POSIX-form PATH inherited through ssh.
    export CC='C:/msys64/mingw64/bin/gcc.exe'
    export CXX='C:/msys64/mingw64/bin/g++.exe'
    ;;
  *)
    echo "unsupported platform: $PLATFORM" >&2
    exit 2
    ;;
esac

[ -d "$PDFIUM_ROOT/include" ] ||
  { echo "PDFium is not staged at $PDFIUM_ROOT; run build-pdfium.sh first" >&2; exit 1; }

verify_sha256() {
  local expected=$1 file=$2 actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  fi
  [ "$actual" = "$expected" ] ||
    { echo "SHA-256 mismatch for $file: expected $expected, got $actual" >&2; exit 1; }
}

fetch_source() {
  local name=$1
  local url=$2
  local sha=$3
  local archive="$BUILD_ROOT/downloads/$name"
  local source="$SOURCES/${name%.tar.*}"
  if [ ! -d "$source" ]; then
    mkdir -p "$BUILD_ROOT/downloads" "$source"
    if [ ! -f "$archive" ]; then
      curl --fail --location --retry 3 "$url" --output "$archive"
    fi
    verify_sha256 "$sha" "$archive"
    case "$archive" in
      *.tar.xz) tar xJf "$archive" -C "$source" --strip-components=1 ;;
      *.tar.gz) tar xzf "$archive" -C "$source" --strip-components=1 ;;
      *) echo "unknown source archive: $archive" >&2; exit 1 ;;
    esac
  fi
  printf '%s\n' "$source"
}

meson_configure() {
  local build_dir=$1 source_dir=$2
  shift 2
  local clean_flags=(
    "-Dc_args=[]"
    "-Dc_link_args=[]"
    "-Dcpp_args=[]"
    "-Dcpp_link_args=[]"
  )
  if [ -f "$build_dir/build.ninja" ]; then
    meson setup --reconfigure "$build_dir" "$source_dir" \
      "${clean_flags[@]}" "$@"
  else
    meson setup "$build_dir" "$source_dir" "${clean_flags[@]}" "$@"
  fi
}

mkdir -p "$BUILD_ROOT" "$SOURCES" "$PREFIX"

if [ ! -d "$VCPKG_ROOT/.git" ]; then
  git clone https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
fi
git -C "$VCPKG_ROOT" fetch --depth 1 origin "$VCPKG_COMMIT"
git -C "$VCPKG_ROOT" checkout --detach "$VCPKG_COMMIT"
git -C "$VCPKG_ROOT" checkout -- \
  ports/libheif/portfile.cmake ports/libheif/vcpkg.json
git -C "$VCPKG_ROOT" apply \
  "$ROOT/build-natives/vcpkg/libheif-dav1d.patch"
if [ "$PLATFORM" = windows-x64 ]; then
  if [ ! -x "$VCPKG_ROOT/vcpkg.exe" ]; then
    cmd.exe //c "$(cygpath -w "$VCPKG_ROOT/bootstrap-vcpkg.bat") -disableMetrics"
  fi
  VCPKG="$VCPKG_ROOT/vcpkg.exe"
else
  if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
    "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
  fi
  VCPKG="$VCPKG_ROOT/vcpkg"
fi

VCPKG_INSTALL_ARGS=(
  install
  --disable-metrics
  "--x-manifest-root=$MANIFEST_ROOT"
  "--x-install-root=$VCPKG_INSTALLED"
  # The pinned builtin registry ignores working-tree port edits; select the
  # reviewed libheif dav1d patch (and otherwise identical pinned ports) here.
  "--overlay-ports=$VCPKG_ROOT/ports"
  "--overlay-triplets=$TRIPLET_DIR"
  "--triplet=$TRIPLET"
)
if [ "$PLATFORM" = windows-x64 ]; then
  # The native vcpkg/CMake/Ninja process tree needs a native Windows PATH.
  # Keeping a POSIX PATH here lets compiler detection succeed but causes the
  # parallel compile processes to exit silently when their runtime DLLs cannot
  # be found.
  VCPKG_WINDOWS_PATH='C:\msys64\mingw64\bin;C:\Program Files\Git\cmd;C:\Windows\System32;C:\Windows'
  PATH="$VCPKG_WINDOWS_PATH" "$VCPKG" "${VCPKG_INSTALL_ARGS[@]}"
else
  "$VCPKG" "${VCPKG_INSTALL_ARGS[@]}"
fi

VCPKG_PREFIX="$VCPKG_INSTALLED/$TRIPLET"

# Bootstrap Rust build tools before adding target libraries to PATH and
# PKG_CONFIG_PATH. Otherwise cargo-c itself can accidentally link against the
# private runtime closure (and fail before that closure has been relocated).
if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup is required to select the pinned Rust $RUST_VERSION toolchain" >&2
  exit 1
fi
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
rustc --version | grep -Fq "rustc $RUST_VERSION " ||
  { echo "failed to activate Rust $RUST_VERSION" >&2; exit 1; }

if ! command -v cargo-cbuild >/dev/null 2>&1; then
  cargo install cargo-c --version "$CARGO_C_VERSION" --locked
fi
if ! cargo-cbuild --version | grep -Fq "$CARGO_C_VERSION"; then
  echo "cargo-c $CARGO_C_VERSION is required" >&2
  exit 1
fi
if [ "$PLATFORM" = windows-x64 ] && command -v rustup >/dev/null 2>&1; then
  rustup target add x86_64-pc-windows-gnu
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$VCPKG_PREFIX/lib/pkgconfig:$VCPKG_PREFIX/share/pkgconfig"
export CMAKE_PREFIX_PATH="$PREFIX;$VCPKG_PREFIX"
export PATH="$PREFIX/bin:$VCPKG_PREFIX/bin:$PATH"

# Install the separately source-built PDFium package into the private prefix.
cp -R "$PDFIUM_ROOT/include" "$PREFIX/"
if [ -d "$PDFIUM_ROOT/lib" ]; then cp -R "$PDFIUM_ROOT/lib/." "$PREFIX/lib/"; fi
if [ -d "$PDFIUM_ROOT/bin" ]; then cp -R "$PDFIUM_ROOT/bin/." "$PREFIX/bin/"; fi
mkdir -p "$PREFIX/lib/pkgconfig"

if [ "$PLATFORM" = windows-x64 ]; then
  if [ -f "$PREFIX/lib/pdfium.dll.lib" ]; then
    cp "$PREFIX/lib/pdfium.dll.lib" "$PREFIX/lib/pdfium.lib"
  fi
  if [ ! -f "$PREFIX/lib/libpdfium.dll.a" ] && command -v gendef >/dev/null 2>&1; then
    (cd "$PREFIX/lib" && gendef "$PREFIX/bin/pdfium.dll" &&
      dlltool -d pdfium.def -D pdfium.dll -l libpdfium.dll.a)
  fi
fi

cat > "$PREFIX/lib/pkgconfig/pdfium.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: pdfium
Description: Chromium PDFium without V8 or XFA
Version: ${PDFIUM_BRANCH#chromium/}
Libs: -L\${libdir} -lpdfium
Cflags: -I\${includedir}
EOF

VCPKG_CMAKE_ARGS=(
  "-DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
  "-DVCPKG_TARGET_TRIPLET=$TRIPLET"
  "-DVCPKG_OVERLAY_TRIPLETS=$TRIPLET_DIR"
  "-DVCPKG_INSTALLED_DIR=$VCPKG_INSTALLED"
  "-DCMAKE_INSTALL_PREFIX=$PREFIX"
  "-DCMAKE_INSTALL_LIBDIR=lib"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DBUILD_SHARED_LIBS=ON"
  "-DCMAKE_C_FLAGS="
  "-DCMAKE_CXX_FLAGS="
  "-DCMAKE_EXE_LINKER_FLAGS="
  "-DCMAKE_MODULE_LINKER_FLAGS="
  "-DCMAKE_SHARED_LINKER_FLAGS="
)

LIBRSVG_SRC="$(fetch_source "librsvg-$LIBRSVG_VERSION.tar.xz" "$LIBRSVG_URL" "$LIBRSVG_SHA256")"
LIBRSVG_OPTIONS=(
  --prefix="$PREFIX"
  --libdir=lib
  --buildtype=release
  --default-library=shared
  -Dintrospection=disabled
  -Dpixbuf=disabled
  -Drsvg-convert=disabled
  -Dpixbuf-loader=disabled
  -Ddocs=disabled
  -Dvala=disabled
  -Dtests=false
  -Davif=disabled
)
if [ "$PLATFORM" = windows-x64 ]; then
  LIBRSVG_OPTIONS+=(
    -Dtriplet=x86_64-pc-windows-gnu
    "-Dc_link_args=['-Wl,--strip-debug']"
  )
fi
meson_configure "$LIBRSVG_SRC/build-$PLATFORM" "$LIBRSVG_SRC" "${LIBRSVG_OPTIONS[@]}"
if [ "$PLATFORM" = windows-x64 ]; then
  # Rust 1.92's GNU staticlib contains two copies of a small set of kernel32
  # import members. A whole-archive DLL link rejects them as duplicate symbols.
  # Build the archive first and remove only that reviewed duplicate set.
  meson compile -C "$LIBRSVG_SRC/build-$PLATFORM" librsvg-2
  python3 "$ROOT/build-natives/deduplicate-rust-archive.py" \
    "$LIBRSVG_SRC/build-$PLATFORM/rsvg/librsvg_2.a"
fi
meson compile -C "$LIBRSVG_SRC/build-$PLATFORM" -j "$JOBS"
meson install -C "$LIBRSVG_SRC/build-$PLATFORM"

IMAGEQUANT_SRC="$(fetch_source "libimagequant-$IMAGEQUANT_VERSION.tar.gz" "$IMAGEQUANT_URL" "$IMAGEQUANT_SHA256")"
meson_configure "$IMAGEQUANT_SRC/build-$PLATFORM" "$IMAGEQUANT_SRC" \
  --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=shared
meson compile -C "$IMAGEQUANT_SRC/build-$PLATFORM" -j "$JOBS"
meson install -C "$IMAGEQUANT_SRC/build-$PLATFORM"

UHDR_SRC="$(fetch_source "libultrahdr-$UHDR_VERSION.tar.gz" "$UHDR_URL" "$UHDR_SHA256")"
cmake -S "$UHDR_SRC" -B "$UHDR_SRC/build-$PLATFORM" \
  "${VCPKG_CMAKE_ARGS[@]}" \
  -DUHDR_BUILD_EXAMPLES=OFF -DUHDR_BUILD_TESTS=OFF \
  -DUHDR_BUILD_BENCHMARK=OFF -DUHDR_BUILD_FUZZERS=OFF \
  -DUHDR_ENABLE_INSTALL=ON -DUHDR_BUILD_DEPS=OFF
cmake --build "$UHDR_SRC/build-$PLATFORM" --config Release -j "$JOBS"
cmake --install "$UHDR_SRC/build-$PLATFORM" --config Release

VIPS_SRC="$(fetch_source "vips-$LIBVIPS_VERSION.tar.xz" "$LIBVIPS_URL" "$LIBVIPS_SHA256")"
VIPS_OPTIONS=(
  --prefix="$PREFIX"
  --libdir=lib
  --buildtype=release
  --default-library=shared
  -Dauto_features=disabled
  -Ddeprecated=false
  -Dexamples=false
  -Dcplusplus=false
  -Ddocs=false
  -Dintrospection=disabled
  -Dmodules=disabled
  -Darchive=enabled
  -Dcgif=disabled
  -Dexif=enabled
  -Dfontconfig=enabled
  -Dheif=enabled
  -Dheif-module=disabled
  -Dhighway=enabled
  -Dimagequant=enabled
  -Djpeg=enabled
  -Djpeg-xl=enabled
  -Djpeg-xl-module=disabled
  -Dlcms=enabled
  -Dopenjpeg=enabled
  -Dpangocairo=enabled
  -Dpdfium=enabled
  -Dpng=enabled
  -Drsvg=enabled
  -Dtiff=enabled
  -Duhdr=enabled
  -Dwebp=enabled
  -Dzlib=enabled
  -Dmagick=disabled
  -Dmagick-module=disabled
  -Dpoppler=disabled
  -Draw=disabled
  -Dopenexr=disabled
  -Dopenslide=disabled
  -Dcfitsio=disabled
  -Dfftw=disabled
  -Dmatio=disabled
  -Dnifti=disabled
  -Dorc=disabled
  -Dquantizr=disabled
  -Dspng=disabled
  -Dnsgif=true
  -Dppm=false
  -Danalyze=false
  -Dradiance=false
)
meson_configure "$VIPS_SRC/build-$PLATFORM" "$VIPS_SRC" "${VIPS_OPTIONS[@]}"
meson compile -C "$VIPS_SRC/build-$PLATFORM" -j "$JOBS"
meson install -C "$VIPS_SRC/build-$PLATFORM"

HEIC_FIXTURE="$(find "$VCPKG_ROOT/buildtrees/libheif" \
  -path '*/tests/data/rainbow-451x461.heic' -type f -print -quit)"
[ -n "$HEIC_FIXTURE" ] ||
  { echo "libheif HEIC release fixture was not found" >&2; exit 1; }
HEIC_SMOKE_OUTPUT="$BUILD_ROOT/heic-smoke.png"
case "$PLATFORM" in
  macos-arm64)
    DYLD_LIBRARY_PATH="$PREFIX/lib:$VCPKG_PREFIX/lib" \
      "$PREFIX/bin/vips" copy "$HEIC_FIXTURE" "$HEIC_SMOKE_OUTPUT"
    ;;
  linux-x64)
    LD_LIBRARY_PATH="$PREFIX/lib:$VCPKG_PREFIX/lib" \
      "$PREFIX/bin/vips" copy "$HEIC_FIXTURE" "$HEIC_SMOKE_OUTPUT"
    ;;
  windows-x64)
    PATH="$PREFIX/bin:$VCPKG_PREFIX/bin:$PATH" \
      "$PREFIX/bin/vips" copy "$HEIC_FIXTURE" "$HEIC_SMOKE_OUTPUT"
    ;;
esac
case "$PLATFORM" in
  macos-arm64)
    DYLD_LIBRARY_PATH="$PREFIX/lib:$VCPKG_PREFIX/lib" \
      "$PREFIX/bin/vipsheader" "$HEIC_SMOKE_OUTPUT" | grep -Fq '451x461'
    ;;
  linux-x64)
    LD_LIBRARY_PATH="$PREFIX/lib:$VCPKG_PREFIX/lib" \
      "$PREFIX/bin/vipsheader" "$HEIC_SMOKE_OUTPUT" | grep -Fq '451x461'
    ;;
  windows-x64)
    PATH="$PREFIX/bin:$VCPKG_PREFIX/bin:$PATH" \
      "$PREFIX/bin/vipsheader" "$HEIC_SMOKE_OUTPUT" | grep -Fq '451x461'
    ;;
esac
rm -f "$HEIC_SMOKE_OUTPUT"
echo "Decoded representative 451x461 HEIC/HEVC fixture through libheif/libde265"

AVIF_FIXTURE="$(find "$VCPKG_ROOT/buildtrees/libheif" \
  -path '*/examples/example.avif' -type f -print -quit)"
[ -n "$AVIF_FIXTURE" ] ||
  { echo "libheif AVIF release fixture was not found" >&2; exit 1; }
AVIF_SMOKE_OUTPUT="$BUILD_ROOT/avif-smoke.png"
case "$PLATFORM" in
  macos-arm64)
    DYLD_LIBRARY_PATH="$PREFIX/lib:$VCPKG_PREFIX/lib" \
      "$PREFIX/bin/vips" copy "$AVIF_FIXTURE" "$AVIF_SMOKE_OUTPUT"
    ;;
  linux-x64)
    LD_LIBRARY_PATH="$PREFIX/lib:$VCPKG_PREFIX/lib" \
      "$PREFIX/bin/vips" copy "$AVIF_FIXTURE" "$AVIF_SMOKE_OUTPUT"
    ;;
  windows-x64)
    PATH="$PREFIX/bin:$VCPKG_PREFIX/bin:$PATH" \
      "$PREFIX/bin/vips" copy "$AVIF_FIXTURE" "$AVIF_SMOKE_OUTPUT"
    ;;
esac
case "$PLATFORM" in
  macos-arm64)
    DYLD_LIBRARY_PATH="$PREFIX/lib:$VCPKG_PREFIX/lib" \
      "$PREFIX/bin/vipsheader" "$AVIF_SMOKE_OUTPUT" | grep -Fq '800x533'
    ;;
  linux-x64)
    LD_LIBRARY_PATH="$PREFIX/lib:$VCPKG_PREFIX/lib" \
      "$PREFIX/bin/vipsheader" "$AVIF_SMOKE_OUTPUT" | grep -Fq '800x533'
    ;;
  windows-x64)
    PATH="$PREFIX/bin:$VCPKG_PREFIX/bin:$PATH" \
      "$PREFIX/bin/vipsheader" "$AVIF_SMOKE_OUTPUT" | grep -Fq '800x533'
    ;;
esac
rm -f "$AVIF_SMOKE_OUTPUT"
echo "Decoded representative 800x533 AVIF fixture through libheif/dav1d"

if [ "$PLATFORM" = windows-x64 ]; then
  # MinGW-built C++ and Rust libraries depend on these toolchain runtimes.
  # They are not vcpkg ports, so stage the exact DLLs used by this compiler.
  for runtime in libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll; do
    runtime_path="/mingw64/bin/$runtime"
    [ -f "$runtime_path" ] ||
      { echo "missing MinGW runtime $runtime" >&2; exit 1; }
    cp "$runtime_path" "$PREFIX/bin/"
  done
fi

rm -rf "$DEST"
mkdir -p "$DEST"
python3 "$ROOT/build-natives/stage-runtime.py" \
  "$PLATFORM" "$DEST" "$PREFIX" "$VCPKG_PREFIX"
python3 "$ROOT/build-natives/audit-runtime.py" "$PLATFORM" "$DEST"
grep -Eiq 'dav1d' "$DEST/manifest.txt" ||
  { echo "staged closure does not contain dav1d" >&2; exit 1; }
if grep -Eiq 'aom|cgif' "$DEST/manifest.txt"; then
  echo "staged closure unexpectedly contains AOM or cgif" >&2
  exit 1
fi

mkdir -p "$DEST/licenses/vcpkg" "$DEST/licenses/pdfium"
find "$VCPKG_PREFIX/share" -mindepth 2 -maxdepth 2 -type f -name copyright \
  -exec sh -c 'd="$1/licenses/vcpkg/$(basename "$(dirname "$2")")"; mkdir -p "$d"; cp "$2" "$d/copyright"' sh "$DEST" {} \;
if [ -d "$PDFIUM_ROOT/licenses" ]; then
  cp -R "$PDFIUM_ROOT/licenses/." "$DEST/licenses/pdfium/"
fi
if [ -f "$PDFIUM_ROOT/LICENSE" ]; then
  cp "$PDFIUM_ROOT/LICENSE" "$DEST/licenses/pdfium/PDFium-LICENSE.txt"
fi
if [ -f "$PDFIUM_ROOT/args.gn" ]; then
  cp "$PDFIUM_ROOT/args.gn" "$DEST/PDFIUM-ARGS.gn"
fi
cp "$VIPS_SRC/LICENSE" "$DEST/LICENSE-libvips.txt"
cp "$IMAGEQUANT_SRC/COPYRIGHT" "$DEST/LICENSE-libimagequant.txt"
cp "$UHDR_SRC/LICENSE" "$DEST/LICENSE-libultrahdr.txt"
cp "$LIBRSVG_SRC/COPYING.LIB" "$DEST/LICENSE-librsvg.txt"
python3 "$ROOT/build-natives/collect-rust-licenses.py" \
  "$LIBRSVG_SRC" "$DEST/licenses/rust"

if [ "$PLATFORM" = windows-x64 ]; then
  mkdir -p "$DEST/licenses/mingw-runtime"
  for component in gcc-libs libwinpthread winpthreads; do
    if [ -d "/mingw64/share/licenses/$component" ]; then
      cp -R "/mingw64/share/licenses/$component" \
        "$DEST/licenses/mingw-runtime/"
    fi
  done
fi

"$VCPKG" list --x-install-root="$VCPKG_INSTALLED" |
  LC_ALL=C sort > "$DEST/VCPKG-COMPONENTS.txt"

RECORDED_VIPS_OPTIONS="${VIPS_OPTIONS[*]}"
RECORDED_VIPS_OPTIONS="${RECORDED_VIPS_OPTIONS//$ROOT/<source-root>}"

cat > "$DEST/BUILD-INFO.txt" <<EOF
libvips $LIBVIPS_VERSION built from source
platform: $PLATFORM
vcpkg baseline: $VCPKG_COMMIT
PDFium: $PDFIUM_VERSION ($PDFIUM_BRANCH, revision $PDFIUM_REVISION)
PDFium build scripts: https://github.com/bblanchon/pdfium-binaries/commit/$PDFIUM_BUILD_COMMIT
librsvg: $LIBRSVG_VERSION (Rust, cargo-c $CARGO_C_VERSION)
rustc: $(rustc --version)
cargo: $(cargo --version)
cargo-c: $(cargo-cbuild --version)
HEIC decode smoke: libheif rainbow-451x461.heic -> 451x461 PNG
AVIF decode smoke: libheif example.avif -> 800x533 PNG via dav1d
Meson options: $RECORDED_VIPS_OPTIONS
compiler: $(${CC:-cc} --version 2>/dev/null | head -1 || true)
MinGW runtime packages: $(if command -v pacman >/dev/null 2>&1; then pacman -Q mingw-w64-x86_64-gcc-libs mingw-w64-x86_64-libwinpthread 2>/dev/null | tr '\n' ';'; fi)
replacement: set LIBVIPS_FFM_LIBDIR or -Dlibvipsffm.libdir
EOF

cat > "$DEST/CORRESPONDING-SOURCE.txt" <<EOF
All native code in this classifier was built from source.

libvips: $LIBVIPS_URL
libimagequant: $IMAGEQUANT_URL
libultrahdr: $UHDR_URL
librsvg: $LIBRSVG_URL
vcpkg ports and checksummed sources: https://github.com/microsoft/vcpkg/commit/$VCPKG_COMMIT
PDFium: https://pdfium.googlesource.com/pdfium/+/$PDFIUM_REVISION
PDFium release branch: $PDFIUM_BRANCH
PDFium build scripts: https://github.com/bblanchon/pdfium-binaries/commit/$PDFIUM_BUILD_COMMIT
MinGW runtime package sources (Windows only): https://repo.msys2.org/mingw/sources/

Exact component versions are in VCPKG-COMPONENTS.txt and BUILD-INFO.txt.
The complete build recipes are the build-natives scripts in this source tree.
EOF

cat > "$DEST/THIRD-PARTY-NOTICES.md" <<'EOF'
# Native third-party notices

This classifier contains a from-source build of libvips and its reviewed
runtime dependency closure. Complete per-component license texts are under
`licenses/`; the libvips, libimagequant, and libultrahdr licenses are
also included at the root of this directory, together with librsvg's license.

Enabled format integrations are libjpeg-turbo, PNG, TIFF, WebP, GIF decoding
through nsgif, AVIF decoding through dav1d, HEIC decoding through libde265,
UltraHDR, JPEG XL, SVG, PDFium, and OpenJPEG. GIF and AVIF encoding are
deliberately absent.
ImageMagick, GraphicsMagick, Poppler, x265, and dynamic libvips modules are
not included.
EOF

echo "Built and staged $PLATFORM in $DEST"
