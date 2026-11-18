# Automatic selection across B-tree, coherence_noise and XIndex

The candidate `published-rmw-size-tiebreaker.config` extends the
evidence-balanced policy with three points for an allocation published
through a global pointer whose pointee is used by atomic RMW or compare-and-swap.
The score threshold stays at 5 and explicit site IDs stay empty.
[Configuration](../../configs/hitm-seed/policy-candidates/published-rmw-size-tiebreaker.config)

## Selection

| Workload | Candidate decision | Evidence |
|---|---|---|
| coherence_noise | Select the entry table, site 4 | Score 5, including pointee CAS |
| coherence_noise | Keep ballast local, site 5 | Score 2, read-only use after initialization |
| B-tree | Select zero allocations | The pass cannot rewrite its `posix_memalign` calls |
| XIndex/YCSB-A | Select 68, 71, 74, 90, 97, 98, 99, 100 | Identical selection to evidence-balanced |

The original weights gave the table and ballast the same signals. Changing
those weights could not distinguish them. The added compiler signal follows
pointer loads from a directly published global through GEP, casts, PHI and
select to the address operand of RMW/CAS. It treats a load through the
allocated object as a separate pointee. Its weight defaults to zero.
The analysis is a static sharing heuristic. It does not measure access
frequency or prove that the RMW executes on multiple threads.
[All allocation decisions](../../results/allocation-policy/published-rmw-20261118/decisions.csv)

The candidate produces byte-identical rewritten XIndex bitcode and executable
to the evidence-balanced control. The executable SHA-256 is
`e94972432898885a4904acd571ea5bbe7fef478773e14a4705576d75695dffc7`.
The automatic microbenchmark rewrite equals the earlier explicit table-only
rewrite. B-tree's native and automatic builds have identical object code.
[Input and binary hashes](../../results/allocation-policy/published-rmw-20261118/inputs.sha256)

## Exploratory placement measurements

All measurements used the Xeon Gold 6548Y+ host with CPUs 0–31, local DRAM
on node 0 and CXL on node 2, Clang 18.1.8 and the Release jemalloc runtime.
Each process ran in a 64 GiB systemd scope with swap disabled.

The screen used two local/CXL pairs per setting, 15 seconds per process,
32 victims, zero noise, 50% reads and 8 GiB ballast. The second pair reversed
the placement order. All live page probes and allocator reports matched the
requested placement with zero fallbacks and query errors. The supplied
table size is 256. The larger-table rows explore additional working sets.

| Selected allocation | Entries | Local Mops/s | CXL Mops/s | Change |
|---|---:|---:|---:|---:|
| Table | 256 | 347.14 | 351.13 | +1.15% |
| Table | 1,000,000 | 725.85 | 534.29 | −26.39% |
| Table | 4,000,000 | 657.72 | 92.07 | −86.00% |
| Table | 16,000,000 | 595.65 | 63.39 | −89.36% |
| Ballast | 256 | 350.77 | 46.45 | −86.76% |
| Table and ballast | 256 | 351.16 | 46.57 | −86.74% |

The small-table screen includes a slower first local run at 343.10 Mops/s.
The reversed pair measured 351.18 local and 351.06 CXL. The longer confirmation
below uses the supplied 120-second duration.
[All screen rows](../../results/allocation-policy/published-rmw-20261118/screen.csv)

The arena's default 2 MiB chunk setting accepts allocations up to 1 MiB.
For this screen, the chunk was raised to 1 GiB for table-only tests and
16 GiB for ballast tests, with a 32 GiB virtual reserve. This admitted the
larger individual requests. An initial larger-table run with the default
cap failed and was rerun with the adjusted setting. The supplied-size
confirmation uses the standard 2 MiB chunks and 24 GiB reserve.

## Supplied-workload confirmation

The automatic build ran B-tree once per mode and the microbenchmark twice per
mode at the supplied 120-second duration. The table-only policy averaged
351.37 Mops/s local and 351.44 Mops/s CXL, a +0.02% difference. Native averaged
351.18 Mops/s. This result establishes no meaningful throughput gain for the
supplied microbenchmark.

B-tree selected zero objects. Native and both policy modes kept all sampled
pages on local DRAM and measured 23.02, 22.88 and 22.72 million lookups/s.
Every process completed all 600M lookups and validated 4,096 stored payload
addresses. The supplied parallel RNG and accumulator still share mutable
state, so the exact lookup sequence can vary. Automatic selection avoids
the large slowdown seen when the earlier targeted experiment moved the
node arrays to CXL. The compiler's unsupported `posix_memalign` interface
limits the B-tree selection experiment.
[Confirmation rows and page samples](../../results/allocation-policy/published-rmw-20261118/benchmark-runs.csv)

## XIndex/YCSB-A preservation

Four local/CXL pairs per policy each loaded 100M records and executed all
400M YCSB-A operations using 31 foreground workers and one background
worker. The policy order was control, candidate, candidate, control,
candidate, control, control, candidate. Two of the pairs reversed placement
order. Both configurations used the strict 24 GiB arena and 2 MiB chunks.

| Policy | Local Mops/s | CXL Mops/s | CXL vs local |
|---|---:|---:|---:|
| Evidence-balanced control | 27.50 | 46.34 | +68.50% |
| Published-RMW candidate | 26.69 | 46.30 | +73.46% |

Candidate CXL throughput differed from control by −0.08%. Local throughput
differed by −2.94%. The bitcode and executable hashes match exactly across
policies. The sampled differences therefore reflect run conditions and
variation. CXL individual runs ranged from 42.44 to 48.26 Mops/s for control
and 42.88 to 49.43 Mops/s for the candidate.

All 16 runs validated 4,096 keys with digest `0x7474b8e9d3962859`.
Every run reported 52,791,182 selected allocations, zero fallbacks, zero page
query errors and zero swaps. Every resident arena page was on the requested
node. The runtime allocated the same objects at sites 68, 71 and 74.
[Full-trace measurements](../../results/allocation-policy/published-rmw-20261118/xindex-runs.csv)

## Reproduction

Use the [automatic benchmark build and run commands](../../README.md#run-b-tree-and-the-coherence-microbenchmark).
The generated `selected-objects.json` connects policy decisions to the runner's
live page checks. The original manual-placement build is archived at
[commit a2151db](https://github.com/minchurl/arbiter/tree/a2151db).

To compare YCSB-A with this candidate after rebuilding the LLVM plugin, use
the existing full-trace runner with validation enabled.

```sh
ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/policy-candidates/published-rmw-size-tiebreaker.config \
  XINDEX_VALIDATE=1 REPEATS=2 ./scripts/run-xindex-hitm-seed-replay.sh
```

The compiler regression checks cover table selection, read-only ballast,
nested pointees and a pointer used as the value of an atomic exchange.
All 16 existing and added LLVM checks passed. The updated result parser also
accepted all 18 historical targeted benchmark rows. Both the automatic
default build and explicit targeted build passed three-mode CLI smoke runs.
