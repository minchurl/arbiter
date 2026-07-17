configure_xindex_experiment() {
  "${OPT}" \
    -load-pass-plugin "${PLUGIN}" \
    -passes=arbiter-report-lock-touch-sites \
    -arbiter-lock-touch-report-path="${OUT_DIR}/ycsb_bench.lock-touch-sites.csv" \
    -disable-output \
    "${OUT_DIR}/ycsb_bench.bc"

  REWRITE_PASS="arbiter-experiment-lock-touch-instrument"
  EXPERIMENT_REPORTS=("ycsb_bench.lock-touch-sites.csv")
}
