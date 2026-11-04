`timescale 1ns/1ps
// ============================================================================
// arbiter_select : picks one arbiter at elaboration time
//   ARB_TYPE = 0 : fixed priority (FIR > MATMUL > SPARSE)
//   ARB_TYPE = 1 : round robin
//   ARB_TYPE = 2 : adaptive v1 (score + starvation override, step 1)
//   ARB_TYPE = 3 : adaptive v2 (missed-grant override + burst hold)
//   All four share one port list, so the rest of the design never changes.
//   (A runtime mode register replaces this in the AXI-Lite step.)
// ============================================================================
module arbiter_select #(
    parameter integer ARB_TYPE      = 2,
    parameter integer DEPTH         = 16,
    parameter integer WAIT_OVERRIDE = 12,
    parameter integer SCORE_W       = 8,
    // ADAPT_V2 tuning knobs
    parameter integer HOLD_MAX      = 4,
    parameter integer W_OCC         = 4,
    parameter integer W_WAIT        = 3,
    parameter integer W_RATE        = 2,
    parameter integer W_BURST       = 1
)(
    input  wire                     clk,
    input  wire                     reset,
    input  wire                     mem_ready,
    input  wire                     empty1, empty2, empty3,
    input  wire [$clog2(DEPTH):0]   fifo_count1, fifo_count2, fifo_count3,
    input  wire                     almost_full1, almost_full2, almost_full3,
    input  wire [3:0]               arrival_rate1, arrival_rate2, arrival_rate3,
    input  wire [3:0]               burst_len1, burst_len2, burst_len3,
    output wire                     rd_en1, rd_en2, rd_en3,
    output wire [1:0]               grant,
    output wire [SCORE_W-1:0]       score1, score2, score3,
    output wire [7:0]               waiting1, waiting2, waiting3
);

    // All four arbiters use exactly this module's port names, so the
    // instances connect by name with .* (no macros).
    generate
        if (ARB_TYPE == 0) begin : g_fixed
            fixed_priority_arbiter #(.DEPTH(DEPTH), .SCORE_W(SCORE_W)) u_arb (.*);
        end else if (ARB_TYPE == 1) begin : g_rr
            rr_arbiter #(.DEPTH(DEPTH), .SCORE_W(SCORE_W)) u_arb (.*);
        end else if (ARB_TYPE == 2) begin : g_adaptive
            adaptive_arbiter #(.DEPTH(DEPTH), .WAIT_OVERRIDE(WAIT_OVERRIDE),
                               .SCORE_W(SCORE_W)) u_arb (.*);
        end else begin : g_adaptive_v2
            adaptive_arbiter #(.DEPTH(DEPTH), .WAIT_OVERRIDE(WAIT_OVERRIDE),
                               .SCORE_W(SCORE_W), .WAIT_MODE(1), .HOLD_MAX(HOLD_MAX),
                               .W_OCC(W_OCC), .W_WAIT(W_WAIT),
                               .W_RATE(W_RATE), .W_BURST(W_BURST)) u_arb (.*);
        end
    endgenerate


endmodule
