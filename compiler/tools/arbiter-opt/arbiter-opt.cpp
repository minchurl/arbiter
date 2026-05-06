#include "arbiter/Dialect/Arbiter/IR/ArbiterDialect.h"
#include "arbiter/Transforms/Passes.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/AsmState.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/Parser/Parser.h"
#include "mlir/Pass/PassManager.h"
#include "mlir/Support/FileUtilities.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/ToolOutputFile.h"

using namespace mlir;

static llvm::cl::opt<std::string> inputFilename(llvm::cl::Positional,
                                                llvm::cl::desc("<input mlir>"),
                                                llvm::cl::init("-"));

static llvm::cl::opt<std::string>
    outputFilename("o", llvm::cl::desc("Output filename"),
                   llvm::cl::value_desc("filename"), llvm::cl::init("-"));

static llvm::cl::opt<bool>
    selectAllocations("arbiter-select-allocations",
                      llvm::cl::desc("Select allocation sites for Arbiter "
                                     "placement"));

static llvm::cl::opt<bool> rewriteAllocations(
    "arbiter-rewrite-allocations",
    llvm::cl::desc("Rewrite selected memref.alloc/dealloc operations to "
                   "Arbiter dialect operations"));

static llvm::cl::opt<bool>
    lowerToRuntime("arbiter-lower-to-runtime",
                   llvm::cl::desc("Lower Arbiter dialect allocation operations "
                                  "to LLVM runtime calls"));

int main(int argc, char **argv) {
  llvm::InitLLVM y(argc, argv);
  llvm::cl::ParseCommandLineOptions(argc, argv, "Arbiter optimizer driver\n");

  DialectRegistry registry;
  registry.insert<arith::ArithDialect, func::FuncDialect, LLVM::LLVMDialect,
                  memref::MemRefDialect, scf::SCFDialect>();
  arbiter::registerArbiterDialect(registry);

  MLIRContext context(registry);
  context.allowUnregisteredDialects();
  context.loadAllAvailableDialects();

  ParserConfig parserConfig(&context);
  OwningOpRef<ModuleOp> module =
      parseSourceFile<ModuleOp>(inputFilename, parserConfig);
  if (!module)
    return 1;

  PassManager pm(&context);
  if (selectAllocations)
    pm.addPass(arbiter::createSelectAllocationsPass());
  if (rewriteAllocations) {
    pm.addPass(arbiter::createRewriteAllocationsPass());
    pm.addPass(arbiter::createRewriteDeallocationsPass());
  }
  if (lowerToRuntime)
    pm.addPass(arbiter::createLowerToRuntimePass());

  if (failed(pm.run(*module)))
    return 1;

  std::string errorMessage;
  auto output = openOutputFile(outputFilename, &errorMessage);
  if (!output) {
    llvm::errs() << errorMessage << "\n";
    return 1;
  }

  module->print(output->os());
  output->os() << "\n";
  output->keep();
  return 0;
}
