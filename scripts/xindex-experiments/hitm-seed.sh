configure_xindex_experiment() {
  local config_path="${ARBITER_HITM_SEED_CONFIG:-}"
  local settings=(
    ARBITER_HITM_MIN_SCORE=6
    ARBITER_HITM_SEED_LIMIT=3
    ARBITER_HITM_SEED_SITE_IDS=
    ARBITER_HITM_WEIGHT_ESCAPE_RETURN=3
    ARBITER_HITM_WEIGHT_ESCAPE_STORE=3
    ARBITER_HITM_WEIGHT_ESCAPE_CALL=2
    ARBITER_HITM_WEIGHT_SYNC_ATOMIC=3
    ARBITER_HITM_WEIGHT_SYNC_STORE=2
    ARBITER_HITM_WEIGHT_SYNC_INLINE_ASM=2
    ARBITER_HITM_WEIGHT_SYNC_FILE=1
    ARBITER_HITM_WEIGHT_WORKER_ENTRY=3
    ARBITER_HITM_WEIGHT_WORKER_REACHABLE=2
    ARBITER_HITM_WEIGHT_SIZE=1
    ARBITER_HITM_REQUIRE_ESCAPE=1
    ARBITER_HITM_REQUIRE_SYNC=1
    ARBITER_HITM_LARGE_ALLOCATION_THRESHOLD=4096
    ARBITER_HITM_INCLUDE_DYNAMIC_SIZE=1
    ARBITER_HITM_SEED_REPORT_PATH=
    ARBITER_HITM_SEED_DYNAMIC_SIZE_ESTIMATE=4096
    ARBITER_HITM_SEED_MAX_ESTIMATED_BYTES=0
  )
  local setting key option

  # Shadow ambient exported values with local defaults before sourcing config.
  for setting in "${settings[@]}"; do
    local "${setting}"
  done

  if [[ -n "${config_path}" ]]; then
    if [[ ! -f "${config_path}" && -f "${ROOT_DIR}/${config_path}" ]]; then
      config_path="${ROOT_DIR}/${config_path}"
    fi
    if [[ ! -f "${config_path}" ]]; then
      echo "missing ARBITER_HITM_SEED_CONFIG=${ARBITER_HITM_SEED_CONFIG}" >&2
      exit 1
    fi

    # shellcheck source=/dev/null
    source "${config_path}"
  fi

  local report_path="${ARBITER_HITM_SEED_REPORT_PATH:-${OUT_DIR}/ycsb_bench.hitm-seed-sites.csv}"
  local effective_args_path="${OUT_DIR}/ycsb_bench.hitm-seed-effective.opt-args"

  REWRITE_ARGS=(-arbiter-hitm-seed-report-path="${report_path}")
  for setting in "${settings[@]}"; do
    key="${setting%%=*}"
    [[ "${key}" == ARBITER_HITM_SEED_REPORT_PATH ]] && continue
    option="${key#ARBITER_}"
    option="${option,,}"
    option="${option//_/-}"
    REWRITE_ARGS+=("-arbiter-${option}=${!key}")
  done

  printf '%s\n' "${REWRITE_ARGS[@]}" >"${effective_args_path}"

  "${OPT}" \
    -load-pass-plugin "${PLUGIN}" \
    -passes=arbiter-report-hitm-seed-sites \
    "${REWRITE_ARGS[@]}" \
    -disable-output \
    "${OUT_DIR}/ycsb_bench.bc"

  REWRITE_PASS="arbiter-experiment-hitm-seed-rewrite"
  EXPERIMENT_REPORTS=("${report_path}" "${effective_args_path}")
}
