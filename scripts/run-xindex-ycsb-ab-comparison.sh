#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=run
if [[ "${1:-}" == "--check" ]]; then
  MODE=check
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: scripts/run-xindex-ycsb-ab-comparison.sh [--check]

Compares full-trace XIndex/YCSB-A and YCSB-B with the same native binary,
the same seed-rewritten binary, and the same HITM-risk seed policy. Each round runs
native, seed-local, and seed-target rows for both workloads. Workload and
placement order alternate between rounds. By default, each row consumes its
400M-operation transaction trace exactly once and exits.

Use --check to validate the machine, traces, config, disk headroom, and tools
without building or starting a benchmark.

Common overrides:
  ARBITER_HITM_SEED_CONFIG  policy config, default raw-046
  ARBITER_TARGET_NODE    CXL NUMA node, default 2
  ROUNDS                 balanced A/B rounds, default 4
  XINDEX_ITERATION       full-trace passes per row, default 1
  XINDEX_DURATION_SECONDS
                         default 0 (iteration mode); positive values repeat
                         each worker's trace partition for that many seconds
  RESULT_DIR             unique parent result directory
  BUILD_BENCHMARKS       rebuild once before round 1, default 1
  RUN_NATIVE             include native rows, default 1
EOF
  exit 0
elif [[ $# -ne 0 ]]; then
  echo "unknown argument: $1" >&2
  exit 1
fi

CONFIG="${ARBITER_HITM_SEED_CONFIG:-${ROOT_DIR}/configs/hitm-seed/candidates/raw-046.config}"
DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
TARGET_NODE="${ARBITER_TARGET_NODE:-2}"
CPU_NODE="${ARBITER_CPU_NODE:-0}"
MEM_NODE="${ARBITER_MEM_NODE:-0}"
ROUNDS="${ROUNDS:-4}"
ITERATIONS="${XINDEX_ITERATION:-1}"
DURATION_SECONDS="${XINDEX_DURATION_SECONDS:-0}"
SAMPLE_SECONDS="${XINDEX_THROUGHPUT_SAMPLE_SECONDS:-0}"
RUN_NATIVE_VALUE="${RUN_NATIVE:-1}"
REBUILD="${BUILD_BENCHMARKS:-1}"
MIN_FREE_GIB="${MIN_FREE_GIB:-8}"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-ycsb-ab-$(date +%Y%m%d-%H%M%S)}"
ARBITER_BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"

if [[ "${CONFIG}" != /* ]]; then
  CONFIG="${ROOT_DIR}/${CONFIG}"
fi
if [[ "${DATA_DIR}" != /* ]]; then
  DATA_DIR="${ROOT_DIR}/${DATA_DIR}"
fi
CONFIG_NAME="$(basename "${CONFIG}")"
CONFIG_NAME="${CONFIG_NAME%.config}"
HITM_SEED_BUILD_DIR="${HITM_SEED_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-ab-${CONFIG_NAME}}"

LOAD_PATH="${DATA_DIR}/xindex_load_ycsb_a.dat"
TX_A_PATH="${DATA_DIR}/xindex_transaction_ycsb_a.dat"
TX_B_PATH="${DATA_DIR}/xindex_transaction_ycsb_b.dat"
MANIFEST_PATH="${DATA_DIR}/github-parts/MANIFEST.sha256"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${name} must be a positive integer: ${value}" >&2
    exit 1
  fi
}

require_nonnegative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "${name} must be a non-negative integer: ${value}" >&2
    exit 1
  fi
}

resolve_tool() {
  local candidate
  for candidate in "$@"; do
    [[ -z "${candidate}" ]] && continue
    if [[ "${candidate}" == */* ]]; then
      if [[ -x "${candidate}" ]]; then
        printf '%s' "${candidate}"
        return 0
      fi
    elif command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
  done
  return 1
}

prepend_path() {
  local name="$1"
  local value="$2"
  local current="${!name:-}"
  if [[ -d "${value}" ]]; then
    printf -v "${name}" '%s' "${value}${current:+:${current}}"
    export "${name}"
  fi
}

for command in awk basename cat cp date df git head ln lscpu numactl pgrep sed \
  seq sha256sum stat systemd-run wc; do
  require_command "${command}"
done

for value_name in ROUNDS ITERATIONS MIN_FREE_GIB; do
  require_positive_integer "${value_name}" "${!value_name}"
done
for value_name in DURATION_SECONDS SAMPLE_SECONDS; do
  require_nonnegative_integer "${value_name}" "${!value_name}"
