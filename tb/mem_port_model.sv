`timescale 1ns/1ps
// ============================================================================
// mem_port_model : stand-in for the memory side until the AXI master exists
//
//   SERVICE_INTERVAL : cycles per accepted request (1 = one per cycle,
//                      2 = half bandwidth, ...). Models port bandwidth.
//   SWITCH_PENALTY   : extra busy cycles when the accepted request comes from
//                      a different channel than the previous one. A crude
//                      model of the cost of interleaving streams (DRAM row
//                      misses / AXI ID or burst changes). 0 disables it.
//
//   ready is registered state only, so the arbiter's grant can depend on it
//   without a combinational loop.
// ============================================================================
module mem_port_model #(
    parameter integer SERVICE_INTERVAL = 1,
    parameter integer SWITCH_PENALTY   = 0
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       accept,        // a grant was issued this cycle
    input  wire [1:0] accept_ch,     // which channel
    output wire       ready
);
    reg [7:0] busy;
    reg [1:0] last_ch;
    reg       have_last;

    assign ready = (busy == 0);

    always @(posedge clk) begin
        if (reset) begin
            busy      <= 8'd0;
            last_ch   <= 2'd0;
            have_last <= 1'b0;
        end else if (accept && ready) begin
            busy      <= (SERVICE_INTERVAL - 1)
                       + ((have_last && accept_ch != last_ch) ? SWITCH_PENALTY : 0);
            last_ch   <= accept_ch;
            have_last <= 1'b1;
        end else if (busy != 0) begin
            busy <= busy - 1'b1;
        end
    end
endmodule
