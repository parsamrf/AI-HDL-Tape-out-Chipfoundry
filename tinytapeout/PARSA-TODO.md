# Remaining work to complete the MPW submission (Parsa)

Everything design-side is done: all 16 projects in this directory are
complete chipdiscover-verilog-template projects with passing local cocotb
tests. What's left is GitHub plumbing, which needs your account:

## 1. Create the 16 individual repos (one command)

Jeff's integration flow requires each design as its own public repo created
from the template, with GitHub Actions enabled. From a machine with the
`gh` CLI logged in:

```bash
git clone https://github.com/parsamrf/AI-HDL-Tape-out-Chipfoundry
cd AI-HDL-Tape-out-Chipfoundry/tinytapeout
./publish-repos.sh parsamrf          # or an org name
```

The script creates each repo from `chipfoundry/chipdiscover-verilog-template`,
overlays the project files, enables Actions, and pushes (the push starts the
`test` → `gds` → `docs`/`fpga` workflows). Re-running it is safe; you can
also pass specific projects: `./publish-repos.sh parsamrf tt-slm-gemm`.

## 2. Watch the Actions

- `test` should be green everywhere on the first run (the same cocotb suites
  pass locally).
- `gds` is the real gate (hardening + precheck). Expect it to take a while
  per repo.

## 3. Collect and send the URL list to Jeff

Once every repo shows green Actions, send Jeff the list of the 16 repo URLs
(the reply email that references this staging area has already gone out).

## Area pre-check (already done)

Every SLM tile was synthesized locally to sky130 HD and its area checked
against its claimed tile size (cpu 42%, kv 41%, dma 41%, softmax 52%,
rmsnorm 56% raw utilization); RMSNorm and GEMM carry documented
scratch-buffer depth reductions, and their cocotb suites were re-run
bit-exact afterwards. If a `gds` Action still fails on one of these, don't
debug it — flag it and we'll supply an adjusted variant.

**Exception — tt-slm-gemm:** its 64-PE systolic array is ~0.44 mm², ~1.5x
the largest tile, independent of buffers. Publish the repo (its `test`
Action passes) but expect `gds` to fail; whether it gets a custom slot is
a question already posed to Jeff. Don't hold the other 15 on it.
