configure_xindex_experiment() {
  "${OPT}" \
    -load-pass-plugin "${PLUGIN}" \
    -passes=arbiter-report-shared-mutable-sites \
    -arbiter-shared-mutable-report-path="${OUT_DIR}/ycsb_bench.shared-mutable-sites.csv" \
    -disable-output \
    "${OUT_DIR}/ycsb_bench.bc"

  REWRITE_PASS="arbiter-experiment-shared-mutable-rewrite"
  EXPERIMENT_REPORTS=("ycsb_bench.shared-mutable-sites.csv")
}
