# libvips integrations and bundled capabilities

This document distinguishes:

1. libraries that libvips *can* use when built with them;
2. the consequences of enabling those integrations; and
3. the libraries and operations included in the native artifacts published by
   this project.

It describes libvips 8.18.3 and
`io.github.ghosthack:libvips-ffm-natives:8.18.3-0.1.0`. Future native upgrades
must update and re-verify this document.

## How optional integrations work

libvips has native "foreign" loaders and savers for many image formats. Most
are compiled only when Meson finds the corresponding dependency. Feature
options defaulting to `auto` make this convenient for a workstation build, but
they can also make two builds from the same source expose different operations.

Some integrations can instead be built as dynamically discovered libvips
modules. libvips 8.18.3 has module controls for HEIF, JPEG XL, ImageMagick,
OpenSlide, and Poppler, as well as a global `modules` option. A reproducible
self-contained build should explicitly control these instead of relying on
what happens to be installed on the build machine.

The normal generic load API chooses from the loaders registered in the running
libvips. Native format-specific loaders are preferred where applicable, while
broad fallback loaders can recognize additional formats. Consequently, adding
or removing an integration can affect not only which files load, but which
implementation handles them and the options, metadata, performance, and error
behavior observed by callers.

## Optional external libraries

### Image formats and document renderers

| Integration | Capability added to libvips | Important consequences |
|---|---|---|
| IJG-compatible `libjpeg`, mozjpeg, or libjpeg-turbo | JPEG load and save | Codec choice changes performance and encoding characteristics. libvips recommends mozjpeg when available. |
| libultrahdr (`libuhdr`) | UltraHDR JPEG loading | Adds another parser and HDR processing dependency. |
| libexif | EXIF metadata handling in JPEG | Metadata parsing is separate from JPEG pixel decoding. |
| libpng or libspng | PNG load and save | libpng is preferred when present; spng is the alternative. |
| libtiff | TIFF load and save | Its own JPEG/ZIP and other codec configuration determines available TIFF compression schemes. |
| libwebp | WebP load and save | Adds lossy, lossless, alpha, and animation support provided by the selected libwebp build. |
| cgif | GIF saving | Without it, a Magick-enabled build can fall back to Magick for GIF output. libvips also has an internal nsgif loader option. |
| libimagequant or quantizr | Palette quantization for PNG and GIF | Affects palette quality, performance, and the dependency/license inventory. |
| librsvg | SVG rendering | Uses the Cairo/font/XML stack. Without it, a Magick-enabled build can fall back to ImageMagick for SVG. |
| PDFium | PDF rendering | Preferred PDF backend when detected. It is a large rendering engine with a correspondingly large attack and maintenance surface. |
| Poppler GLib | PDF rendering | Used if PDFium is unavailable. Without either, a Magick-enabled build can fall back to ImageMagick. Poppler's exact licensing must be considered before binary distribution. |
| LibRaw | Camera RAW loading | Adds support for camera sensor formats. This is distinct from libvips' built-in `rawload`, which reads headerless raw pixel data. |
| OpenEXR | OpenEXR loading | libvips 8.18.3 directly reads but does not directly write OpenEXR through this integration. |
| OpenJPEG (`libopenjp2`) | JPEG 2000 load and save | Adds the `jp2kload`/`jp2ksave` family. JPEG 2000 is unrelated to JPEG XL. |
| libjxl | JPEG XL load and save | Adds the `jxlload`/`jxlsave` family. The Meson option is named `jpeg-xl`. |
| OpenSlide | Whole-slide microscopy images | Supports formats such as Aperio, Hamamatsu, Leica, MIRAX, Sakura, Trestle, and Ventana. These files can be extremely large. |
| libheif | HEIF-family containers, including AVIF and potentially HEIC | Actual formats depend on the codec plugins compiled into libheif; the presence of `heifload` alone does not prove HEIC support. |
| cfitsio | FITS loading | Adds astronomy/scientific image parsing. |
| matio | MATLAB save-file loading | Adds MATLAB scientific data parsing. |
| libniftiio | NIfTI load and save | Adds medical/scientific volume data support. |

libvips also contains formats that do not require one of the external format
libraries above, including CSV, its native `.v` format, PPM/PGM/PFM, Radiance
HDR, Analyze, and raw pixel data. Some have their own boolean Meson switches.

### Processing and output support

