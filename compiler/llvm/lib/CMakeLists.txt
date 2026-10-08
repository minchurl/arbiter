add_llvm_library(ArbiterLLVM
  AllocationSite.cpp
  RewritePlan.cpp
  Passes.cpp
  hitm_seed/HITMRiskScoring.cpp
  hitm_seed/HITMSeedOptions.cpp
  hitm_seed/HITMSeedPasses.cpp
  ReportAllocationSites.cpp
  RewriteHeapAllocations.cpp
  RewriteMMapAllocations.cpp

  LINK_COMPONENTS
  Core
  Support
)