done
for value_name in RUN_NATIVE_VALUE REBUILD; do
  value="${!value_name}"
  if [[ "${value}" != "0" && "${value}" != "1" ]]; then
    echo "${value_name} must be 0 or 1: ${value}" >&2
    exit 1
  fi
done

for path in "${CONFIG}" "${LOAD_PATH}" "${TX_A_PATH}" "${TX_B_PATH}"; do
  if [[ ! -s "${path}" ]]; then
    echo "missing required A/B input: ${path}" >&2
    exit 1
  fi
done

CLANGXX_TOOL="${CLANGXX:-}"
OPT_TOOL="${OPT:-}"
if [[ "${REBUILD}" == "1" ]]; then
  if [[ -z "${CLANGXX_TOOL}" ]]; then
    CLANGXX_TOOL="$(resolve_tool \
      "${ROOT_DIR}/.tools/llvm-18.1.8/bin/clang++" \
      /usr/lib/llvm-18/bin/clang++ clang++-18 clang++)" || {
      echo "missing LLVM 18 clang++; set CLANGXX" >&2
      exit 1
    }
  fi
  if [[ -z "${OPT_TOOL}" ]]; then
    OPT_TOOL="$(resolve_tool \
      "${ROOT_DIR}/.tools/llvm18-apt-root/usr/bin/opt-18" \
      /usr/lib/llvm-18/bin/opt opt-18 opt)" || {
      echo "missing LLVM 18 opt; set OPT" >&2
      exit 1
    }
  fi

  if [[ "${CLANGXX_TOOL}" == "${ROOT_DIR}/.tools/"* || \
        "${OPT_TOOL}" == "${ROOT_DIR}/.tools/"* ]]; then
    prepend_path LD_LIBRARY_PATH "${ROOT_DIR}/.tools/libtinfo5-root/lib/x86_64-linux-gnu"
    prepend_path LD_LIBRARY_PATH "${ROOT_DIR}/.tools/libllvm18-root/usr/lib/x86_64-linux-gnu"
    prepend_path LIBRARY_PATH "${ROOT_DIR}/.tools/libstdcxx"
    prepend_path CPLUS_INCLUDE_PATH /usr/include/c++/11/backward
    prepend_path CPLUS_INCLUDE_PATH /usr/include/x86_64-linux-gnu/c++/11
    prepend_path CPLUS_INCLUDE_PATH /usr/include/c++/11
  fi

  CLANG_MAJOR="$("${CLANGXX_TOOL}" --version | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {split($i,v,"."); print v[1]; exit}}')"
  OPT_MAJOR="$("${OPT_TOOL}" --version | awk '/LLVM version/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {split($i,v,"."); print v[1]; exit}}')"
  if [[ "${CLANG_MAJOR}" != "18" || "${OPT_MAJOR}" != "18" ]]; then
    echo "A/B comparison requires LLVM 18; clang=${CLANG_MAJOR:-unknown}, opt=${OPT_MAJOR:-unknown}" >&2
    exit 1
  fi

  export CLANGXX="${CLANGXX_TOOL}"
  export OPT="${OPT_TOOL}"
fi

if [[ -z "${MKL_INCLUDE_DIR:-}" || -z "${MKL_LINK_DIR:-}" || -z "${MKL_RUNTIME_DIR:-}" ]]; then
  for mkl_root in /opt/intel/oneapi/mkl/latest /opt/intel/oneapi/mkl/2025.2 /opt/intel/oneapi/2025.2; do
    if [[ -f "${mkl_root}/include/mkl.h" && -f "${mkl_root}/lib/libmkl_rt.so" ]]; then
      MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR:-${mkl_root}/include}"
      MKL_LINK_DIR="${MKL_LINK_DIR:-${mkl_root}/lib}"
      MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-${mkl_root}/lib}"
      break
    fi
  done
fi
if [[ ! -f "${MKL_INCLUDE_DIR:-}/mkl.h" || ! -f "${MKL_LINK_DIR:-}/libmkl_rt.so" ]]; then
  echo "missing Intel MKL; set MKL_INCLUDE_DIR, MKL_LINK_DIR, and MKL_RUNTIME_DIR" >&2
  exit 1
fi
export MKL_INCLUDE_DIR MKL_LINK_DIR MKL_RUNTIME_DIR
prepend_path LD_LIBRARY_PATH "${MKL_RUNTIME_DIR}"

