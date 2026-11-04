`timescale 1ns/1ps
// ============================================================================
// traffic_monitor : per-channel arrival rate and current burst length
//
// Changes from v1:
//   * Measures DEMAND, not just accepted requests. A channel counts an event
//     in a cycle if its request was accepted OR it was stalled by backpressure.
//     In v1 a congested (paused) channel showed a LOWER rate, which pushed the
//     arbiter the wrong way.
//   * Port renamed accepted_write -> accepted_req (reads were always counted).
//   * Integers replaced with sized registers; one shared window counter and a
//     per-channel submodule instead of three copies of the same code.
//
//   arrival_rateN : events in the last completed 16-cycle window (sat. at 15)
//   burst_lenN    : length of the current back-to-back event streak (sat. 15)
// ============================================================================
module traffic_monitor (
    input  wire       clk,
    input  wire       reset,

    input  wire [2:0] accepted_req,   // req && !full, per channel
    input  wire [2:0] stalled,        // channel wanted to issue but was paused

    output wire [3:0] arrival_rate1,
    output wire [3:0] arrival_rate2,
    output wire [3:0] arrival_rate3,

    output wire [3:0] burst_len1,
    output wire [3:0] burst_len2,
    output wire [3:0] burst_len3
);

    wire [2:0] demand = accepted_req | stalled;

    // One 16-cycle measurement window shared by all channels.
    reg  [3:0] window;
    wire       window_end = (window == 4'd15);

    always @(posedge clk) begin
        if (reset) window <= 4'd0;
        else       window <= window_end ? 4'd0 : window + 4'd1;   // explicit wrap
    end

    chan_monitor m1 (.clk(clk), .reset(reset), .event_i(demand[0]), .window_end(window_end),
                     .rate(arrival_rate1), .burst(burst_len1));
    chan_monitor m2 (.clk(clk), .reset(reset), .event_i(demand[1]), .window_end(window_end),
                     .rate(arrival_rate2), .burst(burst_len2));
    chan_monitor m3 (.clk(clk), .reset(reset), .event_i(demand[2]), .window_end(window_end),
                     .rate(arrival_rate3), .burst(burst_len3));

endmodule