| Integration | Capability added | Important consequences |
|---|---|---|
| lcms2 | ICC import, export, and colour transforms | Colour behavior depends on profiles and rendering intent. |
| Pango/Cairo, Fontconfig, FreeType, FriBidi, and HarfBuzz | Text rendering and the rendering stack used by SVG | Text output can depend on available fonts and font configuration on the target machine. |
| FFTW3 | Fourier-transform operations | Adds a performance-oriented numerical dependency. |
| Highway or ORC | SIMD acceleration | Highway is preferred; ORC is the fallback. This affects performance rather than file compatibility. |
| libarchive | Archive output for `dzsave` image pyramids | Adds archive creation and compression handling. |
| zlib or a compatible implementation | Deflate compression used by formats and dependencies | The exact implementation can affect performance and platform requirements. |

GLib/GObject and Expat are core libvips build dependencies rather than optional
image-format integrations. A self-contained distribution will also include
transitive libraries required by the selected integrations.

## ImageMagick and GraphicsMagick

ImageMagick, or optionally GraphicsMagick, is different from the narrow codec
integrations. It supplies `magickload` and optionally `magicksave`, allowing
libvips to use the formats recognized by the selected Magick build. This is
useful for long-tail formats such as DICOM, but it has significant effects:

- It greatly expands the amount of native code processing untrusted input.
- Available formats can depend on installed or bundled Magick coder modules.
- Behavior can depend on Magick configuration and `policy.xml`.
- Some formats can use delegate programs or additional libraries.
- It can become a fallback for SVG, PDF, camera RAW, and GIF output when
  narrower integrations are absent.
- It can be much slower than libvips' native loaders.
- The exact coder/delegate set expands the vulnerability, licensing, and
  update inventory.

libvips itself warns that enabling Magick for a service processing untrusted
images has security implications. For a controlled server-side artifact,
narrow native codecs are generally easier to reason about.

The relevant libvips 8.18.3 Meson settings are:

```text
-Dmagick=disabled
-Dmagick-features=load,save
-Dmagick-module=disabled
-Dmagick-package=MagickCore
```

`magick-features` can enable loading and saving independently. Setting
`magick=disabled` is the important explicit exclusion; merely omitting
ImageMagick from a dependency list is weaker when feature detection remains
automatic.

## Sharp and sharp-libvips

