# Arbiter

Arbiter is a compiler-assisted object placement system for tiered memory environments.

It identifies allocation objects that may suffer from coherence and contention overhead, then places selected objects on an alternative memory node such as remote NUMA memory or CXL memory.

The first target is static, allocation-time placement. Arbiter does not move objects after the program starts running.

## Install / Setup

TBD.

Run:

```sh
./scripts/setup.sh
```

The setup flow will be filled in once the compiler/runtime skeleton is added.

## Docs

- [Overview](docs/overview.md)
