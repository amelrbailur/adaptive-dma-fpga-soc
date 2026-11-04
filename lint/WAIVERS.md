# Lint waivers (reviewed)

These are the only warnings expected after the lint clean-up. Each is
intentional; anything else in a lint report is new and should be looked at.

| Where | Warning | Why it is waived |
|---|---|---|
| `fixed_priority_arbiter`, `rr_arbiter` | Unused inputs (`fifo_count*`, `almost_full*`, `arrival_rate*`, `burst_len*`) | All four arbiters share one port list so they are drop-in swappable; the baselines ignore traffic metrics by design. |
| `adaptive_dma_top` | Unconnected outputs on `request_fifo.dout`, arbiter `score*` / `waiting*` | Registered `dout` is not needed (the DMA uses the fall-through `head`); scores and wait counters are debug/observability outputs. Synthesis removes the unused logic. |
| `axi3_dma_master` | Unconnected tracker FIFO `dout`, `full`, `almost_full` | Trackers are read through `head`; space is guaranteed by `accept_ready` (checks `count` against `MAX_OUT`). |
| `adaptive_arbiter` | Truncation in `calc_score` sum | Width checked at elaboration: max score 15*(sum of weights) + AF_BONUS must fit in SCORE_W (error otherwise). |
| `tg_fir`, `tg_matmul`, `tg_sparse` | Width expansion of index counters into 32-bit address arithmetic | Stimulus models, not in the synthesis top. |
| Parameter-dependent generate branches | Only one arbiter is elaborated per configuration | Lint each `ARB_TYPE` (the HAL script loops over all four). |

## Real issues found and fixed in the lint pass
1. `axi3_dma_master` ignored `RID`/`BID`, `RRESP`/`BRESP` and `RDATA`:
   - added `err_status` (sticky): bit 0 = SLVERR/DECERR response, bit 1 = ID mismatch or unexpected response;
   - added the read-data return stream `rd_data_valid / rd_data_ch / rd_data / rd_data_last`;
   - testbench now fails a run if `err_status` is ever set.
2. `rr_arbiter`: loop index assigned only when `mem_ready` was high, a latch risk in `always @*`; now assigned on every path.
3. `adaptive_arbiter`: score functions were evaluated inside the clocked block (blocking assignments in sequential logic); moved to combinational wires, then registered.
4. `% 3` rotation arithmetic on 32-bit integers replaced by a 2-bit `next_ch` function (smaller, lint-clean).
5. Explicit `AxLEN = len - 1` encoding, sized parameter comparisons, sized beat indexing.

Regression after the fixes: step 2 and step 3 sweeps (with and without bursts) give results identical to before.

## Second pass: Cadence HAL and Jasper Superlint (lab run, 2 Nov)

### Jasper Superlint (AUTO_FORMAL domain): 6 findings
| Finding | Verdict | Action |
|---|---|---|
| Overflow: `len_m1 = len - 1` (DMA) | Reachable only while idle (`len = 0`), value unused then | Guarded: `len_m1 = 0` when `len = 0` |
| Overflow: `last + 4` (DMA, 33-bit carry) | Harmless (4 KB check blocks the wrap), but inexact | Compare at ADDR_W+1 bits (`next_addr`) |
| Overflow: `calc_score` 8-bit sum | Cannot overflow with current weights (max 180), **would** once weights are programmable (step 4) | Sum computed SCORE_W+7 bits wide, then saturated at 255 |
| Overflow: `window + 1` (monitor) | Intended 16-cycle wrap | Wrap written explicitly |
| Dead code: `overdue = 1` in the arbiter's last loop iteration | **Formally proven unreachable**: that iteration checks the most recently granted channel, whose missed-grant count was just reset | Keep (generic loop); evidence the override logic is sound |
| Dead code: wait-term saturation in `norm_wait` (v2) | **Formally proven unreachable**: in v2 the missed-grant count never exceeds 15, i.e. the starvation bound holds formally, not just in simulation | Keep as defensive logic (reachable in v1) |

### HAL: fixed
| Rule | What | Fix |
|---|---|---|
| POOBID (9) | 2-bit channel index into 3-entry vectors (`empty[ch]`, `head_*[ch]`, `empty_v[last_grant]`) | Vectors padded to 4 entries (index 3 = empty / never selected) |
| NAUTOF (4) | Functions without `automatic` | Marked `automatic` |

