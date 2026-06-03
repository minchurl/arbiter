#include "arbiter/LLVM/AllocationSite.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

namespace arbiter::llvm {
namespace {

StringRef getCalledName(const CallBase &call) {
  const Value *called = call.getCalledOperand()->stripPointerCasts();
  if (const auto *fn = dyn_cast<Function>(called))
    return fn->getName();
  return StringRef();
}

bool isPlacementNewName(StringRef name) {
  return name == "_ZnwmPv" || name == "_ZnamPv";
}

bool isCxxNewName(StringRef name) {
  return name.starts_with("_Znwm") && !isPlacementNewName(name);
}

bool isCxxNewArrayName(StringRef name) {
  return name.starts_with("_Znam") && !isPlacementNewName(name);
}

bool isCxxDeleteName(StringRef name) { return name.starts_with("_ZdlPv"); }

bool isCxxDeleteArrayName(StringRef name) {
  return name.starts_with("_ZdaPv");
}

std::string getFunctionName(const Function &fn) {
  if (const DISubprogram *subprogram = fn.getSubprogram()) {
    if (!subprogram->getName().empty())
      return subprogram->getName().str();
  }
  return fn.getName().str();
}

std::string getDebugFile(const DILocation *loc) {
  if (!loc)
    return "";

  StringRef filename = loc->getFilename();
  StringRef directory = loc->getDirectory();
  if (filename.empty())
    return "";
  if (sys::path::is_absolute(filename) || directory.empty())
    return filename.str();

  SmallString<256> path(directory);
  sys::path::append(path, filename);
  return path.str().str();
}

std::string valueExpr(Value *value) {
  if (!value)
    return "";
  std::string text;
  raw_string_ostream os(text);
  value->printAsOperand(os, false);
  return os.str();
}

std::string getSizeExpr(const CallBase &call, AllocationKind kind) {
  switch (kind) {
  case AllocationKind::Malloc:
  case AllocationKind::CxxNew:
  case AllocationKind::CxxNewArray:
    return call.arg_size() >= 1 ? valueExpr(call.getArgOperand(0)) : "";
  case AllocationKind::Calloc:
    if (call.arg_size() >= 2)
      return valueExpr(call.getArgOperand(0)) + "*" +
             valueExpr(call.getArgOperand(1));
    return "";
  case AllocationKind::MMap:
  case AllocationKind::MUnmap:
    return call.arg_size() >= 2 ? valueExpr(call.getArgOperand(1)) : "";
  default:
    return "";
  }
}

} // namespace

const char *kindToString(AllocationKind kind) {
  switch (kind) {
  case AllocationKind::Malloc:
    return "malloc";
  case AllocationKind::Calloc:
    return "calloc";
  case AllocationKind::Free:
    return "free";
  case AllocationKind::CxxNew:
    return "cxx-new";
  case AllocationKind::CxxNewArray:
    return "cxx-new-array";
  case AllocationKind::CxxDelete:
    return "cxx-delete";
  case AllocationKind::CxxDeleteArray:
    return "cxx-delete-array";
  case AllocationKind::MMap:
    return "mmap";
  case AllocationKind::MUnmap:
    return "munmap";
  case AllocationKind::Unknown:
    return "unknown";
  }
  return "unknown";
}

AllocationKind classifyCall(const CallBase &call) {
  StringRef name = getCalledName(call);
  if (name.empty())
    return AllocationKind::Unknown;

  if (name == "malloc")
    return AllocationKind::Malloc;
  if (name == "calloc")
    return AllocationKind::Calloc;
  if (name == "free")
    return AllocationKind::Free;
  if (name == "mmap" || name == "mmap64")
    return AllocationKind::MMap;
  if (name == "munmap")
    return AllocationKind::MUnmap;

  if (isCxxNewName(name))
    return AllocationKind::CxxNew;
  if (isCxxNewArrayName(name))
    return AllocationKind::CxxNewArray;
  if (isCxxDeleteName(name))
    return AllocationKind::CxxDelete;
  if (isCxxDeleteArrayName(name))
    return AllocationKind::CxxDeleteArray;

  return AllocationKind::Unknown;
}

bool isHeapAllocation(AllocationKind kind) {
  return kind == AllocationKind::Malloc || kind == AllocationKind::Calloc ||
         kind == AllocationKind::CxxNew || kind == AllocationKind::CxxNewArray;
}

bool isHeapDeallocation(AllocationKind kind) {
  return kind == AllocationKind::Free || kind == AllocationKind::CxxDelete ||
         kind == AllocationKind::CxxDeleteArray;
}

bool isMMapAllocation(AllocationKind kind) {
  return kind == AllocationKind::MMap;
}

bool isMMapDeallocation(AllocationKind kind) {
  return kind == AllocationKind::MUnmap;
}

bool isAnonymousMMap(const CallBase &call) {
  if (call.arg_size() < 4)
    return false;

  auto *flags = dyn_cast<ConstantInt>(call.getArgOperand(3));
  if (!flags)
    return false;

  constexpr uint64_t kLinuxMapAnonymous = 0x20;
  return (flags->getZExtValue() & kLinuxMapAnonymous) != 0;
}

std::vector<AllocationSite> collectAllocationSites(Module &module) {
  std::vector<AllocationSite> sites;
  uint32_t nextId = 1;

  for (Function &function : module) {
    if (function.isDeclaration())
      continue;

    for (Instruction &instruction : instructions(function)) {
      auto *call = dyn_cast<CallBase>(&instruction);
      if (!call)
        continue;

      AllocationKind kind = classifyCall(*call);
      if (kind == AllocationKind::Unknown)
        continue;

      DebugLoc debugLoc = call->getDebugLoc();
      const DILocation *loc = debugLoc ? debugLoc.get() : nullptr;

      AllocationSite site;
      site.id = nextId++;
      site.kind = kind;
      site.call = call;
      site.function = getFunctionName(function);
      site.file = getDebugFile(loc);
      site.line = loc ? loc->getLine() : 0;
      site.callee = getCalledName(*call).str();
      site.sizeExpr = getSizeExpr(*call, kind);
      sites.push_back(std::move(site));
    }
  }

  return sites;
}

} // namespace arbiter::llvm
