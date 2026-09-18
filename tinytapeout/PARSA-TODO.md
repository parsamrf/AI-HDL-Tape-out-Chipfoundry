# Remaining work to complete the MPW submission (Parsa)

Status per Jeff's 2026-09-16 reply: the tinytapeout/ layout matches his
flow; **tt-slm-gemm is off CI2609** (no custom-size tile exists); the
other five SLM tiles ride once their GDS is green; the three signed-off
macros (traffic, SPI, AES) are already on the dedicated chip. What's left
is GitHub plumbing, which needs your account:

## 1. Create the individual repos (one command)

From a machine with the `gh` CLI logged in:

```bash
git clone https://github.com/parsamrf/AI-HDL-Tape-out-Chipfoundry
cd AI-HDL-Tape-out-Chipfoundry/tinytapeout
./publish-repos.sh parsamrf          # or an org name
```

The script creates each repo from `chipfoundry/chipdiscover-verilog-template`,
overlays the project files, enables Actions, and pushes (the push starts the
`test` → `gds` → `docs`/`fpga` workflows). The default list already skips
tt-slm-gemm per Jeff. Re-running it is safe; you can also pass specific
projects: `./publish-repos.sh parsamrf tt-slm-cpu`.

## 2. Watch the Actions

Every project was already hardened locally with the exact CI recipe
(tt-support-tools + LibreLane 2.4.2, sky130A) before publication — see
`harden-results.md` in this directory for the per-project DRC/timing/
utilization table — so `gds` failures are not expected. If one still fails,
flag it rather than debugging; we'll supply an adjusted variant.

## 3. Send Jeff the URL list

When the repos show green `gds` (and ideally `docs`) Actions, send Jeff the
list of repo URLs. A draft confirmation reply is in the handoff notes.
