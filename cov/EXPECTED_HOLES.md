# Coverage: what the regression covers, and the holes to expect

## Regression (`./run3.sh xrun cov`, 37 runs, all must PASS)
| Group | Runs | Purpose |
|---|---|---|
| Sweep | 20 | 5 scenarios x 4 arbiters (the results runs) |
| Backpressure (`BP=1`) | 8 | ARREADY / AWREADY / WREADY randomly low: DMA wait states, AXI stability rules |
| CONTIG (scenario 5) | 4 | Contiguous access orders: multi-beat write bursts, read gathering on all 3 channels |
| Error injection | 3 | `ERR=1` SLVERR on a read and a write, `ERR=2` wrong RID, `ERR=3` wrong BID: `err_status` bits 0 and 1 |
| SOLO | 2 | Only FIR active (adaptive v1, v2): long single-channel grant runs, hold counter saturation |

## What coverage found
1. **Write gathering had never run.** With the original workloads every write burst was 1 beat
   (each channel writes one word between reads). The CONTIG scenario now produces 2-, 3- and
   4-beat write bursts.
2. **Read gathering only ever ran on the FIR channel** (MATMUL and SPARSE addresses were never
   contiguous). CONTIG covers both.
3. **The DMA's AXI wait states had never run** (the memory model held READY high). With random
   backpressure the first run failed: a **testbench bug**, the AXI checker stored the 35-bit
   `{wlast, wid, wdata}` in a 34-bit register, so its W-stability rule could never pass. The DMA was
   correct (trace: W fields stable while WREADY low). Fixed; all backpressure runs pass.
4. **The error-detection logic had never run.** Error injection now exercises both bits.

## Functional coverage (cov/out/func_cov.txt): 42 / 42 bins

## Code coverage holes to expect in IMC (cov/out/code_cov_*.txt), by design
| Where | Item | Why it is not hit |
|---|---|---|
| `axi3_dma_master` | `default: state <= S_IDLE` | 3-bit state, 5 states used; codes 5-7 unreachable |
| `axi3_dma_master` | `len == 0` branch of `len_m1` | `len` is 0 only while idle |
| `request_fifo` (request FIFOs) | `full` true, `wr_en && full` | Backpressure at 12 entries stops writes before 16 |
| `request_fifo` (trackers) | `full`, `almost_full` | `accept_ready` keeps outstanding bursts < MAX_OUT |
| `adaptive_arbiter` | score saturation `sum > 255` | Proven unreachable by Jasper with current weights (max 180) |
| `adaptive_arbiter` | `overdue = 1` on the last loop step | Proven unreachable by Jasper (last-granted channel never overdue) |
| `adaptive_arbiter` (v2) | `norm_wait` saturation | Proven unreachable by Jasper (missed grants never exceed 15) |
| `wait_counters` | saturation at 255 | Reached only by starved channels under FIXED priority |
| Toggle | upper address / data bits | Workload addresses are 0x0001_xxxx-0x0003_xxxx; data are small tags |
| `axi3_dma_master` | `g_ftag1` generate branch | Only elaborated for MAX_BURST = 1 (`./run3.sh xrun nobursts`) |

After the lab run, the actual uncovered items were reviewed: see `EXCLUSIONS.md`.
