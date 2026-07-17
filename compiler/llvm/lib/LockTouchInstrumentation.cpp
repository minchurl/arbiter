#include "arbiter/LLVM/Passes.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

#include <memory>
#include <string>
#include <vector>

using namespace llvm;

namespace arbiter::llvm {
namespace {

struct LockTouchSite {
  uint32_t id = 0;
  Instruction *instruction = nullptr;
  Value *target = nullptr;
  std::string function;
  std::string file;
  uint32_t line = 0;
  std::string kind;
  std::string targetExpr;
};

bool contains(StringRef value, StringRef needle) {
  return value.find(needle) != StringRef::npos;
}

StringRef getCalledName(const CallBase &call) {
  const Value *called = call.getCalledOperand()->stripPointerCasts();
  if (const auto *fn = dyn_cast<Function>(called))
    return fn->getName();
  return StringRef();
}

bool isPThreadLockName(StringRef name) {
  return name == "pthread_mutex_lock" || name == "pthread_mutex_trylock" ||
         name == "pthread_rwlock_rdlock" ||
         name == "pthread_rwlock_wrlock" || name == "pthread_spin_lock";
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

Value *firstPointerArg(CallBase &call) {
  for (Use &arg : call.args()) {
    Value *value = arg.get();
    if (value->getType()->isPointerTy())
      return value;
  }
  return nullptr;
}

bool classifyInlineAsm(CallBase &call, std::string &kind, Value *&target) {
  const auto *asmValue =
      dyn_cast<InlineAsm>(call.getCalledOperand()->stripPointerCasts());
  if (!asmValue)
    return false;

  StringRef asmText = asmValue->getAsmString();
  bool hasCmpXchg = contains(asmText, "cmpxchg");
  bool hasLock = contains(asmText, "lock");
  if (!hasCmpXchg && !hasLock)
    return false;

  target = firstPointerArg(call);
  if (!target)
    return false;

  kind = hasCmpXchg ? "inline-asm-cmpxchg" : "inline-asm-lock";
  return true;
}

bool classifyCall(CallBase &call, std::string &kind, Value *&target) {
  StringRef name = getCalledName(call);
  if (!name.empty() && isPThreadLockName(name)) {
    if (call.arg_size() < 1 || !call.getArgOperand(0)->getType()->isPointerTy())
      return false;

    kind = name.str();
    target = call.getArgOperand(0);
    return true;
  }

  return classifyInlineAsm(call, kind, target);
}

bool classifyInstruction(Instruction &instruction, std::string &kind,
                         Value *&target) {
  if (auto *call = dyn_cast<CallBase>(&instruction))
    return classifyCall(*call, kind, target);

  if (auto *atomicRmw = dyn_cast<AtomicRMWInst>(&instruction)) {
    kind = "atomicrmw";
    target = atomicRmw->getPointerOperand();
    return true;
  }

  if (auto *cmpxchg = dyn_cast<AtomicCmpXchgInst>(&instruction)) {
    kind = "cmpxchg";
    target = cmpxchg->getPointerOperand();
    return true;
  }

  if (auto *store = dyn_cast<StoreInst>(&instruction)) {
    if (!store->isAtomic())
      return false;

    kind = "atomic-store";
    target = store->getPointerOperand();
    return true;
  }

  return false;
}

LockTouchSite makeSite(uint32_t id, Instruction &instruction,
                       StringRef kind, Value *target) {
  DebugLoc debugLoc = instruction.getDebugLoc();
  const DILocation *loc = debugLoc ? debugLoc.get() : nullptr;

  LockTouchSite site;
  site.id = id;
  site.instruction = &instruction;
  site.target = target;
  site.function = getFunctionName(*instruction.getFunction());
  site.file = getDebugFile(loc);
  site.line = loc ? loc->getLine() : 0;
  site.kind = kind.str();
  site.targetExpr = valueExpr(target);
  return site;
}

std::vector<LockTouchSite> collectLockTouchSites(Module &module) {
  std::vector<LockTouchSite> sites;
  uint32_t nextId = 1;

  for (Function &function : module) {
    if (function.isDeclaration())
      continue;

    for (Instruction &instruction : instructions(function)) {
      std::string kind;
      Value *target = nullptr;
      if (!classifyInstruction(instruction, kind, target))
        continue;
      if (!target || !target->getType()->isPointerTy())
        continue;

      sites.push_back(makeSite(nextId++, instruction, kind, target));
    }
  }

  return sites;
}

void csvValue(raw_ostream &os, StringRef value) {
  bool quote = value.contains(',') || value.contains('"') ||
               value.contains('\n') || value.contains('\r');
  if (!quote) {
    os << value;
    return;
  }

  os << '"';
  for (char ch : value) {
    if (ch == '"')
      os << "\"\"";
    else
      os << ch;
  }
  os << '"';
}

std::unique_ptr<raw_fd_ostream> openFile(StringRef path,
                                         std::error_code &error) {
  if (path.empty() || path == "-")
    return nullptr;
  return std::make_unique<raw_fd_ostream>(path, error, sys::fs::OF_Text);
}

void emitLockTouchReport(raw_ostream &os, ArrayRef<LockTouchSite> sites) {
  os << "site_id,function,file,line,kind,target\n";
  for (const LockTouchSite &site : sites) {
    os << site.id << ',';
    csvValue(os, site.function);
    os << ',';
    csvValue(os, site.file);
    os << ',' << site.line << ',';
    csvValue(os, site.kind);
    os << ',';
    csvValue(os, site.targetExpr);
    os << '\n';
  }
}

FunctionCallee getLockTouchFn(Module &module) {
  LLVMContext &context = module.getContext();
  Type *voidTy = Type::getVoidTy(context);
  Type *ptrTy = PointerType::getUnqual(context);
  Type *i32Ty = Type::getInt32Ty(context);
  return module.getOrInsertFunction("arbiter_lock_touch", voidTy, ptrTy,
                                    i32Ty);
}

Value *runtimePointer(IRBuilder<> &builder, Value *target) {
  Type *ptrTy = PointerType::getUnqual(builder.getContext());
  if (target->getType() == ptrTy)
    return target;
  return builder.CreateAddrSpaceCast(target, ptrTy);
}

bool instrumentLockTouchSites(Module &module, ArrayRef<LockTouchSite> sites) {
  if (sites.empty())
    return false;

  FunctionCallee touchFn = getLockTouchFn(module);
  for (const LockTouchSite &site : sites) {
    IRBuilder<> builder(site.instruction);
    builder.SetCurrentDebugLocation(site.instruction->getDebugLoc());
    Value *target = runtimePointer(builder, site.target);
    Value *siteId = ConstantInt::get(builder.getInt32Ty(), site.id);
    builder.CreateCall(touchFn, {target, siteId});
  }

  return true;
}

} // namespace

PreservedAnalyses LockTouchReportPass::run(Module &module,
                                           ModuleAnalysisManager &manager) {
  (void)manager;

  std::vector<LockTouchSite> sites = collectLockTouchSites(module);

  std::error_code ec;
  std::unique_ptr<raw_fd_ostream> file =
      openFile(ArbiterLockTouchReportPath, ec);
  if (ec) {
    errs() << "arbiter: failed to open lock-touch report path "
           << ArbiterLockTouchReportPath << ": " << ec.message() << "\n";
    return PreservedAnalyses::all();
  }

  raw_ostream &os = file ? *file : outs();
  emitLockTouchReport(os, sites);
  return PreservedAnalyses::all();
}

PreservedAnalyses LockTouchInstrumentPass::run(
    Module &module, ModuleAnalysisManager &manager) {
  (void)manager;

  std::vector<LockTouchSite> sites = collectLockTouchSites(module);
  bool changed = instrumentLockTouchSites(module, sites);
  return changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}

} // namespace arbiter::llvm