for node_spec in \
  "ARBITER_TARGET_NODE:${TARGET_NODE}" \
  "ARBITER_CPU_NODE:${CPU_NODE}" \
  "ARBITER_MEM_NODE:${MEM_NODE}"; do
  name="${node_spec%%:*}"
  value="${node_spec#*:}"
  if [[ ! "${value}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${value}" ]]; then
    echo "invalid ${name}=${value}" >&2
    exit 1
  fi
done
if [[ "${TARGET_NODE}" == "${MEM_NODE}" ]]; then
  echo "target and local memory nodes must differ" >&2
  exit 1
fi

CPU_COUNT="$(lscpu -p=CPU,NODE | awk -F, -v node="${CPU_NODE}" '$1 !~ /^#/ && $2 == node {count++} END {print count + 0}')"
if [[ "${CPU_COUNT}" -lt 32 ]]; then
  echo "node ${CPU_NODE} has ${CPU_COUNT} CPUs; A/B comparison requires at least 32" >&2
  exit 1
fi

FREE_BYTES="$(df -B1 --output=avail "${ROOT_DIR}" | awk 'NR == 2 {print $1}')"
MIN_FREE_BYTES=$((MIN_FREE_GIB * 1024 * 1024 * 1024))
if [[ "${FREE_BYTES}" -lt "${MIN_FREE_BYTES}" ]]; then
  echo "insufficient free disk: ${FREE_BYTES} bytes; require at least ${MIN_FREE_BYTES}" >&2
  exit 1
fi

TARGET_CPUS="$(cat "/sys/devices/system/node/node${TARGET_NODE}/cpulist")"
TARGET_MEMORY_KB="$(awk '/MemTotal/ {print $4}' "/sys/devices/system/node/node${TARGET_NODE}/meminfo")"
LOAD_BYTES="$(stat -c %s "${LOAD_PATH}")"
TX_A_BYTES="$(stat -c %s "${TX_A_PATH}")"
TX_B_BYTES="$(stat -c %s "${TX_B_PATH}")"
EXPECTED_B_SHA=""
if [[ -f "${MANIFEST_PATH}" ]]; then
  EXPECTED_B_SHA="$(awk '$2 == "xindex_transaction_ycsb_b.dat" {print $1}' "${MANIFEST_PATH}")"
fi
ROWS_PER_ROUND=$((2 * (2 + RUN_NATIVE_VALUE)))
TOTAL_ROWS=$((ROUNDS * ROWS_PER_ROUND))
if [[ "${DURATION_SECONDS}" -eq 0 ]]; then
  EXECUTION_MODE="one full transaction trace per row"
  PLANNED_OPERATIONS=$((TOTAL_ROWS * ITERATIONS * 400000000))
  PLANNED_WORK="${PLANNED_OPERATIONS} transaction operations"
else
  EXECUTION_MODE="fixed-duration trace replay"
  PLANNED_WORK="$((TOTAL_ROWS * DURATION_SECONDS)) measured seconds"
fi

cat <<EOF
XIndex/YCSB A/B comparison settings:
  config:                  ${CONFIG}
  workloads:               A (50R/50U), B (95R/5U), full traces
  trace bytes A-load/A/B:  ${LOAD_BYTES} / ${TX_A_BYTES} / ${TX_B_BYTES}
  expected B SHA-256:      ${EXPECTED_B_SHA:-not recorded}
  rounds / total rows:     ${ROUNDS} / ${TOTAL_ROWS}
  execution mode:          ${EXECUTION_MODE}
  iteration / duration:    ${ITERATIONS} / ${DURATION_SECONDS}s
  throughput sample:       ${SAMPLE_SECONDS}s (duration mode only)
  planned measured work:   ${PLANNED_WORK}
  workers:                 31 foreground + 1 background
  CPU / local / CXL:       ${CPU_NODE} / ${MEM_NODE} / ${TARGET_NODE}
  target node CPUs:        ${TARGET_CPUS:-none}
  target memory:           ${TARGET_MEMORY_KB} KiB
  memory / swap cap:       64G / 0
  arena capacity:          25769803776 bytes
  free disk / minimum:     ${FREE_BYTES} / ${MIN_FREE_BYTES} bytes
  rebuild / native rows:   ${REBUILD} / ${RUN_NATIVE_VALUE}
  clang++ / opt:           ${CLANGXX_TOOL:-not required} / ${OPT_TOOL:-not required}
  result:                  ${RESULT_DIR}
  order:                   A/B + local/target on odd rounds; both reversed on even rounds
  cache policy:            fresh process; warm filesystem cache; no drop_caches
EOF

