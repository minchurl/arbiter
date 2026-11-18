#include "ObjectAccessAnalysis.h"
#include "arbiter/LLVM/AllocationSite.h"

#include "llvm/ADT/MapVector.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/KnownBits.h"
#include "llvm/Support/raw_ostream.h"

#include <map>
#include <numeric>
#include <tuple>
#include <vector>

using namespace llvm;
namespace arbiter::llvm::hitm_seed {
namespace {

// offset + k * stride (stride == 0 denotes an exact offset). Joins widen
// induction variables without collapsing distinct fields to an entire object.
struct Offset {
  uint64_t value = 0, stride = 0;
  bool join(Offset other) {
    uint64_t next = std::gcd(std::gcd(stride, other.stride),
                             value > other.value ? value - other.value
                                                 : other.value - value);
    uint64_t residue = next ? value % next : value;
    bool changed = next != stride || residue != value;
    value = residue;
    stride = next;
    return changed;
  }
  Offset add(Offset other) const {
    uint64_t s = std::gcd(stride, other.stride);
    uint64_t v = value + other.value;
    return {s ? v % s : v, s};
  }
  bool overlaps(Offset other) const {
    uint64_t s = std::gcd(stride, other.stride);
    return s ? value % s == other.value % s : value == other.value;
  }
};

using Key = std::pair<const Value *, unsigned>;
using Offsets = SmallVector<Offset, 4>;
using Points = std::map<unsigned, Offsets>;
bool covers(Offset a, Offset b) {
  return a.stride ? b.stride % a.stride == 0 &&
                        a.value % a.stride == b.value % a.stride
                  : !b.stride && a.value == b.value;
}
bool mergeOffsets(Offsets &into, Offset from) {
  for (Offset offset : into)
    if (covers(offset, from))
      return false;
  for (auto it = into.begin(); it != into.end();)
    if (covers(from, *it))
      it = into.erase(it);
    else
      ++it;
  into.push_back(from);
  // Keep finite alternatives (e.g. two fields selected by a PHI) separate.
  // Widen long induction chains only, rather than conflating every pair of
  // fields.
  if (into.size() > 8) {
    Offset widened = into.front();
    for (Offset offset : into)
      widened.join(offset);
    into.assign(1, widened);
  }
  return true;
}
bool merge(Points &into, const Points &from) {
  bool changed = false;
  for (const auto &[object, offsets] : from)
    for (Offset offset : offsets)
      changed |= mergeOffsets(into[object], offset);
  return changed;
}
SmallVector<std::pair<unsigned, Offset>, 8> facts(const Points &points) {
  SmallVector<std::pair<unsigned, Offset>, 8> result;
  for (const auto &[object, offsets] : points)
    for (Offset offset : offsets)
      result.push_back({object, offset});
  return result;
}
Points shifted(const Points &points, Offset offset) {
  Points result;
  for (auto [object, at] : facts(points))
    mergeOffsets(result[object], at.add(offset));
  return result;
}

struct Cell {
  Points addresses, contents;
};
struct Context {
  const Function *function;
};

class Analysis {
  Module &module;
  const DataLayout &layout;
  std::map<Key, Points> values;
  DenseMap<const GEPOperator *, Offset> gepOffsets;
  std::map<Key, unsigned> objectIds;
  std::vector<Key> objects;
  std::map<std::tuple<const Value *, unsigned, uint64_t>, Cell> memory;
  std::map<unsigned, SmallVector<Cell *, 4>> memoryByObject;
  std::map<std::pair<const Function *, const CallBase *>, unsigned> contextIds;
  std::vector<Context> contexts;
  std::map<unsigned, Points> returns;
  ObjectAccessInfo result;
  bool changed = false;
  // Implementation resource limits, not scoring/policy parameters. On
  // exhaustion discard the partial result: iteration order must never determine
  // selection.
  static constexpr unsigned maxContexts = 2048;
  static constexpr unsigned maxRounds = 128;

