#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cd "$ROOT" && ./mvnw -q help:evaluate -Dexpression=project.version -DforceStdout)"
CLASSIFIER="${1:-}"
if [ -z "$CLASSIFIER" ]; then
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  case "$OS-$ARCH" in
    Darwin-arm64) CLASSIFIER=macos-arm64 ;;
    Linux-x86_64) CLASSIFIER=linux-x64 ;;
    MINGW*-x86_64|MSYS*-x86_64) CLASSIFIER=windows-x64 ;;
    *) echo "unsupported JPMS smoke-test platform: $OS-$ARCH" >&2; exit 2 ;;
  esac
fi
case "$CLASSIFIER" in
  windows-x64) PATH_SEPARATOR=';' ;;
  *) PATH_SEPARATOR=':' ;;
esac

CORE="$ROOT/core/target/libvips-ffm-$VERSION.jar"
NATIVE="$ROOT/natives/target/libvips-ffm-natives-$VERSION-$CLASSIFIER.jar"
OUT="$ROOT/integration-tests/target/jpms"

if command -v javac >/dev/null 2>&1; then
  JAVAC=javac
  JAVA=java
elif [ -n "${JAVA_HOME:-}" ]; then
  JAVA_HOME_SHELL="$JAVA_HOME"
  if command -v cygpath >/dev/null 2>&1; then
    JAVA_HOME_SHELL="$(cygpath --unix "$JAVA_HOME")"
  fi
  JAVAC="$JAVA_HOME_SHELL/bin/javac"
  JAVA="$JAVA_HOME_SHELL/bin/java"
else
  echo "javac is not on PATH and JAVA_HOME is unset" >&2
  exit 2
fi

rm -rf "$OUT"
mkdir -p "$OUT"
MODULE_INFO="$ROOT/integration-tests/jpms/module-info.java"
MAIN_SOURCE="$ROOT/integration-tests/jpms/io/github/ghosthack/libvipsffm/jpmstest/Main.java"
if [ "$CLASSIFIER" = windows-x64 ] && command -v cygpath >/dev/null 2>&1; then
  CORE="$(cygpath --windows "$CORE")"
  NATIVE="$(cygpath --windows "$NATIVE")"
  OUT="$(cygpath --windows "$OUT")"
  MODULE_INFO="$(cygpath --windows "$MODULE_INFO")"
  MAIN_SOURCE="$(cygpath --windows "$MAIN_SOURCE")"
  export MSYS2_ARG_CONV_EXCL='*'
fi

"$JAVAC" --module-path "$CORE$PATH_SEPARATOR$NATIVE" -d "$OUT" \
  "$MODULE_INFO" "$MAIN_SOURCE"
"$JAVA" --enable-native-access=libvips.ffm \
  --module-path "$CORE$PATH_SEPARATOR$NATIVE$PATH_SEPARATOR$OUT" \
  --module libvips.ffm.jpms.test/io.github.ghosthack.libvipsffm.jpmstest.Main
