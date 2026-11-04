# Code-coverage exclusions (reviewed)

Every item below was reported uncovered by IMC after the coverage regression and was checked
against the RTL. Two other items were real gaps and are now covered by tests:

| Was uncovered | Now covered by |
|---|---|
| `adaptive_arbiter` line 273: `hold_cnt` saturation at 255 (block + expression term 2) | `solo_a2`, `solo_a3`: only FIR active, so one channel is granted for >255 grants in a row |
| `axi3_dma_master` line 306: `b_id_bad` alone (expression term 2) | `err_bid`: memory returns one write response with a wrong BID (`ERR=3`) |

## Items to exclude (none can be hit by design)
| Instance | Line | Item | Reason (paste as the IMC exclusion comment) |
|---|---|---|---|
| `arbiter.g_adaptive.u_arb`, `arbiter.g_adaptive_v2.u_arb` | 83, 85 | `$warning` blocks | Elaboration-time parameter checks; fire only for invalid parameters |
| `dma` | 118 | `$error` block | Elaboration-time parameter check (MAX_BURST must be 1..16) |
| `arbiter.g_adaptive.u_arb`, `arbiter.g_adaptive_v2.u_arb` | 98 | `else s = s << (4 - LG2)` | Constant branch: only used when DEPTH < 16 |
| `arbiter.g_rr.u_arb.u_wait`, `g_adaptive.u_arb.u_wait`, `g_adaptive_v2.u_arb.u_wait` | 25, 28, 31 | implicit else (wait counter saturates at 255) | Wait is bounded by the arbiter (RR: <= 2 grants; adaptive: override) |
| `arbiter.g_fixed.u_arb.u_wait` | 25 | implicit else (FIR wait counter saturates) | FIR is the top fixed-priority channel and is never starved |
| `arbiter.g_adaptive.u_arb` | 159, 161, 163 | implicit else; expression terms 1 and 2 | v1: `opportunity` is constant 1 (WAIT_MODE = 0) and age is bounded by the override |
| `arbiter.g_adaptive_v2.u_arb` | 159, 161, 163 | expression term 2 (`age < 255` false) | Bounded: Jasper proved the v2 missed-grant count never exceeds 15 |
| `arbiter.g_adaptive.u_arb` | 255 | `else if (sticky)` true part | Burst hold disabled in v1 (HOLD_MAX = 1) |

## How to make the exclusion file (IMC GUI, once)
1. Run the coverage regression and merge: `./run3.sh xrun cov`
2. Open the merged result: `imc -load cov_work/merged/all &`
3. In **Verification Hierarchy**, expand `adaptive_dma_top` and select an instance from the table.
4. In the lower-right **Details** pane, open the **Block** (or **Expression**) list, show uncovered items only,
   select the item at the line in the table, then **Exclude** (toolbar, Refinement group).
   When asked, paste the reason as the comment.
5. Repeat for every row. Then **Refinement Files > Save** and save as `cov/exclusions.vRefine`
   in the project folder.
6. Rerun only the merge: `./run3.sh xrun covmerge`. The script loads `cov/exclusions.vRefine`
   automatically, so the reports show the excluded items as excluded, and the grades are over
   reachable code.

Expected after exclusions: Block, Expression and FSM at 100 % for every instance.
Toggle stays as measured (see `EXPECTED_HOLES.md`): upper address and data bits never toggle with these workloads.