  unsigned context(const Function *function, const CallBase *caller) {
    auto key = std::make_pair(function, caller);
    auto found = contextIds.find(key);
    if (found != contextIds.end())
      return found->second;
    unsigned id = contexts.size();
    contexts.push_back({function});
    contextIds[key] = id;
    changed = true;
    return id;
  }
  Points root(const Value *value, unsigned ctx) {
    Key key{value, ctx};
    auto [it, inserted] = objectIds.emplace(key, objects.size());
    if (inserted)
      objects.push_back(key);
    return {{it->second, {Offset{}}}};
  }
  Offset integerOffset(const Value *value, unsigned depth = 0) {
    if (const auto *constant = dyn_cast<ConstantInt>(value))
      return {constant->getValue().getLimitedValue(), 0};
    if (depth < 12) {
      if (const auto *op = dyn_cast<BinaryOperator>(value)) {
        Offset a = integerOffset(op->getOperand(0), depth + 1);
        Offset b = integerOffset(op->getOperand(1), depth + 1);
        switch (op->getOpcode()) {
        case Instruction::Add:
          return a.add(b);
        case Instruction::Sub:
          return a.add({0 - b.value, b.stride});
        case Instruction::Mul:
          if (!b.stride)
            return {a.value * b.value, a.stride * b.value};
          if (!a.stride)
            return {b.value * a.value, b.stride * a.value};
          break;
        case Instruction::Shl:
          if (!b.stride && b.value < 64)
            return {a.value << b.value, a.stride << b.value};
          break;
        default:
          break;
        }
      }
    }
    unsigned zeros = computeKnownBits(value, layout).countMinTrailingZeros();
    return {0, zeros < 64 ? uint64_t{1} << zeros : 0};
  }
  Offset gepOffset(const GEPOperator &gep) {
    auto cached = gepOffsets.find(&gep);
    if (cached != gepOffsets.end())
      return cached->second;
    Offset offset = computeGEPOffset(gep);
    gepOffsets[&gep] = offset;
    return offset;
  }
  Offset computeGEPOffset(const GEPOperator &gep) {
    unsigned bits = layout.getIndexTypeSizeInBits(gep.getType());
    MapVector<Value *, APInt> variables;
    APInt constant(bits, 0);
    if (bits > 64 || !gep.collectOffset(layout, bits, variables, constant))
      return {0, 1};
    Offset result{constant.getZExtValue(), 0};
    for (const auto &variable : variables) {
      Offset index = integerOffset(variable.first);
      uint64_t scale = variable.second.getZExtValue();
      result =
          result.add({index.value * scale,
                      index.stride * variable.second.abs().getZExtValue()});
    }
    return result;
  }
  Points get(const Value *value, unsigned ctx) {
    if (!value->getType()->isPointerTy() &&
        !value->getType()->isIntegerTy(layout.getPointerSizeInBits()))
      return {};
    if (isa<GlobalValue>(value))
      return root(value, 0);
    if (const auto *expr = dyn_cast<ConstantExpr>(value)) {
      if (const auto *gep = dyn_cast<GEPOperator>(expr))
        return shifted(get(gep->getPointerOperand(), ctx), gepOffset(*gep));
      if (expr->isCast())
        return get(expr->getOperand(0), ctx);
    }
    return values[{value, ctx}];
  }
  void put(const Value *value, unsigned ctx, const Points &points) {
    changed |= merge(values[{value, ctx}], points);
  }
  void store(const Value *origin, unsigned ctx, uint64_t slot,
             const Points &addresses, const Points &contents) {
    if (addresses.empty() || contents.empty())
      return;
    Cell &cell = memory[{origin, ctx, slot}];
    changed |= merge(cell.addresses, addresses);
    changed |= merge(cell.contents, contents);
    for (const auto &address : addresses) {
      auto &cells = memoryByObject[address.first];
      if (::llvm::find(cells, &cell) == cells.end())
        cells.push_back(&cell);
    }
  }
  Points load(const Points &addresses) const {
    Points result;
    for (auto [object, offset] : facts(addresses)) {
      if (offset.stride && offset.stride < layout.getPointerSize())
        continue;
      auto cells = memoryByObject.find(object);
      if (cells == memoryByObject.end())
        continue;
      for (const Cell *cell : cells->second)
        for (Offset at : cell->addresses.at(object))
          if ((!at.stride || at.stride >= layout.getPointerSize()) &&
              offset.overlaps(at)) {
            merge(result, cell->contents);
            break;
          }
    }
    return result;
  }
  void initializer(const GlobalVariable &global, const Constant *constant,
                   uint64_t offset) {
    if (constant->getType()->isPointerTy()) {
      store(&global, 0, offset, shifted(root(&global, 0), {offset, 0}),
            get(constant, 0));
    } else if (const auto *structure = dyn_cast<ConstantStruct>(constant)) {
      const auto *sl = layout.getStructLayout(structure->getType());
      for (unsigned i = 0; i < structure->getNumOperands(); ++i)
        initializer(global, structure->getOperand(i),
                    offset + sl->getElementOffset(i));
    } else if (const auto *array = dyn_cast<ConstantArray>(constant)) {
      uint64_t size =
          layout.getTypeAllocSize(array->getType()->getElementType());
      for (unsigned i = 0; i < array->getNumOperands(); ++i)
        initializer(global, array->getOperand(i), offset + i * size);
    }
  }
  void edge(const Function *from, const Function *to) {
    auto &callees = result.calls[from];
    if (::llvm::find(callees, to) == callees.end())
      callees.push_back(to);
  }
  void enter(const CallBase &call, unsigned ctx, const Function *callee,
             ArrayRef<Points> arguments, bool worker = false) {
    if (callee->isDeclaration() || callee->arg_size() != arguments.size())
      return;
    unsigned target = context(callee, &call);
    unsigned i = 0;
    for (const Argument &argument : callee->args())
      if (argument.getType()->isPointerTy())
        put(&argument, target, arguments[i++]);
      else
        ++i;
    if (worker)
      result.threadEntries.insert(callee);
    else {
      edge(call.getFunction(), callee);
      if (call.getType()->isPointerTy())
        put(&call, ctx, returns[target]);
    }
  }
  void call(const CallBase &call, unsigned ctx) {
    const auto *direct =
        dyn_cast<Function>(call.getCalledOperand()->stripPointerCasts());
    StringRef name = direct ? direct->getName() : StringRef();
    uint64_t word = layout.getPointerSize();
    if (name == "pthread_create" && call.arg_size() >= 4) {
      for (auto [id, offset] : facts(get(call.getArgOperand(2), ctx)))
        if (const auto *fn = dyn_cast<Function>(objects[id].first))
          enter(call, ctx, fn, {get(call.getArgOperand(3), ctx)}, true);
      return;
    }
    // libstdc++'s ABI passes unique_ptr<_State> by address. The vptr points
    // after offset-to-top/typeinfo; its third virtual function is _M_run.
    if (name == "_ZNSt6thread15_M_start_threadESt10unique_ptrINS_6_"
                "StateESt14default_deleteIS1_EEPFvvE" &&
        call.arg_size() == 3) {
      Points state = load(get(call.getArgOperand(1), ctx));
      Points run = load(shifted(load(state), {2 * word, 0}));
      for (auto [id, offset] : facts(run)) {
        const auto *fn = dyn_cast<Function>(objects[id].first);
        if (fn && fn->getName().starts_with("_ZNSt6thread11_State_impl") &&
            fn->getName().ends_with("6_M_runEv"))
          enter(call, ctx, fn, {state}, true);
      }
      return;
    }
    // libstdc++ list insertion is out of line. Model its four pointer stores,
    // not a particular container/type/allocation from a benchmark.
    if (name == "_ZNSt8__detail15_List_node_base7_M_hookEPS0_" &&
        call.arg_size() == 2) {
      Points node = get(call.getArgOperand(0), ctx);
      Points position = get(call.getArgOperand(1), ctx);
      Points previous = load(shifted(position, {word, 0}));
      store(&call, ctx, 0, node, position);
      store(&call, ctx, 1, shifted(node, {word, 0}), previous);
      store(&call, ctx, 2, previous, node);
      store(&call, ctx, 3, shifted(position, {word, 0}), node);
      return;
    }
    if (direct && direct->isDeclaration()) {
      // An opaque pointer result is an unknown origin, not an empty alias set
      // that could disappear when joined with a known allocation.
      if (call.getType()->isPointerTy())
        put(&call, ctx, root(&call, ctx));
      return;
    }
    SmallVector<Points, 8> arguments;
    for (const Use &argument : call.args())
      arguments.push_back(get(argument, ctx));
    for (auto [id, offset] : facts(get(call.getCalledOperand(), ctx)))
      if (const auto *fn = dyn_cast<Function>(objects[id].first))
        enter(call, ctx, fn, arguments);
  }
  void copyMemory(const Value *origin, unsigned ctx, const Points &destination,
                  const Points &source, uint64_t bytes) {
    // Snapshot: stores below may add cells. Only fully copied pointer slots
    // count; unknown lengths and partial pointer copies give no evidence.
    std::vector<std::pair<Offset, Points>> copies;
    for (auto [object, from] : facts(source)) {
      if (from.stride)
        continue;
      auto cells = memoryByObject.find(object);
      if (cells == memoryByObject.end())
        continue;
      for (const Cell *cell : cells->second)
        for (Offset at : cell->addresses.at(object)) {
          uint64_t delta = at.value - from.value;
          if (!at.stride && delta <= bytes &&
              layout.getPointerSize() <= bytes - delta)
            copies.push_back({{delta, 0}, cell->contents});
        }
    }
    for (const auto &copy : copies)
      store(origin, ctx, copy.first.value, shifted(destination, copy.first),
            copy.second);
  }
  void transfer(const Instruction &instruction, unsigned ctx) {
    if (const auto *alloca = dyn_cast<AllocaInst>(&instruction)) {
      put(alloca, ctx, root(alloca, ctx));
    } else if (const auto *gep = dyn_cast<GetElementPtrInst>(&instruction)) {
      put(gep, ctx,
          shifted(get(gep->getPointerOperand(), ctx),
                  gepOffset(*cast<GEPOperator>(gep))));
    } else if (const auto *phi = dyn_cast<PHINode>(&instruction)) {
      if (phi->getType()->isPointerTy())
        for (Value *incoming : phi->incoming_values())
          put(phi, ctx, get(incoming, ctx));
    } else if (const auto *select = dyn_cast<SelectInst>(&instruction)) {
      if (select->getType()->isPointerTy()) {
        put(select, ctx, get(select->getTrueValue(), ctx));
        put(select, ctx, get(select->getFalseValue(), ctx));
      }
    } else if (isa<BitCastInst, AddrSpaceCastInst, FreezeInst, PtrToIntInst,
                   IntToPtrInst>(&instruction)) {
      if (instruction.getType()->isPointerTy() ||
          instruction.getType()->isIntegerTy(layout.getPointerSizeInBits()))
        put(&instruction, ctx, get(instruction.getOperand(0), ctx));
    } else if (const auto *read = dyn_cast<LoadInst>(&instruction)) {
      if (read->getType()->isPointerTy() ||
          read->getType()->isIntegerTy(layout.getPointerSizeInBits()))
        put(read, ctx, load(get(read->getPointerOperand(), ctx)));
    } else if (const auto *write = dyn_cast<StoreInst>(&instruction)) {
      if (auto *vector =
              dyn_cast<FixedVectorType>(write->getValueOperand()->getType())) {
        if (vector->getElementType()->isPointerTy())
          if (const auto *read = dyn_cast<LoadInst>(write->getValueOperand()))
            copyMemory(write, ctx, get(write->getPointerOperand(), ctx),
                       get(read->getPointerOperand(), ctx),
                       layout.getTypeStoreSize(vector));
      } else
        store(write, ctx, 0, get(write->getPointerOperand(), ctx),
              get(write->getValueOperand(), ctx));
    } else if (const auto *ret = dyn_cast<ReturnInst>(&instruction)) {
      if (ret->getReturnValue())
        changed |= merge(returns[ctx], get(ret->getReturnValue(), ctx));
    } else if (const auto *copy = dyn_cast<MemTransferInst>(&instruction)) {
      if (const auto *size = dyn_cast<ConstantInt>(copy->getLength()))
        copyMemory(copy, ctx, get(copy->getDest(), ctx),
                   get(copy->getSource(), ctx), size->getZExtValue());
    } else if (const auto *cb = dyn_cast<CallBase>(&instruction)) {
      if (isHeapAllocation(classifyCall(*cb)))
        put(cb, ctx, root(cb, ctx));
      else
        call(*cb, ctx);
    }
  }

public:
  explicit Analysis(Module &module)
      : module(module), layout(module.getDataLayout()) {}
  ObjectAccessInfo run() {
    for (const GlobalVariable &global : module.globals())
      if (global.hasInitializer())
        initializer(global, global.getInitializer(), 0);
    for (const Function &function : module)
      if (!function.isDeclaration()) {
        unsigned ctx = context(&function, nullptr);
        for (const Argument &argument : function.args())
          if (argument.getType()->isPointerTy())
            put(&argument, ctx, root(&argument, ctx));
      }
    bool converged = false;
    for (unsigned round = 0; round < maxRounds; ++round) {
      changed = false;
      for (unsigned ctx = 0;
           ctx < contexts.size() && contexts.size() <= maxContexts; ++ctx)
        for (const Instruction &instruction :
             instructions(contexts[ctx].function))
          transfer(instruction, ctx);
      if (contexts.size() > maxContexts)
        break;
      if (!changed) {
        converged = true;
        break;
      }
    }
    if (!converged) {
      errs() << "arbiter: object-access analysis budget exhausted; discarding "
                "partial evidence\n";
      return ObjectAccessInfo();
    }
    for (unsigned ctx = 0; ctx < contexts.size(); ++ctx)
      for (const Instruction &instruction :
           instructions(contexts[ctx].function)) {
        const Value *address = nullptr;
        if (const auto *rmw = dyn_cast<AtomicRMWInst>(&instruction))
          address = rmw->getPointerOperand();
        else if (const auto *cas = dyn_cast<AtomicCmpXchgInst>(&instruction))
          address = cas->getPointerOperand();
        if (!address)
          continue;
        SmallPtrSet<const CallBase *, 4> candidates;
        bool unknown = false;
        for (auto [id, offset] : facts(get(address, ctx))) {
          const auto *allocation = dyn_cast<CallBase>(objects[id].first);
          if (allocation && isHeapAllocation(classifyCall(*allocation)))
            candidates.insert(allocation);
          else
            unknown = true;
        }
        // Alias unions are useful for finding paths, but are insufficient to
        // award object-specific evidence when multiple allocations remain.
        if (!unknown && candidates.size() == 1)
          result.rmwAllocations.insert(*candidates.begin());
      }
    return std::move(result);
  }
};
} // namespace
ObjectAccessInfo analyzeObjectAccesses(Module &module) {
  return Analysis(module).run();
}
} // namespace arbiter::llvm::hitm_seed
