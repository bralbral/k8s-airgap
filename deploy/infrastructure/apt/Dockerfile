FROM debian:12-slim AS repository

ARG DEBIAN_MIRROR=http://deb.debian.org/debian
ARG DEBIAN_SECURITY_MIRROR=http://security.debian.org/debian-security

COPY config/packages.txt /tmp/packages.txt

RUN set -eux; \
    rm -f /etc/apt/sources.list.d/debian.sources; \
    printf 'deb %s bookworm main\n' "${DEBIAN_MIRROR}" > /etc/apt/sources.list; \
    printf 'deb %s bookworm-updates main\n' "${DEBIAN_MIRROR}" >> /etc/apt/sources.list; \
    printf 'deb %s bookworm-security main\n' "${DEBIAN_SECURITY_MIRROR}" >> /etc/apt/sources.list; \
    sed -i '/^#/d; /^[[:space:]]*$/d' /tmp/packages.txt; \
    apt-get update; \
    mkdir -p /repo/pool/main/partial /repo/dists/bookworm/main/binary-amd64; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --download-only --no-install-recommends \
      -o Dir::Cache::archives=/repo/pool/main \
      $(tr '\n' ' ' < /tmp/packages.txt); \
    rm -rf /repo/pool/main/lock /repo/pool/main/partial; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apt-utils dpkg-dev; \
    cd /repo; \
    dpkg-scanpackages --multiversion pool/main /dev/null > dists/bookworm/main/binary-amd64/Packages; \
    gzip -9 -k dists/bookworm/main/binary-amd64/Packages; \
    apt-ftparchive \
      -o APT::FTPArchive::Release::Origin=k8s-airgap \
      -o APT::FTPArchive::Release::Label=k8s-airgap-debian12 \
      -o APT::FTPArchive::Release::Suite=bookworm \
      -o APT::FTPArchive::Release::Codename=bookworm \
      -o APT::FTPArchive::Release::Architectures=amd64 \
      -o APT::FTPArchive::Release::Components=main \
      release dists/bookworm > dists/bookworm/Release

FROM debian:12-slim

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl nginx; \
    rm -rf /var/lib/apt/lists/*

COPY --from=repository /repo /usr/share/nginx/html/debian
COPY deploy/infrastructure/apt/nginx.conf /etc/nginx/nginx.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
