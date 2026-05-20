add_custom_target(gups-pipeline
  COMMAND
    ${CMAKE_COMMAND} -E env
      ARBITER_BUILD_DIR=${CMAKE_BINARY_DIR}
      ${CMAKE_SOURCE_DIR}/scripts/build_gups_pipeline.sh
  DEPENDS
    arbiter-opt
    arbiter_runtime
  WORKING_DIRECTORY
    ${CMAKE_SOURCE_DIR}
  COMMENT
    "Building GUPS benchmark through the MLIR/Arbiter pipeline"
)
