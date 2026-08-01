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
    # setup-msys2 does not retain the hosted runner's Cargo directory on PATH.
    # Resolve it from the dynamic Windows profile instead of assuming a user.
    if [ "$RUST_BIN_DIR" = /__libvips_ffm_missing_rustup__ ] &&
       [ -n "${USERPROFILE:-}" ]; then
      WINDOWS_USER_HOME="$(cygpath -u "$USERPROFILE")"
      WINDOWS_CARGO_HOME="$WINDOWS_USER_HOME/.cargo"
      if [ -x "$WINDOWS_CARGO_HOME/bin/rustup.exe" ]; then
        RUST_CARGO_HOME="$WINDOWS_CARGO_HOME"
        RUSTUP_PATH="$RUST_CARGO_HOME/bin/rustup.exe"
        RUST_BIN_DIR="$RUST_CARGO_HOME/bin"
      fi
    fi
    if [ "$GIT_BIN_DIR" = /__libvips_ffm_missing_git__ ] &&
       [ -x '/c/Program Files/Git/cmd/git.exe' ]; then
      GIT_BIN_DIR='/c/Program Files/Git/cmd'
    fi
    export PATH="$RUST_BIN_DIR:$GIT_BIN_DIR:/mingw64/bin:/usr/bin:/c/Windows/System32:/c/Windows:/c/Windows/System32/WindowsPowerShell/v1.0"
    # setup-msys2 may install under any runner drive. Discover the compiler
    # from the active shell, then also expose its native path to vcpkg.exe and
    # the compiler wrapper scripts used by native Windows CMake/Ninja.
    MINGW_GCC_PATH="$(command -v x86_64-w64-mingw32-gcc || true)"
    if [ -z "$MINGW_GCC_PATH" ]; then
      echo "x86_64-w64-mingw32-gcc is required for windows-x64" >&2
      exit 1
    fi
    MINGW_BIN_POSIX="${MINGW_GCC_PATH%/*}"
    MINGW_PREFIX_POSIX="${MINGW_BIN_POSIX%/bin}"
    MINGW_BIN_MIXED="$(cygpath -m "$MINGW_BIN_POSIX")"
    export LIBVIPS_FFM_MINGW_BIN="$MINGW_BIN_MIXED"
    # These variables also reach native Windows CMake processes, so use paths
    # understood on both sides of the MSYS2 process boundary.
    export CC="$MINGW_BIN_MIXED/gcc.exe"
    export CXX="$MINGW_BIN_MIXED/g++.exe"
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
# Git for Windows defaults to CRLF checkout. Keep the reviewed overlay patch
# byte-compatible across hosts before restoring the two files it modifies.
git -C "$VCPKG_ROOT" config core.autocrlf false
git -C "$VCPKG_ROOT" config core.eol lf
git -C "$VCPKG_ROOT" checkout --force "$VCPKG_COMMIT" -- \
  ports/libheif/portfile.cmake ports/libheif/vcpkg.json
git -C "$VCPKG_ROOT" apply --ignore-space-change --ignore-whitespace \
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
  VCPKG_WINDOWS_PATH="$LIBVIPS_FFM_MINGW_BIN;C:\\Program Files\\Git\\cmd;C:\\Windows\\System32;C:\\Windows"
  if ! PATH="$VCPKG_WINDOWS_PATH" "$VCPKG" "${VCPKG_INSTALL_ARGS[@]}"; then
    # vcpkg reports compiler-detection failures only by naming its private
    # logs. Surface the relevant files in hosted CI so failures are actionable.
    for log in \
      "$VCPKG_ROOT"/buildtrees/detect_compiler/config-x64-mingw-dynamic-*.log; do
      if [ -f "$log" ]; then
        echo "===== $log =====" >&2
        sed -n '1,240p' "$log" >&2
      fi
    done
    exit 1
  fi
else
  "$VCPKG" "${VCPKG_INSTALL_ARGS[@]}"
fi

VCPKG_PREFIX="$VCPKG_INSTALLED/$TRIPLET"

if [ "$PLATFORM" = windows-x64 ]; then
  # Meson is a native Windows Python process in MINGW64. Route every compiler
  # invocation through the same wrappers used by vcpkg so cc1.exe and linker
  # subprocesses always inherit the MinGW runtime DLL directory.
  export CC="$(cygpath -m "$TRIPLET_DIR/mingw-gcc.cmd")"
  export CXX="$(cygpath -m "$TRIPLET_DIR/mingw-gxx.cmd")"
