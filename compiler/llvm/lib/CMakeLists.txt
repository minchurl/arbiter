add_llvm_library(ArbiterLLVM
  AllocationSite.cpp
  RewritePlan.cpp
  Passes.cpp
  PatternPlacement.cpp
  ReportAllocationSites.cpp
  RewriteHeapAllocations.cpp
  RewriteMMapAllocations.cpp

  LINK_COMPONENTS
  Core
  Support
)
