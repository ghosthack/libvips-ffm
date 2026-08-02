#!/bin/sh
# Regenerate the low-level libvips bindings with OpenJDK jextract 25+.
#
# Environment:
#   JEXTRACT_HOME  jextract distribution root (required)
#   VIPS_PREFIX    libvips prefix (default: pkg-config --variable=prefix vips)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JX="${JEXTRACT_HOME:?set JEXTRACT_HOME to the jextract distribution}/bin/jextract"
VIPS_PREFIX="${VIPS_PREFIX:-$(pkg-config --variable=prefix vips)}"
GLIB_PREFIX="$(pkg-config --variable=prefix glib-2.0)"
OUT="$ROOT/core/src/main/java"
PKG="io.github.ghosthack.libvipsffm.libvips"
GEN_DIR="$OUT/$(printf '%s' "$PKG" | tr . /)"

rm -rf "$GEN_DIR"

set -- \
  --include-function vips_init \
  --include-function vips_shutdown \
  --include-function vips_version \
  --include-function vips_version_string \
  --include-function vips_error_buffer \
  --include-function vips_error_clear \
  --include-function vips_image_new_from_file \
  --include-function vips_image_new_from_memory_copy \
  --include-function vips_image_new_from_buffer \
  --include-function vips_image_write_to_file \
  --include-function vips_image_write_to_buffer \
  --include-function vips_image_write_to_memory \
  --include-function vips_image_get_width \
  --include-function vips_image_get_height \
  --include-function vips_image_get_bands \
  --include-function vips_image_get_format \
  --include-function vips_image_get_interpretation \
  --include-function vips_image_get_fields \
  --include-function vips_image_get_typeof \
  --include-function vips_image_get_as_string \
  --include-function vips_image_get_blob \
  --include-function vips_image_get_int \
  --include-function vips_image_get_double \
  --include-function vips_image_hasalpha \
  --include-function vips_thumbnail \
  --include-function vips_thumbnail_buffer \
  --include-function vips_thumbnail_image \
  --include-function vips_resize \
  --include-function vips_crop \
  --include-function vips_extract_area \
  --include-function vips_extract_band \
  --include-function vips_bandjoin \
  --include-function vips_bandjoin_const1 \
  --include-function vips_unpremultiply \
  --include-function vips_flip \
  --include-function vips_rot \
  --include-function vips_autorot \
  --include-function vips_cast \
  --include-function vips_colourspace \
  --include-function vips_icc_import \
  --include-function vips_icc_transform \
  --include-function vips_invert \
  --include-function vips_linear1 \
  --include-function vips_avg \
  --include-function vips_cache_set_max \
  --include-function vips_cache_set_max_mem \
  --include-function vips_cache_set_max_files \
  --include-function vips_blob_get_type \
  --include-function g_object_unref \
  --include-function g_free \
  --include-function g_strfreev \
  --include-constant VIPS_DIRECTION_HORIZONTAL \
  --include-constant VIPS_DIRECTION_VERTICAL \
  --include-constant VIPS_ANGLE_D0 \
  --include-constant VIPS_ANGLE_D90 \
  --include-constant VIPS_ANGLE_D180 \
  --include-constant VIPS_ANGLE_D270 \
  --include-constant VIPS_FORMAT_UCHAR \
  --include-constant VIPS_FORMAT_CHAR \
  --include-constant VIPS_FORMAT_USHORT \
  --include-constant VIPS_FORMAT_SHORT \
  --include-constant VIPS_FORMAT_UINT \
  --include-constant VIPS_FORMAT_INT \
  --include-constant VIPS_FORMAT_FLOAT \
  --include-constant VIPS_FORMAT_DOUBLE \
  --include-constant VIPS_INTERPRETATION_sRGB

"$JX" --output "$OUT" -t "$PKG" \
  --header-class-name Vips \
  -I "$VIPS_PREFIX/include" \
  -I "$GLIB_PREFIX/include/glib-2.0" \
  -I "$(pkg-config --variable=libdir glib-2.0)/glib-2.0/include" \
  -I "$(pkg-config --variable=includedir libffi)" \
  "$@" \
  "$ROOT/jextract/libvips_api.h"

perl -0777 -pi -e \
  's/static final SymbolLookup SYMBOL_LOOKUP = .*?;/static final SymbolLookup SYMBOL_LOOKUP = io.github.ghosthack.libvipsffm.LibVipsLibs.lookup();/s' \
  "$GEN_DIR/Vips.java"

# These selected declarations use C_LONG only as jextract's macOS spelling of
# size_t. All supported targets are 64-bit, while Windows C long is only
# 32-bit, so canonicalLayouts().get("long") is not a portable size_t layout.
perl -pi -e \
  's|public static final ValueLayout\.OfLong C_LONG = .*;|public static final ValueLayout.OfLong C_LONG = ValueLayout.JAVA_LONG; // 64-bit size_t|' \
  "$GEN_DIR/Vips\$shared.java"

grep -q "LibVipsLibs.lookup()" "$GEN_DIR/Vips.java" || {
  echo "ERROR: runtime symbol-lookup patch did not apply"
  exit 1
}
if grep -rn "$VIPS_PREFIX" "$GEN_DIR" >/dev/null; then
  echo "ERROR: generation-machine paths survived in generated sources"
  exit 1
fi
grep -q "C_LONG = ValueLayout.JAVA_LONG" "$GEN_DIR/Vips\$shared.java" || {
  echo "ERROR: portable size_t patch did not apply"
  exit 1
}

echo "Generated $(find "$GEN_DIR" -type f | wc -l | tr -d ' ') files in $GEN_DIR"
