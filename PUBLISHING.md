# Publishing to Maven Central

Publishing is gated by a non-prerelease GitHub Release. Pushes, pull requests,
and manual CI runs only verify artifacts.

## Release procedure

1. Set the same non-SNAPSHOT version in the parent and child POMs and update
   versioned documentation.
2. Merge the release commit to `main` and wait for all three platform jobs.
3. Publish a GitHub Release tagged `v<project.version>` at that exact commit.
4. The release workflow validates the tag, rebuilds PDFium, libvips, and the
   complete checksum-pinned native closure from source, reruns native and JPMS
   tests on all platforms, assembles all three classifier jars, signs every
   artifact, and deploys to Maven Central.

The Central plugin uses `autoPublish=true` and waits for the deployment to
reach `published`.

## Repository secrets

Configure these GitHub Actions secrets:

| Secret | Purpose |
|---|---|
| `MAVEN_CENTRAL_USERNAME` | Central Portal user-token username |
| `MAVEN_CENTRAL_PASSWORD` | Central Portal user-token password |
| `GPG_PRIVATE_KEY` | ASCII-armored signing private key |
| `GPG_PASSPHRASE` | Signing-key passphrase |

The `io.github.ghosthack` Central namespace must be verified before the first
deployment.

## Local release verification

After running the platform build on each target and collecting all three
staged native directories:

```sh
./mvnw -Prelease,all-natives -Dnative.classifier=macos-arm64 \
  -Dgpg.skip=true clean verify
```

Published releases are immutable. Correct a failed release with a new version;
do not rebuild different content under an existing version.
