#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ARBITER_XINDEX_EXPERIMENT=lock-touch \
  exec "${ROOT_DIR}/scripts/build-xindex-llvm.sh"
