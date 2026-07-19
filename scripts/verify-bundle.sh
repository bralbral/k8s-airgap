#!/usr/bin/env bash
set -Eeuo pipefail
bundle_dir="${1:?Usage: verify-bundle.sh <unpacked-bundle-directory>}"
cd "${bundle_dir}"
sha256sum --check SHA256SUMS