fi

# Bootstrap Rust build tools before adding target libraries to PATH and
# PKG_CONFIG_PATH. Otherwise cargo-c itself can accidentally link against the
# private runtime closure (and fail before that closure has been relocated).
if [ -z "$RUSTUP_PATH" ] || [ ! -x "$RUSTUP_PATH" ]; then
  echo "rustup is required to select the pinned Rust $RUST_VERSION toolchain" >&2
  exit 1
fi
"$RUSTUP_PATH" toolchain install "$RUST_TOOLCHAIN" --profile minimal
export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
RUSTC_PATH="$("$RUSTUP_PATH" which --toolchain "$RUST_TOOLCHAIN" rustc)"
if [ "$PLATFORM" = windows-x64 ]; then
  RUSTC_PATH="$(cygpath -u "$RUSTC_PATH")"
fi
RUST_TOOLCHAIN_BIN="${RUSTC_PATH%/*}"
export PATH="$RUST_CARGO_HOME/bin:$RUST_TOOLCHAIN_BIN:$PATH"
rustc --version | grep -Fq "rustc $RUST_VERSION " ||
  { echo "failed to activate Rust $RUST_VERSION" >&2; exit 1; }

if ! command -v cargo-cbuild >/dev/null 2>&1; then
  if [ "$PLATFORM" = windows-x64 ]; then
    # The upstream pinned release provides a self-contained Windows-GNU build.
    # cargo-c is a build-time tool only; using this checksummed executable also
    # avoids native Cargo losing MSYS2 compiler state across CreateProcess.
    CARGO_C_ARCHIVE="$BUILD_ROOT/downloads/cargo-c-windows-gnu.zip"
    mkdir -p "$BUILD_ROOT/downloads" "$RUST_CARGO_HOME/bin"
    if [ ! -f "$CARGO_C_ARCHIVE" ]; then
      curl --fail --location --retry 3 "$CARGO_C_WINDOWS_GNU_URL" \
        --output "$CARGO_C_ARCHIVE"
    fi
    verify_sha256 "$CARGO_C_WINDOWS_GNU_SHA256" "$CARGO_C_ARCHIVE"
    unzip -j -o "$CARGO_C_ARCHIVE" '*.exe' -d "$RUST_CARGO_HOME/bin"
  else
    cargo install cargo-c --version "$CARGO_C_VERSION" --locked
  fi
fi
if ! cargo-cbuild --version | grep -Fq "$CARGO_C_VERSION"; then
  echo "cargo-c $CARGO_C_VERSION is required" >&2
  exit 1
fi
if [ "$PLATFORM" = windows-x64 ]; then
  "$RUSTUP_PATH" target add x86_64-pc-windows-gnu
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
if [ "$PLATFORM" = windows-x64 ]; then
  # cargo-c's Windows-GNU staticlib aggregation can leave GNU ar processing
  # the already-built Rust archive indefinitely. Meson links the native
  # dependencies itself, so use Cargo's raw staticlib and avoid that redundant
  # aggregation step. Keep this as a reviewed, version-pinned source patch.
  LIBRSVG_WINDOWS_PATCH="$ROOT/build-natives/patches/librsvg-windows-raw-staticlib.patch"
  if patch --batch --forward --dry-run -p1 -d "$LIBRSVG_SRC" \
      < "$LIBRSVG_WINDOWS_PATCH" >/dev/null; then
    patch --batch --forward -p1 -d "$LIBRSVG_SRC" < "$LIBRSVG_WINDOWS_PATCH"
  elif grep -Fqx 'crate-type = ["staticlib"]' "$LIBRSVG_SRC/librsvg-c/Cargo.toml" &&
       grep -Fq "output: '@0@librsvg_c.@1@'.format(lib_prefix, ext_static)" \
         "$LIBRSVG_SRC/rsvg/meson.build" &&
       grep -Fq "'--command=build'" "$LIBRSVG_SRC/rsvg/meson.build"; then
    echo "librsvg Windows raw-staticlib patch is already applied"
  else
    echo "librsvg Windows raw-staticlib patch does not apply cleanly" >&2
    exit 1
  fi
fi
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
    "-Dc_link_args=['-Wl,--strip-debug','-Wl,--allow-multiple-definition']"
  )
