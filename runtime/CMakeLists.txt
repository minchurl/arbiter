add_library(arbiter_runtime STATIC
  src/arbiter_runtime.cpp
)

target_include_directories(arbiter_runtime
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)

find_path(NUMA_INCLUDE_DIR numa.h)
find_path(NUMAIF_INCLUDE_DIR numaif.h)
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

if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND NUMA_INCLUDE_DIR AND
   NUMAIF_INCLUDE_DIR AND NUMA_LIBRARY)
  add_executable(arbiter-numa-placement
    ../tests/Runtime/arbiter-numa-placement.cpp
  )

  target_include_directories(arbiter-numa-placement
    PRIVATE
    ${NUMA_INCLUDE_DIR}
    ${NUMAIF_INCLUDE_DIR}
  )

  target_link_libraries(arbiter-numa-placement
    PRIVATE
    arbiter_runtime
  )

  set_target_properties(arbiter-numa-placement PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${LLVM_RUNTIME_OUTPUT_INTDIR}
  )
else()
  message(STATUS
    "Skipping arbiter-numa-placement: Linux libnuma development files not found"
  )
endif()