[Sharp](https://sharp.pixelplumbing.com/) is a popular Node.js image-processing
module whose native engine is libvips. `sharp-libvips` is the related build and
binary-distribution project used to produce libvips packages for Sharp; it is
not libvips itself and is unrelated to the Java Panama API in this repository.

Its useful engineering ideas are the curated dependency set, cross-platform
patches, relocation work, license inventory, and compact deployment model.
Reusing its already-built npm binaries would make bootstrap fast, but would
also delegate our codec policy, compiler choices, provenance, and update
schedule to another distribution. This project therefore applies the useful
model—pinned sources and a reviewed relocatable closure—while compiling its own
native artifacts on the three target platforms. Sharp and sharp-libvips are
not runtime or build inputs.

## HEIF, AVIF, and HEIC are not synonyms

libheif is a container and dispatch layer. Its codec backends determine what a
particular build can decode or encode:

| Content | Typical codec backends |
|---|---|
| AVIF / AV1 | AOM, dav1d, rav1e, or SVT-AV1 |
| HEIC / HEVC | libde265 for decoding; x265 for encoding |

Therefore:

- `libheif` present does not necessarily mean HEIC/HEVC works.
- `heifload` registered does not identify the available codec backend.
- AVIF can work while iPhone HEIC input fails.
- Adding HEVC support requires a separate patent and licensing review.
- x265 is GPL-licensed unless used under an appropriate commercial license,
  so adding it materially changes a binary distribution review.

Codec availability should be tested with representative AVIF and HEIC files,
not inferred from operation names.

## Current project-native configuration

The classifier jars are built from source by this repository on their target
operating systems:

| Classifier | Build target |
|---|---|
| `macos-arm64` | macOS ARM64 |
| `linux-x64` | Ubuntu 24.04-compatible glibc x64 |
| `windows-x64` | Windows x64, MinGW runtime closure |

PDFium is built separately from pinned Chromium source because its checkout
and toolchain are substantially larger. vcpkg builds the remaining external
dependency graph from checksum-pinned port sources. libimagequant,
libultrahdr, supported librsvg 2.62.3, and libvips itself are then built
directly from their pinned release archives.

Each classifier contains libvips plus the complete set of shared libraries it
needs. Dynamic libvips modules are disabled, and the closure is relocated to
resolve only within its extracted classifier directory.

### Included components

The reviewed common functional set is:

| Component | What it provides here |
|---|---|
| libvips 8.18.3 | Image-processing engine |
| libjpeg-turbo | JPEG load/save and TIFF JPEG compression |
| libpng | PNG |
| libtiff with JPEG and ZIP | TIFF |
| libwebp | WebP |
| built-in nsgif | GIF decoding only |
| libheif plus dav1d | AVIF decoding only |
| libheif plus libde265 | HEIC/HEVC decoding only |
| libultrahdr | UltraHDR JPEG |
| libjxl | JPEG XL loading and saving |
| OpenJPEG | JPEG 2000 loading and saving |
| librsvg 2.62.3 plus Cairo | SVG rendering |
| PDFium revision `80fccd7553e5` on `chromium/7869`, without V8 or XFA | PDF rendering |
| libexif | EXIF metadata |
| lcms2 | ICC colour management |
| libimagequant | Palette quantization |
| Pango, Fontconfig, FreeType, FriBidi, and HarfBuzz | Text/font rendering |
| libarchive | Archive support for image-pyramid output |
| Highway | SIMD acceleration |
| GLib/GObject, Expat, libxml2, Pixman, Brotli, dav1d, and related libraries | Core and transitive runtime support |

The authoritative resolved inventories in generated classifier resources are:

- `natives/src/main/resources/libvips-natives/macos-arm64/VCPKG-COMPONENTS.txt`
- `natives/src/main/resources/libvips-natives/linux-x64/VCPKG-COMPONENTS.txt`
- `natives/src/main/resources/libvips-natives/windows-x64/VCPKG-COMPONENTS.txt`

The pinned inputs are in `build-natives/versions.env` and
`build-natives/vcpkg/vcpkg.json`. The platform scripts create these resources
and include source/build provenance, licenses, and a SHA-256 manifest beside
the runtime libraries.

### Deliberately absent integrations

The explicit build configuration excludes:

- ImageMagick or GraphicsMagick;
- Poppler;
- AOM and therefore AVIF encoding;
- cgif and therefore GIF encoding;
- x265 and therefore HEIC/HEVC encoding;
- LibRaw / camera RAW;
- OpenEXR;
- OpenSlide;
- cfitsio / FITS;
- matio / MATLAB;
- libniftiio / NIfTI;
- FFTW3 and ORC;
- dynamic libvips modules;
- GObject introspection, the C++ API, deprecated API, examples, and tools; and
- built-in PPM, Analyze, and Radiance foreign formats.

Do not use printable strings in a native binary as a feature test. libvips
metadata can contain names for operations that are not registered in that
build. Query the runtime type system, use `vips -l` when a CLI is present, or
perform representative decode/encode tests.

### Decision: decode-only AVIF and GIF (2026-07-31)

The project deliberately replaced AOM with dav1d and removed cgif. dav1d is a
decode-only AV1 implementation selected for its focused, optimized decoding
path; removing AOM also removes the AV1 encoder. Removing cgif removes direct
GIF encoding, while libvips' built-in nsgif loader remains. Because Magick is
also excluded, neither format has an encoder fallback in the bundled build.
The resulting contract is therefore AVIF decode-only and GIF decode-only.
This reduces encoder code, artifact surface, and maintenance obligations at
the explicit cost of `heifsave`/AVIF and `gifsave` output capability.
For a deterministic runtime closure, dav1d is compiled directly into libheif;
libheif's external codec plugin loader and its dav1d plugin mode are disabled.

### HEIF boundary

The artifacts include dav1d for AVIF decoding and libde265 for HEIC/HEVC
decoding. They deliberately omit every AV1 and HEVC encoder, including AOM and
x265. This avoids making the native closure GPL-covered through x265, but it
does not eliminate HEVC patent considerations for distribution or use. Every
platform build fully decodes representative AVIF and HEIC/HEVC release
fixtures; the Java smoke suite separately proves AVIF and GIF decoding and
asserts that attempts to encode those formats fail.

### PDF boundary

PDF input uses PDFium, which libvips prefers when both PDF backends are
available. This choice avoids Poppler's GPL coupling and does not permit
JavaScript execution because PDFium is built without V8; XFA is also disabled.
PDF remains a complex document parser, so it materially increases artifact
size, security surface, build time, and patch urgency compared with raster
codecs.

### Current ImageMagick isolation

The build uses `-Dauto_features=disabled`, `-Dmagick=disabled`,
`-Dmagick-module=disabled`, and `-Dmodules=disabled`. ImageMagick,
GraphicsMagick, their coder modules, policies, and delegate processes are not
part of the classifier closure. Release verification must confirm that
the `magickload` operation is not registered and that no staged shared library
imports Magick. libvips retains public `vips_magick*` ABI entry-point names and
a configuration-report string even in a Magick-disabled build; those symbols
and a report of `Magick ... false` do not load or bundle Magick. The native
recipe therefore audits import tables and the complete resolved closure rather
than rejecting libvips' own ABI strings. It also verifies each binary's target
architecture. Staging neutralizes absolute build-machine and home-directory
strings compiled into upstream defaults or diagnostic metadata, then
regenerates hashes and platform signatures as needed.

There is one intentional escape hatch: `LibVipsLibs` prefers
`-Dlibvipsffm.libdir` or `LIBVIPS_FFM_LIBDIR` over the bundled native and can
fall back to a host libvips when no bundle is available. A replacement or host
build can expose a different integration set, including ImageMagick. Capability
claims in this section apply to the bundled classifier artifacts, not arbitrary
override libraries.

## Consequences for future native builds

### Reproducibility

Leaving optional Meson features on `auto` allows installed packages to change
the result. For controlled builds, start from disabled automatic features and
explicitly enable the reviewed set, for example:

```sh
meson setup build \
  -Dauto_features=disabled \
  -Dmodules=disabled \
  -Djpeg=enabled \
  -Dpng=enabled \
  -Dtiff=enabled \
  -Dwebp=enabled \
  -Dheif=enabled \
  -Dheif-module=disabled \
  -Djpeg-xl=enabled \
  -Djpeg-xl-module=disabled \
  -Dopenjpeg=enabled \
  -Drsvg=enabled \
  -Dpdfium=enabled \
  -Dpoppler=disabled \
  -Dcgif=disabled \
  -Darchive=enabled \
  -Dlcms=enabled \
  -Dimagequant=enabled \
  -Dpangocairo=enabled \
  -Dhighway=enabled \
  -Duhdr=enabled \
  -Dmagick=disabled
```

The full recorded option array, including every explicit exclusion, is in
`build-natives/build-platform.sh`. Every enabled feature also has an exact
dependency source. The generated classifier records the Meson options,
component versions, hashes, and provenance for that platform.

### Security and operations

- Every decoder handles attacker-controlled binary data; each added parser
  increases the vulnerability and patching surface.
- Document/PDF, vector, camera RAW, and broad Magick integrations are
  especially large additions compared with a narrow raster codec.
- Large, animated, multipage, tiled, or whole-slide images require resource
  limits even when the decoder is memory-safe.
- Font-based output can vary with installed fonts and configuration.
- Module discovery and external delegate execution make runtime behavior less
  self-contained and should be disabled unless explicitly required.
- Dependency vulnerabilities require rebuilding and republishing the native
  classifier artifacts; updating only the Java binding jar is insufficient.

### Licensing and provenance

The license of libvips does not cover every optional dependency. Any changed
native feature set requires:

- an exact component and transitive dependency inventory;
- license and notice review for every shipped component;
- corresponding-source or relinking compliance where applicable;
- review of GPL components and external delegates;
- review of patent-sensitive codecs, particularly HEVC;
- reproducible upstream URLs and cryptographic hashes; and
- refreshed `THIRD-PARTY-NOTICES.md`, `VCPKG-COMPONENTS.txt`,
  `BUILD-INFO.txt`, and `CORRESPONDING-SOURCE.txt`.

This project republishes native binaries, so the actual content of each binary
and classifier jar—not only the declared Maven dependency graph—is the relevant
distribution boundary.

## Verification checklist

For every native upgrade:

1. Compare all three `VCPKG-COMPONENTS.txt` files and direct-source pins.
2. Review upstream build scripts and feature flags.
3. Inspect dynamic imports with `otool -L`, `readelf -d`, or
   `llvm-objdump -p`.
4. Query registered libvips operations at runtime; do not rely on `strings`.
5. Test real examples for every claimed format, including both AVIF and HEIC
   when relevant.
6. Confirm `magickload` and dynamic module loading remain absent unless they
   are intentional.
7. Re-run cross-platform Java and JPMS smoke tests.
8. Refresh licenses, notices, provenance, source links, and hashes.
9. Update this document with the new artifact version and verified capability
   set.

## Primary references

- [libvips 8.18.3 README and optional dependencies](https://github.com/libvips/libvips/blob/v8.18.3/README.md#optional-dependencies)
- [libvips 8.18.3 Meson feature options](https://github.com/libvips/libvips/blob/v8.18.3/meson_options.txt)
- [librsvg 2.62.3 release archive](https://download.gnome.org/sources/librsvg/2.62/)
- [PDFium source](https://pdfium.googlesource.com/pdfium/)
- [Pinned vcpkg baseline](https://github.com/microsoft/vcpkg/tree/3c5d90a305ff00ca841f085a74a7ce74ee777dee)
- [libvips API documentation](https://www.libvips.org/API/8.18/)
