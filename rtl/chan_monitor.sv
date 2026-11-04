`timescale 1ns/1ps
// ============================================================================
// chan_monitor : per-channel arrival rate and current burst length
//   (used by traffic_monitor; one instance per channel)
//   rate  : events in the last completed 16-cycle window (saturates at 15)
//   burst : length of the current back-to-back event streak (saturates at 15)
// ============================================================================
module chan_monitor (
    input  wire       clk,
    input  wire       reset,
    input  wire       event_i,
    input  wire       window_end,
    output reg  [3:0] rate,
    output reg  [3:0] burst
);

    reg  [4:0] count;                       // 0..16 events per window
    wire [4:0] count_inc = count + {4'd0, event_i};
    wire [4:0] streak_inc = {1'b0, burst} + 5'd1;

    always @(posedge clk) begin
        if (reset) begin
            count <= 5'd0;
            rate  <= 4'd0;
            burst <= 4'd0;
        end else begin
            // Arrival rate over the window
            if (window_end) begin
                rate  <= (count_inc > 5'd15) ? 4'd15 : count_inc[3:0];
                count <= 5'd0;
            end else begin
                count <= count_inc;
            end

            // Current streak length
            if (event_i)
                burst <= (streak_inc > 5'd15) ? 4'd15 : streak_inc[3:0];
            else
                burst <= 4'd0;
        end
    end

endmodule
