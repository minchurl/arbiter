add_library(arbiter_runtime STATIC
  src/arbiter_runtime.cpp
)

target_include_directories(arbiter_runtime
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)

find_path(NUMA_INCLUDE_DIR numa.h)
find_library(NUMA_LIBRARY numa)

if(NUMA_INCLUDE_DIR AND NUMA_LIBRARY)
  target_compile_definitions(arbiter_runtime PRIVATE ARBITER_HAS_NUMA=1)
  target_include_directories(arbiter_runtime PRIVATE ${NUMA_INCLUDE_DIR})
  target_link_libraries(arbiter_runtime PUBLIC ${NUMA_LIBRARY})
else()
  target_compile_definitions(arbiter_runtime PRIVATE ARBITER_HAS_NUMA=0)
endif()

add_executable(arbiter-runtime-smoke
  ../tests/Runtime/arbiter-runtime-smoke.cpp
)

target_link_libraries(arbiter-runtime-smoke
  PRIVATE
  arbiter_runtime
)

set_target_properties(arbiter-runtime-smoke PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${LLVM_RUNTIME_OUTPUT_INTDIR}
)
