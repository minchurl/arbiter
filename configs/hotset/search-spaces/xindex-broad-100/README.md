# XIndex Broad 100-Config Search Space

This directory preserves the exact 100 parameter inputs generated for the
2026 XIndex broad sweep. The same inputs were later rebuilt with the seed-only
compiler and evaluated on full-trace YCSB-B.

The files are search inputs, not 100 distinct validated policies. Static
selection collapses many of them to identical seed sets; some select no site,
some select dynamic-size sites that are unsafe for the fixed-slot arena, and
one failed to build in the retained YCSB-B run.

These configs predate removal of member expansion and therefore retain keys
such as `ARBITER_HOTSET_EXPANSION` and `ARBITER_HOTSET_MEMBER_*`. The current
build wrapper sources the files but emits only its explicit seed-only option
allowlist, so those legacy keys have no effect. They remain here to preserve
the exact search inputs.

Use `../../candidates/raw-046.config` for the recommended current policy. Run
`sha256sum -c configs.sha256` from this directory to verify the frozen inputs.
The
adaptive YCSB-B driver uses this directory only when intentionally replaying
the full parameter space.