if [[ "${MODE}" == "check" ]]; then
  echo "check-only mode: no build, result directory, or benchmark was started"
  exit 0
fi

if [[ -e "${RESULT_DIR}" ]]; then
  echo "result directory already exists: ${RESULT_DIR}" >&2
  exit 1
fi
if pgrep -af '[y]csb_bench' >/dev/null 2>&1 && [[ "${ALLOW_BUSY_HOST:-0}" != "1" ]]; then
  echo "another ycsb_bench process is running; use a quiet host or set ALLOW_BUSY_HOST=1" >&2
  exit 1
fi

mkdir -p "${RESULT_DIR}"
RUN_DATA_DIR="${RESULT_DIR}/data-view"
mkdir -p "${RUN_DATA_DIR}"
ln -s "${LOAD_PATH}" "${RUN_DATA_DIR}/xindex_load_ycsb_a.dat"
ln -s "${LOAD_PATH}" "${RUN_DATA_DIR}/xindex_load_ycsb_b.dat"
ln -s "${TX_A_PATH}" "${RUN_DATA_DIR}/xindex_transaction_ycsb_a.dat"
ln -s "${TX_B_PATH}" "${RUN_DATA_DIR}/xindex_transaction_ycsb_b.dat"
{
  echo "started_at=$(date --iso-8601=seconds)"
  echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  echo "git_branch=$(git -C "${ROOT_DIR}" branch --show-current)"
  echo "git_dirty_files=$(git -C "${ROOT_DIR}" status --porcelain | wc -l)"
  echo "config=${CONFIG}"
  echo "config_sha256=$(sha256sum "${CONFIG}" | awk '{print $1}')"
  echo "data_dir=${DATA_DIR}"
  echo "load_path=${LOAD_PATH}"
  echo "tx_a_path=${TX_A_PATH}"
  echo "tx_b_path=${TX_B_PATH}"
  echo "run_data_view=${RUN_DATA_DIR}"
  echo "expected_b_sha256=${EXPECTED_B_SHA}"
  echo "rounds=${ROUNDS}"
  echo "total_rows=${TOTAL_ROWS}"
  echo "iteration=${ITERATIONS}"
  echo "duration_seconds=${DURATION_SECONDS}"
  echo "sample_seconds=${SAMPLE_SECONDS}"
  echo "foreground_threads=31"
  echo "background_threads=1"
  echo "cpu_node=${CPU_NODE}"
  echo "local_memory_node=${MEM_NODE}"
  echo "target_memory_node=${TARGET_NODE}"
  echo "memory_max=64G"
  echo "memory_swap_max=0"
  echo "arena_slab_bytes=2097152"
  echo "arena_reserve_bytes=25769803776"
  echo "arena_slot_alignment=64"
  echo "build_benchmarks=${REBUILD}"
  echo "run_native=${RUN_NATIVE_VALUE}"
  echo "clangxx=${CLANGXX_TOOL:-not required}"
  echo "opt=${OPT_TOOL:-not required}"
  echo "cache_policy=fresh process per row; filesystem page cache not dropped; CPU cache not flushed"
  echo
  numactl --hardware
} > "${RESULT_DIR}/ab-manifest.txt"

