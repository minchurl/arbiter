configure_xindex_experiment() {
  if [[ -n "${ARBITER_HOTSET_CONFIG:-}" ]]; then
    local config_path="${ARBITER_HOTSET_CONFIG}"
    if [[ ! -f "${config_path}" && -f "${ROOT_DIR}/${config_path}" ]]; then
      config_path="${ROOT_DIR}/${config_path}"
    fi
    if [[ ! -f "${config_path}" ]]; then
      echo "missing ARBITER_HOTSET_CONFIG=${ARBITER_HOTSET_CONFIG}" >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    source "${config_path}"
  fi

  if [[ -n "${ARBITER_HOTSET_EXPAND_SCOPE+x}" ]]; then
    echo "ARBITER_HOTSET_EXPAND_SCOPE was removed; use ARBITER_HOTSET_EXPANSION=none|use" >&2
    exit 1
  fi
  if [[ -n "${ARBITER_HOTSET_MEMBER_MIN_SCORE+x}" ]]; then
    echo "ARBITER_HOTSET_MEMBER_MIN_SCORE was removed; use ARBITER_HOTSET_MEMBER_MIN_AFFINITY=1|3|5" >&2
    exit 1
  fi

  local report_path="${ARBITER_HOTSET_REPORT_PATH:-${OUT_DIR}/ycsb_bench.hotset-sites.csv}"
  local effective_args_path="${OUT_DIR}/ycsb_bench.hotset-effective.opt-args"

  REWRITE_ARGS=(
    -arbiter-hotset-report-path="${report_path}"
    -arbiter-hotset-min-score="${ARBITER_HOTSET_MIN_SCORE:-6}"
    -arbiter-hotset-seed-limit="${ARBITER_HOTSET_SEED_LIMIT:-3}"
    -arbiter-hotset-seed-site-ids="${ARBITER_HOTSET_SEED_SITE_IDS:-}"
    -arbiter-hotset-expansion="${ARBITER_HOTSET_EXPANSION:-use}"
    -arbiter-hotset-max-sites="${ARBITER_HOTSET_MAX_SITES:-16}"
    -arbiter-hotset-include-mmap="${ARBITER_HOTSET_INCLUDE_MMAP:-0}"
    -arbiter-hotset-placement="${ARBITER_HOTSET_PLACEMENT:-local}"
    -arbiter-hotset-target-node="${ARBITER_HOTSET_TARGET_NODE:-0}"
    -arbiter-hotset-weight-escape-return="${ARBITER_HOTSET_WEIGHT_ESCAPE_RETURN:-3}"
    -arbiter-hotset-weight-escape-store="${ARBITER_HOTSET_WEIGHT_ESCAPE_STORE:-3}"
    -arbiter-hotset-weight-escape-call="${ARBITER_HOTSET_WEIGHT_ESCAPE_CALL:-2}"
    -arbiter-hotset-weight-sync-atomic="${ARBITER_HOTSET_WEIGHT_SYNC_ATOMIC:-3}"
    -arbiter-hotset-weight-sync-store="${ARBITER_HOTSET_WEIGHT_SYNC_STORE:-2}"
    -arbiter-hotset-weight-sync-inline-asm="${ARBITER_HOTSET_WEIGHT_SYNC_INLINE_ASM:-2}"
    -arbiter-hotset-weight-sync-file="${ARBITER_HOTSET_WEIGHT_SYNC_FILE:-1}"
    -arbiter-hotset-weight-worker-entry="${ARBITER_HOTSET_WEIGHT_WORKER_ENTRY:-3}"
    -arbiter-hotset-weight-worker-reachable="${ARBITER_HOTSET_WEIGHT_WORKER_REACHABLE:-2}"
    -arbiter-hotset-weight-size="${ARBITER_HOTSET_WEIGHT_SIZE:-1}"
    -arbiter-hotset-require-escape="${ARBITER_HOTSET_REQUIRE_ESCAPE:-1}"
    -arbiter-hotset-require-sync="${ARBITER_HOTSET_REQUIRE_SYNC:-1}"
    -arbiter-hotset-large-allocation-threshold="${ARBITER_HOTSET_LARGE_ALLOCATION_THRESHOLD:-4096}"
    -arbiter-hotset-include-dynamic-size="${ARBITER_HOTSET_INCLUDE_DYNAMIC_SIZE:-1}"
    -arbiter-hotset-dynamic-size-estimate="${ARBITER_HOTSET_DYNAMIC_SIZE_ESTIMATE:-4096}"
    -arbiter-hotset-max-estimated-bytes="${ARBITER_HOTSET_MAX_ESTIMATED_BYTES:-0}"
    -arbiter-hotset-max-members-per-seed="${ARBITER_HOTSET_MAX_MEMBERS_PER_SEED:-4}"
    -arbiter-hotset-member-min-affinity="${ARBITER_HOTSET_MEMBER_MIN_AFFINITY:-3}"
    -arbiter-hotset-member-max-call-depth="${ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH:-1}"
    -arbiter-hotset-member-max-load-depth="${ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH:-2}"
  )

  printf '%s\n' "${REWRITE_ARGS[@]}" >"${effective_args_path}"

  "${OPT}" \
    -load-pass-plugin "${PLUGIN}" \
    -passes=arbiter-report-hotset-sites \
    "${REWRITE_ARGS[@]}" \
    -disable-output \
    "${OUT_DIR}/ycsb_bench.bc"

  REWRITE_PASS="arbiter-experiment-hotset-rewrite"
  EXPERIMENT_REPORTS=("${report_path}" "${effective_args_path}")
}
