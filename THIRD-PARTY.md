# Third-party notices

## Native classifier jars

The `libvips-ffm-natives` classifier jars contain libvips 8.18.3 and
the reviewed runtime dependency closure built from source by this repository.
They do not contain sharp-libvips, a host package-manager build, or an
ImageMagick/GraphicsMagick delegate stack.

Every classifier jar includes:

- `LICENSE-libvips.txt`, the complete LGPL 2.1 license shipped by libvips;
- root license copies for libimagequant, librsvg, and libultrahdr;
- `licenses/rust/`, with an inventory and copied license texts for Rust crates
  linked into librsvg;
- `licenses/vcpkg/`, with the license/copyright material installed by every
  vcpkg port in that platform's resolved dependency graph;
- `licenses/pdfium/`, with PDFium and its included third-party licenses;
- on Windows, `licenses/mingw-runtime/`, covering the staged GCC/libstdc++ and
  winpthreads runtime DLLs;
- `VCPKG-COMPONENTS.txt`, the exact resolved vcpkg package versions;
- `BUILD-INFO.txt`, including source/build pins and explicit libvips feature
  options;
- `CORRESPONDING-SOURCE.txt`, with source locations and build recipes;
- `manifest.sha256`, which the runtime loader verifies before loading the
  staged libraries.

The closure contains components under several permissive and weak-copyleft
licenses. In particular, libvips and librsvg are LGPL-2.1-or-later, while the
pinned libheif port declares LGPL-3.0-only. The per-classifier files are the
authoritative inventory; do not infer the whole native artifact's obligations
from the binding's MIT license or from the Maven dependency graph.

The native shared libraries remain dynamically linked and user-replaceable
through `LIBVIPS_FFM_LIBDIR` or `-Dlibvipsffm.libdir`.

## Source and build provenance

Direct source archives are SHA-256 pinned in `build-natives/versions.env`.
The rest of the codec closure is resolved by the pinned vcpkg baseline in
`build-natives/vcpkg/vcpkg.json`; vcpkg portfiles pin and verify their own
sources. PDFium is built from an exact commit on `chromium/7869`, without V8
or XFA, by the matching pinned `pdfium-binaries` build-script revision.

The complete build recipes are under `build-natives/`. GitHub Actions executes
the same recipes independently for macOS ARM64, Windows x64, and glibc Linux
x64 before the Maven Central release workflow collects the classifier
artifacts.

## OpenJDK jextract

The low-level Java source was generated with OpenJDK jextract 25. OpenJDK
states that jextract's license does not affect generated output:
https://jdk.java.net/jextract/.

## Maven Wrapper

`mvnw` and `mvnw.cmd` are Apache Maven Wrapper 3.3.4 scripts, licensed under
Apache License 2.0. They download Apache Maven 3.9.16 from Maven Central and
do not embed a wrapper jar.
