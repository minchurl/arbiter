#include "arbiter/LLVM/Passes.h"

#include "arbiter/LLVM/AllocationSite.h"

#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

#include <memory>

using namespace llvm;

namespace arbiter::llvm {
namespace {

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

void emitReport(raw_ostream &os, ArrayRef<AllocationSite> sites) {
  os << "site_id,kind,function,file,line,callee,size_expr\n";
  for (const AllocationSite &site : sites) {
    os << site.id << ',';
    csvValue(os, kindToString(site.kind));
    os << ',';
    csvValue(os, site.function);
    os << ',';
    csvValue(os, site.file);
    os << ',' << site.line << ',';
    csvValue(os, site.callee);
    os << ',';
    csvValue(os, site.sizeExpr);
    os << '\n';
  }
}

PreservedAnalyses emitSiteReport(Module &module) {
  std::vector<AllocationSite> sites = collectAllocationSites(module);
  std::error_code ec;
  std::unique_ptr<raw_fd_ostream> file = openFile(ArbiterReportPath, ec);
  if (ec) {
    errs() << "arbiter: failed to open report path " << ArbiterReportPath
           << ": " << ec.message() << "\n";
    return PreservedAnalyses::all();
  }

  raw_ostream &os = file ? *file : outs();
  emitReport(os, sites);
  return PreservedAnalyses::all();
}

} // namespace

PreservedAnalyses ReportAllocationSitesPass::run(Module &module,
                                                 ModuleAnalysisManager &) {
  return emitSiteReport(module);
}

} // namespace arbiter::llvm