for round in $(seq 1 "${ROUNDS}"); do
  round_label="$(printf '%02d' "${round}")"
  round_dir="${RESULT_DIR}/round-${round_label}"
  workloads="a b"
  first_placement=local
  if (( round % 2 == 0 )); then
    workloads="b a"
    first_placement=target
  fi
  round_build=0
  if [[ "${round}" -eq 1 ]]; then
    round_build="${REBUILD}"
  fi

  echo "[round ${round}/${ROUNDS}] workloads=${workloads} first_placement=${first_placement} build=${round_build}"
  env \
    RESULT_DIR="${round_dir}" \
    HITM_SEED_BUILD_DIR="${HITM_SEED_BUILD_DIR}" \
    XINDEX_SCALE_DATA_DIR="${RUN_DATA_DIR}" \
    XINDEX_SCALE_LOAD_RECORDS=100000000 \
    XINDEX_SCALE_TX_OPS=400000000 \
    XINDEX_ITERATION="${ITERATIONS}" \
    XINDEX_DURATION_SECONDS="${DURATION_SECONDS}" \
    XINDEX_THROUGHPUT_SAMPLE_SECONDS="${SAMPLE_SECONDS}" \
    XINDEX_FG=31 \
    XINDEX_BG=1 \
    YCSB_TYPES="${workloads}" \
    REPEATS=1 \
    ARBITER_CPU_NODE="${CPU_NODE}" \
    ARBITER_MEM_NODE="${MEM_NODE}" \
    ARBITER_TARGET_NODE="${TARGET_NODE}" \
    ARBITER_HITM_SEED_CONFIG="${CONFIG}" \
    ARBITER_HEAP_BACKEND=arena \
    ARBITER_ARENA_SLAB_BYTES=2097152 \
    ARBITER_ARENA_RESERVE_BYTES=25769803776 \
    ARBITER_ARENA_SLOT_ALIGNMENT=64 \
    ARBITER_ARENA_STRICT=1 \
    ARBITER_ARENA_REPORT=1 \
    MEMORY_MAX=64G \
    MEMORY_SWAP_MAX=0 \
    RUN_NATIVE="${RUN_NATIVE_VALUE}" \
    RUN_LOCAL=1 \
    RUN_TARGET=1 \
    BUILD_BENCHMARKS="${round_build}" \
    PREPARE_SCALE_DATA=0 \
    FAIL_FAST=1 \
    ALTERNATE_PLACEMENT_ORDER=0 \
    FIRST_PLACEMENT="${first_placement}" \
    COOLDOWN_SECONDS=2 \
    USE_SYSTEMD_SCOPE=1 \
    ARBITER_BUILD_DIR="${ARBITER_BUILD_DIR}" \
    CLANGXX="${CLANGXX_TOOL}" \
    OPT="${OPT_TOOL}" \
    MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR}" \
    MKL_LINK_DIR="${MKL_LINK_DIR}" \
    MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR}" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
    LIBRARY_PATH="${LIBRARY_PATH:-}" \
    CPLUS_INCLUDE_PATH="${CPLUS_INCLUDE_PATH:-}" \
    "${ROOT_DIR}/scripts/run-protected-hitm-seed-experiment.sh"
done

RUNS_CSV="${RESULT_DIR}/runs.csv"
SAMPLES_CSV="${RESULT_DIR}/throughput-samples.csv"
first=1
for round in $(seq 1 "${ROUNDS}"); do
  round_label="$(printf '%02d' "${round}")"
  round_runs="${RESULT_DIR}/round-${round_label}/runs.csv"
  round_samples="${RESULT_DIR}/round-${round_label}/throughput-samples.csv"
  if [[ "${first}" -eq 1 ]]; then
    head -n 1 "${round_runs}" > "${RUNS_CSV}"
    head -n 1 "${round_samples}" > "${SAMPLES_CSV}"
    first=0
  fi
  awk -F, -v OFS=, -v round="${round}" 'NR > 1 {$4=round; print}' \
    "${round_runs}" >> "${RUNS_CSV}"
  awk -F, -v OFS=, -v round="${round}" 'NR > 1 {$4=round; print}' \
    "${round_samples}" >> "${SAMPLES_CSV}"
done

SUMMARY_CSV="${RESULT_DIR}/summary.csv"
printf 'benchmark,workload,config,metric,repeats,avg_time_sec,avg_throughput,avg_max_rss_kb\n' > "${SUMMARY_CSV}"
for workload in a b; do
  for config in native hitm-seed-local hitm-seed-target; do
    awk -F, -v workload="${workload}" -v config="${config}" '
      NR > 1 && $2 == workload && $3 == config && $20 == "ok" {
        count++
        time += $13
        throughput += $14
        rss += $15
      }
      END {
        if (count > 0)
          printf "xindex,%s,%s,op/s,%d,%.9g,%.9g,%.9g\n", workload,
                 config, count, time / count, throughput / count, rss / count
      }
    ' "${RUNS_CSV}" >> "${SUMMARY_CSV}"
  done
done

