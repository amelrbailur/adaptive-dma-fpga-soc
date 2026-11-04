`timescale 1ns/1ps
// ============================================================================
// fixed_priority_arbiter : baseline 1, static priority FIR > MATMUL > SPARSE
//   Same port list as adaptive_arbiter so the three are drop-in swappable.
//   Traffic metrics, counts and almost-full are accepted but ignored.
//   Scores are tied to 0; waiting counters are kept for measurement.
// ============================================================================
module fixed_priority_arbiter #(
    parameter integer DEPTH    = 16,
    parameter integer WAIT_MAX = 255,
    parameter integer SCORE_W  = 8
)(
    input  wire                     clk,
    input  wire                     reset,
    input  wire                     mem_ready,

    input  wire                     empty1, empty2, empty3,
    // Shared port list with adaptive_arbiter; these inputs are intentionally
    // unused by this baseline (lint waiver, reviewed).
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [$clog2(DEPTH):0]   fifo_count1, fifo_count2, fifo_count3,   // unused
    input  wire                     almost_full1, almost_full2, almost_full3, // unused
    input  wire [3:0]               arrival_rate1, arrival_rate2, arrival_rate3, // unused
    input  wire [3:0]               burst_len1, burst_len2, burst_len3,       // unused
    /* verilator lint_on UNUSEDSIGNAL */

    output reg                      rd_en1, rd_en2, rd_en3,
    output reg  [1:0]               grant,
    output wire [SCORE_W-1:0]       score1, score2, score3,
    output wire [7:0]               waiting1, waiting2, waiting3
);

    assign score1 = '0;
    assign score2 = '0;
    assign score3 = '0;

    always @* begin
        if (!mem_ready)   grant = 2'd3;
        else if (!empty1) grant = 2'd0;
        else if (!empty2) grant = 2'd1;
        else if (!empty3) grant = 2'd2;
        else              grant = 2'd3;

        rd_en1 = (grant == 2'd0);
        rd_en2 = (grant == 2'd1);
        rd_en3 = (grant == 2'd2);
    end

    wait_counters #(.WAIT_MAX(WAIT_MAX)) u_wait (
        .clk(clk), .reset(reset),
        .empty1(empty1), .empty2(empty2), .empty3(empty3),
        .rd_en1(rd_en1), .rd_en2(rd_en2), .rd_en3(rd_en3),
        .waiting1(waiting1), .waiting2(waiting2), .waiting3(waiting3));

endmodule
