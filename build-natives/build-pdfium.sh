#!/usr/bin/env bash
# Build the pinned, V8-free PDFium shared library from Chromium source.
#
# Usage:
#   build-natives/build-pdfium.sh <macos-arm64|linux-x64|windows-x64> [output]
#
# PDFium uses Chromium's depot_tools and is intentionally a separate build
# because its source and toolchain are much larger than the libvips closure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/build-natives/versions.env"

# Do not let a developer shell's package-manager flags alter Chromium's
# hermetic GN toolchain configuration.
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS CPATH C_INCLUDE_PATH \
  CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH \
  DYLD_LIBRARY_PATH LD_LIBRARY_PATH

PLATFORM="${1:?usage: $0 <macos-arm64|linux-x64|windows-x64> [output]}"
OUTPUT="${2:-$ROOT/build/pdfium-$PLATFORM}"
BUILDER="$ROOT/build/pdfium-binaries"
PDFIUM_PLATFORM_ENV=()

case "$PLATFORM" in
  macos-arm64) PDFIUM_OS=mac; PDFIUM_CPU=arm64 ;;
  linux-x64) PDFIUM_OS=linux; PDFIUM_CPU=x64 ;;
  windows-x64)
    PDFIUM_OS=win
    PDFIUM_CPU=x64
    # Native Windows treats environment names case-insensitively. Remove
    # mixed-case SDK variables inherited from developer shells before setting
    # our controlled value.
    unset WindowsSdkDir WindowsSdkBinPath WindowsSdkVerBinPath \
      WindowsSDKVersion UniversalCRTSdkDir
    WINDOWS_SDK_BIN_ROOT='/c/Program Files (x86)/Windows Kits/10/bin'
    WINDOWS_SDK_RC="$({
      find "$WINDOWS_SDK_BIN_ROOT" -mindepth 3 -maxdepth 3 \
        -type f -iname rc.exe -path '*/x64/rc.exe' -print 2>/dev/null || true
    } | sort -V | tail -n 1)"
    if [ -z "$WINDOWS_SDK_RC" ]; then
      echo "Windows SDK x64 rc.exe not found under $WINDOWS_SDK_BIN_ROOT" >&2
      exit 1
    fi
    # Chromium's 2022 probe checks Program Files, while the standalone Build
    # Tools installer uses Program Files (x86) on our builders.
    PDFIUM_PLATFORM_ENV=(
      "vs2022_install=C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools"
      "WINDOWSSDKDIR=C:\\Program Files (x86)\\Windows Kits\\10"
      "PATH=$(dirname "$WINDOWS_SDK_RC"):$PATH"
    )
    ;;
  *) echo "unsupported platform: $PLATFORM" >&2; exit 2 ;;
esac

if [ ! -d "$BUILDER/.git" ]; then
  git clone https://github.com/bblanchon/pdfium-binaries.git "$BUILDER"
fi
git -C "$BUILDER" fetch --depth 1 origin "$PDFIUM_BUILD_COMMIT"
git -C "$BUILDER" checkout --force --detach "$PDFIUM_BUILD_COMMIT"

# The upstream CI helper selects a versioned Xcode bundle with sudo.  Local
# builders and GitHub's macOS runners already have an active Xcode toolchain,
# so keep that selection and avoid requiring an administrator password.
if [ "$PLATFORM" = "macos-arm64" ]; then
  sed -i.bak \
    's|sudo xcode-select -s "/Applications/Xcode_26.0.app"|: # use the active Xcode selected by the host|' \
    "$BUILDER/steps/01-install.sh"
  rm -f "$BUILDER/steps/01-install.sh.bak"
fi

# Branch names are useful provenance, but are not immutable. Make the helper
# sync the exact reviewed PDFium commit on every host.
sed -i.bak \
  's|gclient sync -r "origin/${PDFium_BRANCH:-main}" --no-history --shallow|gclient sync -r "'"$PDFIUM_REVISION"'" --no-history --shallow|' \
  "$BUILDER/steps/02-checkout.sh"
rm -f "$BUILDER/steps/02-checkout.sh.bak"

(
  cd "$BUILDER"
  rm -rf staging
  if [ "${#PDFIUM_PLATFORM_ENV[@]}" -gt 0 ]; then
    env \
      DEPOT_TOOLS_WIN_TOOLCHAIN=0 \
      PDFium_VERSION="$PDFIUM_VERSION" \
      "${PDFIUM_PLATFORM_ENV[@]}" \
      ./build.sh -b "$PDFIUM_BRANCH" "$PDFIUM_OS" "$PDFIUM_CPU"
  else
    # Bash 3.2 (still shipped by macOS) treats expansion of an empty array as
    # an unbound variable under `set -u`, even when the array was initialized.
    env \
      DEPOT_TOOLS_WIN_TOOLCHAIN=0 \
      PDFium_VERSION="$PDFIUM_VERSION" \
      ./build.sh -b "$PDFIUM_BRANCH" "$PDFIUM_OS" "$PDFIUM_CPU"
  fi
)

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
cp -R "$BUILDER/staging/." "$OUTPUT/"
find "$OUTPUT/include" -type f -name '*.orig' -delete
cp "$BUILDER/pdfium/third_party/harfbuzz/src/COPYING" \
  "$OUTPUT/licenses/harfbuzz.txt"
printf '%s\n' "$PDFIUM_BUILD_COMMIT" > "$OUTPUT/BUILD-SCRIPT-COMMIT.txt"
printf '%s\n' "$PDFIUM_BRANCH" > "$OUTPUT/PDFIUM-BRANCH.txt"
printf '%s\n' "$PDFIUM_REVISION" > "$OUTPUT/PDFIUM-REVISION.txt"
echo "Built PDFium $PDFIUM_VERSION for $PLATFORM in $OUTPUT"
