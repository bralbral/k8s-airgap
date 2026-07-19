# Generated manifests

`scripts/build-bundle.sh` downloads pinned upstream manifests, rewrites their image references to the target Harbor layout and stores the resulting files here in the bundle.

The generated files are deliberately not committed: their final `imageRepository` is an installation-time value. The build always retains upstream source URLs and checksums in `manifest.json`.
