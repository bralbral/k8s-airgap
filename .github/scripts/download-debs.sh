#!/usr/bin/env bash
# Download Debian 12 prerequisites and their dependencies in the official image.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
mkdir -p /tmp/debs/partial /output
mapfile -t packages < <(sed '/^#/d; /^[[:space:]]*$/d' /config/packages.txt)
# Include dependencies already installed in the build container as well.
: > /tmp/empty-status
apt-get -y --download-only --no-install-recommends \
  -o Dir::State::status=/tmp/empty-status \
  -o Dir::Cache::archives=/tmp/debs \
  install "${packages[@]}"
rm -rf /tmp/debs/partial /tmp/debs/lock
compgen -G '/tmp/debs/*.deb' >/dev/null || { echo 'No Debian packages downloaded' >&2; exit 1; }
tar -czf /output/debian12-amd64.tar.gz -C /tmp/debs .
chmod 0644 /output/debian12-amd64.tar.gz
