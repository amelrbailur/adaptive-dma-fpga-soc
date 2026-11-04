`timescale 1ns/1ps
// ============================================================================
// rr_arbiter : baseline 2, work-conserving round-robin
//   Grants the first non-empty channel after the last one granted.
//   Same port list as adaptive_arbiter; traffic metrics are ignored.
// ============================================================================
module rr_arbiter #(
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

    reg  [1:0] last_grant;
    wire [3:0] empty_v = {1'b1, empty3, empty2, empty1};   // padded: index 3 in range
    reg  [1:0] idx;
    integer    k;

    function automatic [1:0] next_ch;
        input [1:0] c;
        begin
            next_ch = (c >= 2'd2) ? 2'd0 : c + 2'd1;
        end
    endfunction

    always @* begin
        grant = 2'd3;
        idx   = last_grant;            // assigned on every path (no latch)
        if (mem_ready) begin
            for (k = 0; k < 3; k = k + 1) begin
                idx = next_ch(idx);
                if (grant == 2'd3 && !empty_v[idx])
                    grant = idx;
            end
        end
        rd_en1 = (grant == 2'd0);
        rd_en2 = (grant == 2'd1);
        rd_en3 = (grant == 2'd2);
    end

    always @(posedge clk) begin
        if (reset)               last_grant <= 2'd2;
        else if (grant != 2'd3)  last_grant <= grant;
    end

    wait_counters #(.WAIT_MAX(WAIT_MAX)) u_wait (
        .clk(clk), .reset(reset),
        .empty1(empty1), .empty2(empty2), .empty3(empty3),
        .rd_en1(rd_en1), .rd_en2(rd_en2), .rd_en3(rd_en3),
        .waiting1(waiting1), .waiting2(waiting2), .waiting3(waiting3));

endmodule
