# Generated manifests

`.github/scripts/build-bundle.sh` downloads pinned upstream manifests and
stores the resulting files here in the bundle.

The generated files are deliberately not committed. Their original image
references are preserved; containerd redirects pulls to Harbor on each node.
Pinned source versions are recorded in `manifest.env` at the bundle root.