COMPARISON_CSV="${RESULT_DIR}/ab-comparison.csv"
printf 'workload,rounds,native_avg_ops,local_avg_ops,target_avg_ops,local_vs_native_pct,target_vs_local_pct,target_vs_native_pct,local_resident_gib,target_resident_gib,local_arena_allocations,target_arena_allocations\n' > "${COMPARISON_CSV}"
for workload in a b; do
  awk -F, -v workload="${workload}" '
    NR > 1 && $2 == workload && $20 == "ok" {
      config=$3
      count[config]++
      throughput[config]+=$14
      if (config != "native") {
        allocations[config]+=$26
        resident[config]+=$31
      }
    }
    END {
      native=(count["native"] ? throughput["native"]/count["native"] : 0)
      local=(count["hitm-seed-local"] ? throughput["hitm-seed-local"]/count["hitm-seed-local"] : 0)
      target=(count["hitm-seed-target"] ? throughput["hitm-seed-target"]/count["hitm-seed-target"] : 0)
      local_native=(native ? (local/native-1)*100 : 0)
      target_local=(local ? (target/local-1)*100 : 0)
      target_native=(native ? (target/native-1)*100 : 0)
      local_resident=(count["hitm-seed-local"] ? resident["hitm-seed-local"]/count["hitm-seed-local"]/(1024^3) : 0)
      target_resident=(count["hitm-seed-target"] ? resident["hitm-seed-target"]/count["hitm-seed-target"]/(1024^3) : 0)
      local_alloc=(count["hitm-seed-local"] ? allocations["hitm-seed-local"]/count["hitm-seed-local"] : 0)
      target_alloc=(count["hitm-seed-target"] ? allocations["hitm-seed-target"]/count["hitm-seed-target"] : 0)
      printf "%s,%d,%.9g,%.9g,%.9g,%.6f,%.6f,%.6f,%.6f,%.6f,%.9g,%.9g\n",
             workload, count["hitm-seed-target"], native, local, target,
             local_native, target_local, target_native, local_resident,
             target_resident, local_alloc, target_alloc
    }
  ' "${RUNS_CSV}" >> "${COMPARISON_CSV}"
done

SUMMARY_MD="${RESULT_DIR}/summary.md"
{
  echo "# XIndex/YCSB A/B Comparison"
  echo
  echo "- Config: \`${CONFIG}\`"
  echo "- Rounds: ${ROUNDS}"
  echo "- Full traces: 100M load records / 400M transaction operations"
  echo "- Workloads: A (50% read, 50% update); B (95% read, 5% update)"
  echo "- Rows per workload: native/local/CXL x ${ROUNDS}"
  echo "- Workers: 31 foreground + 1 background"
  if [[ "${DURATION_SECONDS}" -eq 0 ]]; then
    echo "- Execution: consume the 400M-operation transaction trace ${ITERATIONS} time(s) per row"
    echo "- Throughput: completed transaction operations divided by measured transaction time"
  else
    echo "- Execution: repeat trace partitions for ${DURATION_SECONDS}s per row"
    echo "- Throughput sample: every ${SAMPLE_SECONDS}s"
  fi
  echo "- CPU/local/CXL nodes: ${CPU_NODE}/${MEM_NODE}/${TARGET_NODE}"
  echo "- Memory protection: MemoryMax=64G, MemorySwapMax=0"
  echo "- Ordering: workload and local/CXL order reverse on even rounds"
  echo "- Cache policy: fresh process per row, warm filesystem cache, no drop_caches"
  echo
  echo "| Workload | Rounds | Native op/s | Local op/s | CXL op/s | Local vs native | CXL vs local | CXL vs native | Local arena GiB | CXL arena GiB |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
  awk -F, 'NR > 1 {
    printf "| %s | %d | %.3fM | %.3fM | %.3fM | %+.2f%% | %+.2f%% | %+.2f%% | %.3f | %.3f |\n",
           toupper($1), $2, $3/1000000, $4/1000000, $5/1000000,
           $6, $7, $8, $9, $10
  }' "${COMPARISON_CSV}"
  echo
  echo "The local and CXL rows use the same rewritten binary and HITM-risk seed policy."
  echo "The comparison changes only the YCSB trace and selected-arena node."
  echo "Runtime allocation counts and resident arena bytes are retained in"
  echo "\`ab-comparison.csv\` and \`runs.csv\` to show whether A and B activate"
  echo "the selected allocation sites differently."
} > "${SUMMARY_MD}"

cp "${RESULT_DIR}/round-01/hitm-seed-input.config" "${RESULT_DIR}/hitm-seed-input.config"
cp "${RESULT_DIR}/round-01/hitm-seed-sites.csv" "${RESULT_DIR}/hitm-seed-sites.csv"
cp "${RESULT_DIR}/round-01/hitm-seed-effective.opt-args" "${RESULT_DIR}/hitm-seed-effective.opt-args"
cp "${RESULT_DIR}/round-01/binaries.sha256" "${RESULT_DIR}/binaries.sha256"

cat <<EOF

XIndex/YCSB A/B comparison complete.
Results:
  ${SUMMARY_MD}
  ${COMPARISON_CSV}
  ${RUNS_CSV}
  ${SAMPLES_CSV}
  ${RESULT_DIR}/ab-manifest.txt
EOF
