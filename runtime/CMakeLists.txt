add_library(arbiter_runtime STATIC
  src/arbiter_runtime.cpp
)

target_include_directories(arbiter_runtime
  PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
