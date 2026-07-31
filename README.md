# libvips-ffm

JDK 26 Panama FFM bindings for the **libvips 8.18** C API, with
self-contained libvips 8.18.3 binaries for macOS ARM64, Windows x64, and
glibc Linux x64. No JNI and no host libvips installation are required.

## Maven

Use the Java API jar plus the native classifier for the deployment platform:

```xml
<dependency>
  <groupId>io.github.ghosthack</groupId>
  <artifactId>libvips-ffm</artifactId>
  <version>8.18.3-0.1.0</version>
</dependency>
<dependency>
  <groupId>io.github.ghosthack</groupId>
  <artifactId>libvips-ffm-natives</artifactId>
  <version>8.18.3-0.1.0</version>
  <classifier>macos-arm64</classifier>
  <scope>runtime</scope>
</dependency>
```

Available classifiers are `macos-arm64`, `windows-x64`, and `linux-x64`.
Production applications normally select one with Maven OS-activated profiles
or produce one distribution per platform.

On the module path, declare both modules:

```java
module your.application {
    requires libvips.ffm;
    requires libvips.ffm.natives;
}
```

`libvips.ffm.natives` is the stable automatic-module name of each classified
native jar. Start a modular application with
`--enable-native-access=libvips.ffm`. On the class path, use
`--enable-native-access=ALL-UNNAMED`.

## Java API

`VipsImage` owns a native image reference and must be closed. Operations are
lazy until a result is written.

```java
import io.github.ghosthack.libvipsffm.VipsImage;

try (VipsImage source = VipsImage.fromFile(input);
     VipsImage thumbnail = source.thumbnail(400).autorotate()) {
    thumbnail.writeToFile(output);
}
```

Encoded memory and memory output are supported as well:

```java
byte[] png;
try (VipsImage source = VipsImage.fromBytes(jpeg);
     VipsImage small = source.thumbnail(320)) {
    png = small.writeToBuffer(".png");
}
```

Buffer-backed lazy pipelines retain their input memory until every derived
image has closed. Convenience operations currently cover load, save,
thumbnail, resize, crop, autorotate, invert, and raw interleaved pixels.
The jextract-generated `io.github.ghosthack.libvipsffm.libvips.Vips` class
exposes the curated low-level C surface for advanced use.

## Native resolution

`LibVipsLibs` resolves in this order:

1. `-Dlibvipsffm.libdir=<directory>` or `LIBVIPS_FFM_LIBDIR`;
2. the matching classified native jar, extracted under the user cache and
   verified against its SHA-256 manifest;
3. a host libvips visible through `java.library.path`.

Set `-Dlibvipsffm.cachedir=<directory>` to replace the extraction cache root.
The explicit library-directory override is also the LGPL replacement
mechanism.

## Building and testing

JDK 26 is required. The Maven wrapper pins Maven 3.9.16:

```sh
./build-natives/build-pdfium.sh macos-arm64
./build-natives/macos-arm64.sh
./mvnw clean verify
./integration-tests/verify-jpms.sh macos-arm64
```

Use the matching PDFium and platform scripts for `linux-x64` or `windows-x64`.
The scripts compile libvips, PDFium, and every distributed dependency from
checksum- or commit-pinned source. They stage the complete relocatable shared
library closure rather than using a host installation or repackaging a
prebuilt libvips distribution. `jextract/gen-bindings.sh` regenerates bindings
with OpenJDK jextract 25+ and preserves the portable 64-bit `size_t`
correction needed on Windows.

GitHub CI is the release builder and repeats the image-processing and JPMS
smoke tests on macOS ARM64, Windows x64, and Ubuntu 24.04 x64. The three LAN
nodes can run the same scripts for development verification. See
[PUBLISHING.md](PUBLISHING.md) for the Maven Central release flow and
[ROADMAP.md](ROADMAP.md) for the ordered next steps.

The reviewed native feature set includes libjpeg-turbo JPEG, PNG, TIFF, WebP,
GIF decoding through nsgif, AVIF decoding through dav1d, HEIC decoding through
libde265, UltraHDR, JPEG XL, SVG through librsvg, PDF through V8-free PDFium,
and JPEG 2000 through OpenJPEG. GIF and AVIF encoding are deliberately absent.
ImageMagick, GraphicsMagick, Poppler, x265/HEIC encoding, and dynamic libvips
modules are explicitly excluded. The complete matrix and the consequences of
every optional integration are recorded in
[LIBVIPS-INTEGRATIONS.md](LIBVIPS-INTEGRATIONS.md).

## Licensing

The binding and convenience code is MIT. Classified native jars contain a
from-source libvips build and its dynamically linked runtime closure. Each jar
includes the libvips LGPL-2.1 text, per-component license material, exact
vcpkg component versions, build inputs, hashes, and corresponding-source/build
information. See [THIRD-PARTY.md](THIRD-PARTY.md).
