# Adaptive DMA / AXI Arbitration for a Zynq-7020-class FPGA-SoC: Results

Design: three accelerator traffic sources (FIR, matrix multiply, sparse matrix) -> per-channel request FIFOs
-> traffic monitor + arbiter (fixed priority / round robin / adaptive v1 / **adaptive v2**) -> AXI3 burst DMA.
Flow: Cadence Xcelium, HAL, Jasper, IMC, Genus, Conformal, Innovus, Tempus; gsclib045 (45 nm).

## 1. Performance (end-to-end, AXI3 DMA + DRAM-like memory model, 5000 cycles)
| Scenario | Metric | Fixed | RR | Adaptive v1 | **Adaptive v2** |
|---|---|---|---|---|---|
| HEAVY | Throughput (beats/cycle) | 0.830* | 0.442 | 0.489 | **0.566** |
| HEAVY | Avg / max latency (cycles) | 32 / starved | 117 / 186 | 103 / 183 | **87 / 145** |
| BALANCED | Throughput | 0.463* | 0.502 | 0.486 | **0.553** |
| SLOW_DRAM | Throughput | 0.377* | 0.295 | 0.245 | **0.350** |
| HEAVY | DRAM row-hit rate | 100%* | 15% | 19% | **32%** |
| LOW (under capacity) | p99 latency | 32 | 46 | 33 | **30** |
\* fixed priority starves the lower-priority channels (max latency = whole run).

- Adaptive v2 (missed-grant starvation override + 4-grant burst hold): **+10-28% throughput vs round robin under contention**,
  lowest latency, via higher DRAM row locality. Burst gathering in the DMA adds another 16-20%.
- Known limitation: fairness is per *grant*, not per *byte* (Jain 0.71-0.87 with bursting; 0.99+ without). Future work: beat-based (deficit) accounting.
- Full tables: `results3.md`, `results3_nobursts.md` (step 3), `results.md` (step 2, ideal memory port).

## 2. Verification
| Item | Result |
|---|---|
| Regression | 37 runs, all PASS (Xcelium): scoreboard, AXI3 protocol checker (8 rules), drain check, starvation bound |
| Stimulus | 5 load scenarios x 4 arbiters, random AXI backpressure, contiguous-access scenario, error injection (SLVERR, bad RID, bad BID), single-channel runs |
| Functional coverage | **42 / 42 bins** |
| Code coverage (IMC, 37 runs merged) | FSM **100%**; block/expression 100% of reachable code (documented exclusions, `cov/EXCLUSIONS.md`) |
| Lint | Verilator `-Wall` clean; **Cadence HAL: 0 unexplained findings** (waivers justified, `lint/WAIVERS.md`) |
| Formal (Jasper Superlint) | 0 overflows; 3 dead-code **proofs**: v2 missed-grant count never exceeds 15 (starvation bound), last-granted channel never overdue, score never saturates with current weights |
| Bugs found by the process | coverage found 4 untested paths (write gathering, gathering on 2 channels, AXI wait states, error logic) and 1 testbench bug (AXI checker register width); lint found unchecked AXI responses (fixed: `err_status`); Superlint flagged a latent score overflow (fixed: saturation) |

## 3. Synthesis (Genus, slow corner) and equivalence (Conformal)
At 3.0 ns (333 MHz), all four arbiters meet timing:
| Arbiter | Area (um2) | Power (mW) | vs round robin |
|---|---|---|---|
| Fixed | 58,246 | 17.45 | |
| Round robin | 59,066 | 17.28 | baseline |
| Adaptive v1 | 64,612 | 19.79 | +9.4% area, +14.5% power |
| Adaptive v2 | 64,657 | 19.94 | **+9.5% area, +15.4% power** |
(Adaptive v2 after the DMA timing fix: 63,192 um2, 19.80 mW.) Arbiter alone: 85 um2 (RR) vs ~4,800-5,400 um2 (adaptive); the traffic monitor is also only needed by the adaptive arbiters.

- **Conformal LEC: PASS**, ~4,150-4,260 compared points per configuration, 0 non-equivalent, 0 aborted.
- **Critical path** (2.5 ns analysis): FIFO head 16:1 mux (0.67 ns) -> burst-gather address check + AR issue/accept (0.97 ns)
  -> arbiter (**0.05 ns**) -> request mux into burst buffer (0.59 ns). The arbiter is not the limiter; the DMA's same-cycle
  accept chain is. Registering the next expected address recovered ~0.1 ns; a registered-head FIFO is the next step for 400 MHz.

## 4. Physical design (Innovus) and sign-off (Tempus): adaptive v2 @ 3.0 ns
| Item | Result |
|---|---|
| Setup (Innovus post-route) | WNS **+0.007 ns**, 0 violating paths (reg->reg +0.078 ns) |
| Hold (Innovus post-route) | WNS **+0.021 ns**, 0 violating paths |
| **Tempus sign-off** (setup @ slow, hold @ fast, OCV + CPPR, SPEF, post-CTS SDC) | setup **+0.016 ns**, reg->reg **+0.094 ns**, hold **+0.298 ns**; **no max-transition/capacitance/fanout violations** |
| DRC / connectivity | **0 violations / clean** |
| Clock tree (CCOpt) | skew **24 ps** (target 50), insertion 239-263 ps |
| Utilization | 57.3% (99.3% with fillers); 9 routing layers, power ring + stripes on Metal9/Metal8 |
| Wire length / cells | ~216 mm; ~27k instances incl. fillers |
| Post-route power | ~17.3 mW (79.6% internal, 20.4% switching, ~1.6 uW leakage) |

Sign-off lessons recorded along the way: use the LEF with fixed via definitions (`LIBS/lef/gsclib045.fixed.lef`);
time post-route with separate setup/hold views (not one view with -max/-min libraries) and with the post-CTS SDC
(propagated clocks, CCOpt I/O latency updates); debug outputs get a false path.

## 5. Future work
- Registered-head FIFOs to break the same-cycle accept chain (target 400 MHz).
- Beat-based (byte-fair) arbitration.
- AXI-Lite register block: runtime arbiter mode, weights, thresholds, performance counters.
- Activity-based power (simulation TCF/VCD into Joules/Voltus) and IR-drop analysis.
- FPGA implementation on the Zynq-7020 (requires Vivado; the RTL uses synchronous resets and inferred memories, and the DMA is AXI3 for the HP ports).
