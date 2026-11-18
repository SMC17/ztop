# Contributing to ztop

This repo follows the [SMC17 standards](https://github.com/SMC17/SMC17/blob/main/STANDARDS.md).

## Build and test

```sh
zig build test --summary all
```

A change is ready when that passes from a fresh clone.

## Finding something to do

- Issues labelled [`status: ready`](https://github.com/SMC17/ztop/labels/status%3A%20ready) or [`good first issue`](https://github.com/SMC17/ztop/labels/good%20first%20issue) are scoped and waiting.
- [ROADMAP.md](ROADMAP.md) says what comes next.

## Pull requests

- One topic per PR; link the issue (`Closes #N`).
- Any performance or correctness number needs its command, commit, toolchain and machine.
- Disclose AI assistance in the PR description.
- See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) and [SECURITY.md](SECURITY.md).
