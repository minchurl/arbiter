#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-local}"
TARGET="${GUPS_TARGET:-gups}"
ARBITER_BIN="${ARBITER_GUPS_BIN:-${ROOT_DIR}/build/arbiter-bench/gups/${TARGET}-arbiter}"
NATIVE_BIN="${NATIVE_GUPS_BIN:-${ROOT_DIR}/benchmark/gups/${TARGET}}"
ARGS_STRING="${GUPS_ARGS:-16 2000000000 35 8 32 90}"

read -r -a ARGS <<< "${ARGS_STRING}"

case "${MODE}" in
  native)
    if [[ ! -x "${NATIVE_BIN}" ]]; then
      echo "missing native GUPS binary: ${NATIVE_BIN}" >&2
      echo "try: make -C ${ROOT_DIR}/benchmark/gups gups" >&2
      exit 1
    fi
    exec "${NATIVE_BIN}" "${ARGS[@]}"
    ;;
  local)
    unset ARBITER_TARGET_NODE
    if [[ ! -x "${ARBITER_BIN}" ]]; then
      echo "missing Arbiter GUPS binary: ${ARBITER_BIN}" >&2
      echo "try: ./scripts/build-gups-llvm.sh" >&2
      exit 1
    fi
    exec "${ARBITER_BIN}" "${ARGS[@]}"
    ;;
  remote)
    if [[ -z "${ARBITER_TARGET_NODE:-}" ]]; then
      echo "ARBITER_TARGET_NODE must be set for remote mode" >&2
      exit 1
    fi
    if [[ ! -x "${ARBITER_BIN}" ]]; then
      echo "missing Arbiter GUPS binary: ${ARBITER_BIN}" >&2
      echo "try: ./scripts/build-gups-llvm.sh" >&2
      exit 1
    fi
    exec "${ARBITER_BIN}" "${ARGS[@]}"
    ;;
  *)
    echo "usage: $0 [native|local|remote]" >&2
    exit 1
    ;;
esac
