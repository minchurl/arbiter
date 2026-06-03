add_library(arbiter_runtime_mlir_legacy STATIC
  src/arbiter_runtime.cpp
)

target_include_directories(arbiter_runtime_mlir_legacy
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)

if(NUMA_INCLUDE_DIR AND NUMA_LIBRARY)
  target_compile_definitions(arbiter_runtime_mlir_legacy
    PRIVATE
    ARBITER_HAS_NUMA=1
  )
  target_include_directories(arbiter_runtime_mlir_legacy
    PRIVATE
    ${NUMA_INCLUDE_DIR}
  )
  target_link_libraries(arbiter_runtime_mlir_legacy
    PUBLIC
    ${NUMA_LIBRARY}
  )
else()
  target_compile_definitions(arbiter_runtime_mlir_legacy
    PRIVATE
    ARBITER_HAS_NUMA=0
  )
endif()
