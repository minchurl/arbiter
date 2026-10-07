add_llvm_library(ArbiterLLVM
  AllocationSite.cpp
  RewritePlan.cpp
  Passes.cpp
  hotset/HITMRiskScoring.cpp
  hotset/HotSetOptions.cpp
  hotset/HotSetPasses.cpp
  ReportAllocationSites.cpp
  RewriteHeapAllocations.cpp
  RewriteMMapAllocations.cpp

  LINK_COMPONENTS
  Core
  Support
)
