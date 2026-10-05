#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

command -v yamllint >/dev/null || {
  echo "Missing required command: yamllint" >&2
  exit 1
}

echo "Validating shell syntax"
bash -n .github/scripts/*.sh
bash -n deploy/scripts/*.sh
bash -n deploy/infrastructure/scripts/*.sh

echo "Validating YAML"
yamllint \
  -d '{extends: default, rules: {line-length: disable}}' \
  config deploy .github

echo "Validation passed"