fi
meson_configure "$LIBRSVG_SRC/build-$PLATFORM" "$LIBRSVG_SRC" "${LIBRSVG_OPTIONS[@]}"
if [ "$PLATFORM" = windows-x64 ]; then
  # Rust 1.92's GNU staticlib contains two copies of a small set of kernel32
  # import members. Validate that exact reviewed set before the narrowly scoped
  # allow-multiple-definition DLL link; external ar hangs on this large archive.
  meson compile -C "$LIBRSVG_SRC/build-$PLATFORM" librsvg-2
  python3 "$ROOT/build-natives/validate-rust-archive.py" \
    "$LIBRSVG_SRC/build-$PLATFORM/rsvg/liblibrsvg_c.a"
fi
meson compile -C "$LIBRSVG_SRC/build-$PLATFORM" -j "$JOBS"
meson install -C "$LIBRSVG_SRC/build-$PLATFORM"

IMAGEQUANT_SRC="$(fetch_source "libimagequant-$IMAGEQUANT_VERSION.tar.gz" "$IMAGEQUANT_URL" "$IMAGEQUANT_SHA256")"
IMAGEQUANT_LIBRARY_TYPE=shared
if [ "$PLATFORM" = windows-x64 ]; then
  # Meson's MinGW DLL import-library scan leaves nm running indefinitely for
  # libimagequant. Embed this small dependency into libvips on Windows.
  IMAGEQUANT_LIBRARY_TYPE=static
fi
meson_configure "$IMAGEQUANT_SRC/build-$PLATFORM" "$IMAGEQUANT_SRC" \
  --prefix="$PREFIX" --libdir=lib --buildtype=release \
  --default-library="$IMAGEQUANT_LIBRARY_TYPE"
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
if [ "$PLATFORM" = windows-x64 ]; then
  # Meson's Windows ABI-stamp optimization scans every generated import
  # library with nm. The hosted MinGW nm process can remain stuck indefinitely
  # after a successful DLL link. Meson explicitly falls back to a dummy stamp
  # when nm fails, which only means downstream targets relink after changes;
  # it does not alter the DLL or its import library. Limit the override to this
  # compile so librsvg's required export-definition generator keeps real nm.
  NM="$(cygpath -m "$TRIPLET_DIR/meson-nm-disabled.cmd")" \
    meson compile -C "$VIPS_SRC/build-$PLATFORM" -j "$JOBS"
else
  meson compile -C "$VIPS_SRC/build-$PLATFORM" -j "$JOBS"
fi
meson install -C "$VIPS_SRC/build-$PLATFORM"

HEIC_FIXTURE="$BUILD_ROOT/fixtures/rainbow-451x461.heic"
HEIC_FIXTURE_URL=https://raw.githubusercontent.com/strukturag/libheif/2c4bbb54c2738d4a5efbbe3e5fa1d5d76bb88eb0/tests/data/rainbow-451x461.heic
HEIC_FIXTURE_SHA256=4b2ce727f093944975f143ba2b39c4c64511b766d94552f8d51a755916e7f983
mkdir -p "${HEIC_FIXTURE%/*}"
curl --fail --location --retry 3 "$HEIC_FIXTURE_URL" \
  --output "$HEIC_FIXTURE.download"
verify_sha256 "$HEIC_FIXTURE_SHA256" "$HEIC_FIXTURE.download"
mv "$HEIC_FIXTURE.download" "$HEIC_FIXTURE"
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

AVIF_FIXTURE="$BUILD_ROOT/fixtures/example.avif"
AVIF_FIXTURE_URL=https://raw.githubusercontent.com/strukturag/libheif/2c4bbb54c2738d4a5efbbe3e5fa1d5d76bb88eb0/examples/example.avif
AVIF_FIXTURE_SHA256=54a0dc31d02b6f5d9d4b66027d4787861b7af15ffd8fab8eab963d10c5411469
curl --fail --location --retry 3 "$AVIF_FIXTURE_URL" \
  --output "$AVIF_FIXTURE.download"
verify_sha256 "$AVIF_FIXTURE_SHA256" "$AVIF_FIXTURE.download"
mv "$AVIF_FIXTURE.download" "$AVIF_FIXTURE"
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
    runtime_path="$MINGW_BIN_POSIX/$runtime"
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
    if [ -d "$MINGW_PREFIX_POSIX/share/licenses/$component" ]; then
      cp -R "$MINGW_PREFIX_POSIX/share/licenses/$component" \
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
HEIC decode smoke: $HEIC_FIXTURE_URL -> 451x461 PNG
AVIF decode smoke: $AVIF_FIXTURE_URL -> 800x533 PNG via dav1d
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
