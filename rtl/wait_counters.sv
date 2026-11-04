`timescale 1ns/1ps
// ============================================================================
// wait_counters : per-channel starvation counters, shared by all arbiters
//   waitingN = consecutive cycles channel N has been non-empty without a grant.
//   Clears on grant or when the FIFO is empty; saturates at WAIT_MAX.
// ============================================================================
module wait_counters #(
    parameter integer WAIT_MAX = 255
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       empty1, empty2, empty3,
    input  wire       rd_en1, rd_en2, rd_en3,
    output reg  [7:0] waiting1, waiting2, waiting3
);
    localparam [7:0] WMAX8 = WAIT_MAX[7:0];

    always @(posedge clk) begin
        if (reset) begin
            waiting1 <= 8'd0;
            waiting2 <= 8'd0;
            waiting3 <= 8'd0;
        end else begin
            if (rd_en1 || empty1)         waiting1 <= 8'd0;
            else if (waiting1 < WMAX8) waiting1 <= waiting1 + 8'd1;

            if (rd_en2 || empty2)         waiting2 <= 8'd0;
            else if (waiting2 < WMAX8) waiting2 <= waiting2 + 8'd1;

            if (rd_en3 || empty3)         waiting3 <= 8'd0;
            else if (waiting3 < WMAX8) waiting3 <= waiting3 + 8'd1;
        end
    end
endmodule
