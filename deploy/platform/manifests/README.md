# Generated manifests

`.github/scripts/build-bundle.sh` downloads pinned upstream manifests and
stores the resulting files here in the bundle.

The generated files are deliberately not committed: their final `imageRepository` is an installation-time value. The build always retains upstream source URLs and checksums in `manifest.json`.
