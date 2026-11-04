# Zynq-7020 Implementation Plan

Status: **not started** (ASIC flow complete; FPGA validation pending Vivado access).

## Goal
Run the adaptive DMA subsystem on a Zynq-7020 board, connected to DDR through a PS high-performance (HP)
port, and measure real throughput and latency for each arbiter mode at runtime.

## Why the RTL is ready for it
- AXI3 DMA, matching the Zynq-7000 HP ports.
- Synchronous resets and inferred memories (map to FFs / BRAM without changes).
- Arbiter selected by parameter today; to be made runtime-selectable.

## Tasks
| # | Task | Owner | Status |
|---|---|---|---|
| 1 | AXI-Lite register block: arbiter mode, weights, thresholds, start/stop, error status | | ☐ |
| 2 | Performance counters (beats, cycles, per-channel latency min/max/sum, row hits) readable over AXI-Lite | | ☐ |
| 3 | Base-address offset register so the DMA targets a reserved DDR region | | ☐ |
| 4 | Vivado block design: Zynq PS, HP0 (S_AXI_HP0) for the DMA master, GP0 for AXI-Lite, clocking/reset | | ☐ |
| 5 | Synthesis + implementation at a target of 100–150 MHz; review timing and utilization | | ☐ |
| 6 | Vitis bare-metal app: configure mode, run each scenario, print counters over UART | | ☐ |
| 7 | ILA on the AXI interface for debug | | ☐ |
| 8 | Compare on-board numbers against simulation; record in `results/fpga/` | | ☐ |

## Deliverables to add to the repo
- `fpga/rtl/` (AXI-Lite wrapper and top), `fpga/bd/` (block design Tcl from `write_bd_tcl`),
  `fpga/constraints/` (XDC), `fpga/sw/` (Vitis sources only)
- `results/fpga/`: utilization and timing reports, UART logs, comparison table
- Screenshot of the block design and ILA capture in `docs/images/`
