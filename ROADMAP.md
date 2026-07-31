# Roadmap

This roadmap is ordered around publishing a dependable first Maven Central
release, then growing the Java API without silently changing the native codec
policy. It reflects the repository state as of 2026-07-31.

## Current baseline

Completed and verified locally on the three target hosts:

- JDK 26 Panama FFM bindings in the `libvips.ffm` JPMS module;
- Maven 3.9.x build and Maven Central release metadata;
- native classifier jars for macOS ARM64, Windows x64, and Ubuntu 24.04 x64;
- pinned, from-source, relocatable native runtime closures with hashes,
  provenance, corresponding-source references, and license inventories;
- representative native AVIF and HEIC decoding on every platform;
- Java image-processing, codec round-trip, decode-only, and JPMS smoke tests;
  and
- import, architecture, closure, private-path, Magick, and sharp-libvips
  audits.

The approved native policy is documented in
[`LIBVIPS-INTEGRATIONS.md`](LIBVIPS-INTEGRATIONS.md). AVIF uses dav1d for
decoding, GIF uses built-in nsgif for decoding, and neither format has an
encoder in the bundled artifacts.

## 1. Prove clean GitHub reproducibility

This is the next release gate.

- Land the current source changes in GitHub and run all three native jobs from
  clean hosted runners.
- Confirm each job rebuilds PDFium and the complete native closure rather than
  consuming files left by the LAN development builds.
- Download the three CI classifiers and repeat the aggregate
  `release,all-natives` Maven verification.
- Compare resolved component inventories and operation tests across the three
  platforms. Library counts may differ for platform runtimes; functional
  capabilities must not.
- Make unexpected component or native-import drift fail CI with a useful diff.

## 2. Harden the public API for 0.1.0

- Decide which generated low-level FFM bindings are supported public API and
  which are implementation detail before promising compatibility.
- Add typed load/save options for common needs such as JPEG quality, metadata
  stripping, page selection, access mode, and thumbnail behavior instead of
  asking callers to use native varargs directly.
- Add safe pixel export and metadata read/write APIs with explicit ownership
  and size limits.
- Exercise image lifetime, lazy evaluation, repeated close, concurrent use,
  failed decode, corrupt input, and extraction-cache contention.
- Add a small runnable example module demonstrating file, memory, transform,
  encode, and JPMS use.
- Complete API Javadocs and document thread-safety, native-memory ownership,
  temporary extraction, and host-library override behavior.

## 3. Expand release-format tests

- Add small, redistributable fixtures for every claimed input family: JPEG,
  PNG, TIFF, WebP, GIF, AVIF, HEIC, UltraHDR, JPEG XL, SVG, PDF, and JPEG 2000.
- Decode each representative fixture on every target platform and validate
  dimensions or pixels, not only operation registration.
- Keep encode/decode round trips for every claimed writable format.
- Keep negative tests proving GIF and AVIF encoding remain unavailable and
  Magick operations remain unregistered.
- Record fixture source, license, checksum, and the feature it proves.

## 4. Complete the first Maven Central release

- Verify ownership of the `io.github.ghosthack` Central namespace.
- Configure the Central token and GPG secrets described in
  [`PUBLISHING.md`](PUBLISHING.md).
- Perform a signed local release dry run without deployment and inspect all
  POM, source, Javadoc, core, and native-classifier artifacts.
- Assemble a release candidate from the successful CI artifacts and test a
  clean external consumer against it.
- Publish `8.18.3-0.1.0` from an immutable non-prerelease GitHub tag only after
  all platform and aggregate gates pass.
- Verify the released coordinates from a clean Maven repository and retain a
  release inventory containing hashes and native component lists.

## 5. Post-0.1 API growth

Prioritize common libvips workflows while preserving owned-handle safety:

- compositing, rotation, colour conversion, alpha handling, and additional
  resize/crop controls;
- streaming `VipsSource`/`VipsTarget` support;
- multipage and animated image inspection and output;
- structured metadata, ICC profile, EXIF, and orientation handling;
- configurable libvips concurrency, cache, and resource limits; and
- integration and performance comparisons against the native libvips CLI.

## 6. Maintenance and supply chain

- Define the versioning rule for libvips upgrades versus binding-only fixes.
- Automate dependency-update reports without automatically accepting a changed
  codec graph.
- Generate an SPDX or CycloneDX SBOM for each native classifier.
- Add vulnerability monitoring and a documented rebuild policy for native
  security fixes.
- Periodically rebuild on clean runners and compare source versions, imports,
  licenses, artifact sizes, and representative outputs.
- Consider provenance attestations for GitHub-built release artifacts.

## Deferred platform targets

Linux ARM64, macOS x64, and other operating-system versions can be evaluated
after the first Central release. A new classifier requires a native build host,
complete closure relocation and audit support, CI coverage, licensed fixtures,
and the same JPMS consumer tests; it is not just a classifier-name addition.

## Codec and module change rule

The current codec/module list is frozen for the first release. Any proposed
addition, removal, encoder change, or fallback backend must be reviewed before
implementation. Approval must cover capability, transitive dependencies,
binary size, security surface, license and patent consequences, native plugin
behavior, fixtures, and all three rebuilt classifier inventories.