### HAL: waived (listed in `lint/hal_waived_rules.txt`, filtered by `run_lint.sh`)
| Rules | Reason |
|---|---|
| CBPAHI (188 "errors"), TPOUNR, IOCOMB, FDTHRU | Combinational paths across modules / to outputs are deliberate: grant, DMA accept and FIFO pop happen in the same cycle. **Timing note for Tempus:** `m_arready` (input) -> `accept_ready` -> arbiter select -> FIFO pop is the longest input-to-register path. If it fails timing, register `accept_ready` (costs one cycle per burst). |
| FFWASR, FFWNSR | Synchronous reset is a design choice (works with Genus; recommended for Xilinx). The 16 FIFO memory words and tracker entries have no reset by design. |
| MAXLEN, SEPLIN, DECLIN, NUMSUF, IDLENG, NOBLKN, NBGEND, OLDALW, STYVAL, EXPIPC, PRMBSE, PADMSB | Coding-style rules (line length, naming, block labels, SV keyword style, explicit padding). |
| UNCONO, UNCONN | Unconnected ports documented above. |
| INDXOP, LRGOPR | `idx*W +: W` slicing synthesizes to a multiplexer; small constant multipliers in the score. |
| REVROP, SYNASN | Ordinary combinational `always @*` blocks read by clocked logic. |
| DALIAS | AR and AW share ID/address/length drivers (only one is valid at a time). |
| CONSTC, CNSTCN, CONSBS | Conditions on parameters (e.g. `WAIT_MODE == 0`, `HOLD_MAX > 1`), resolved at elaboration. |
| POIASG | Counter increments that are guarded (`< WAIT_MAX`, `!= 8'hFF`) or wrap by design (FIFO pointers on a power-of-two depth). |
| CDNOTE, INFNOT, PRTCNT | Informational notes. |

## Third pass: remaining HAL rules (lab run, 3 Nov)

### Fixed
| Rule | What | Fix |
|---|---|---|
| ULCMPE, ULRELE | FIFO `count == DEPTH`, `count_next >= THRESH`, arbiter `s > 15` compared a few bits against 32-bit integers | Sized localparams (`DEPTH_C`, `AFT_C`) and sized literals |
| UELOPR | `x + 1'b1` on wider counters | Increment constants sized to the counter (`8'd1`, `5'd1`, `PONE_C`, ...) |
| PRMVAL | FIFO parameters had no type | `parameter integer` |
| DIFFMN, MULTMF | `request_fifo` lived in `fifo.sv`; `chan_monitor` shared `traffic_monitor.sv` | Files are now `request_fifo.sv` and `chan_monitor.sv` (one module per file, named after it) |
| CDWARN, NODEFD | `` `define ARB_PORTS `` macro in `arbiter_select` | Replaced by SystemVerilog `.*` port connection (all arbiters share the port names) |
| MULNBA | `btags` given two non-blocking assignments on burst start | Single assignment from a combinational `first_tags` vector |
| SHFTNC | `3'b001 << ch` for the gather pop | One-hot decode `{ch==2, ch==1, ch==0}` |
| IDXTSM | `vector[idx*8 +: 8]` slicing in the arbiter | 4-entry arrays `wait_a[idx]`, `score_a[idx]` indexed directly by the 2-bit channel |
| MPCMPE | 17-operand score sum without parentheses | Grouped into pairs |

### Waived (added to `lint/hal_waived_rules.txt`)
| Rules | Reason |
|---|---|
| SYNPRT | Combinational output ports (grant, rd_en, AXI valids, pop, accept_ready, full/empty): the deliberate same-cycle handshake, same as CBPAHI. |
| TIELOG | AXI fields fixed by design: AxSIZE = 4 bytes, AxBURST = INCR, WSTRB all ones, RREADY/BREADY always high; baselines' scores tied to 0. |
| USEPRT, USEPAR | Baselines share the adaptive arbiter's port list; `arbiter_select` parameters unused in the generate branch not elaborated. |
| BADSYS, INIUSP | `$warning`/`$error` parameter checks inside `synthesis translate_off`; HAL ignores the pragma. |
| VLGMEM | Informational: FIFO/tracker arrays. |
| ATLGLC | Two-line glue (`accept = valid && !full`, `pause = almost_full`) in the top level. |
| MICAWS | The arbiter's single combinational selection block contains a loop with several `if`s. |
| BADFSM, EXTFSM, TRNMBT | The DMA's state register shares one clocked block with the burst-buffer registers (single-process FSM) and uses binary encoding. Functionally verified (AXI checker, 40-run regression); a two-process rewrite is optional style work. |

| MULBAS (fourth pass) | `first_tags` built with two blocking assignments in one `always @*` | Single continuous assignment (generate covers MAX_BURST = 1) |

| Superlint ASG_AR_OVFL on `sum` (fourth pass) | Spurious counterexample: Jasper abstracted each `weight * input` multiplier as a free value (trace showed `mult_223.out = 15'h7fff` with inputs 0..1) | `weight x input` rewritten as four conditional shifted adds (`wmul`); identical results in all sweeps including the 80-run weight exploration |

**Result: every HAL rule now either is fixed or has a written reason; `./lint/run_lint.sh hal` should report 0 unexplained findings.**
Regression after the third pass: step 2 and step 3 sweeps (with and without bursts) identical to before.

### Anything new
`./lint/run_lint.sh hal` prints only rules not listed in `lint/hal_waived_rules.txt`.

## Final status (3 Nov)
- Verilator `-Wall`: clean for all 4 arbiter configurations and MAX_BURST 1 / 4 / 16.
- Cadence HAL: 0 unexplained findings in all 4 configurations.
- Jasper Superlint: expected 2 findings, both AUTO_FORMAL dead code, kept as formal evidence
  (last-granted channel never overdue; v2 missed-grant count never exceeds 15).
