`timescale 1ns/1ps
// ============================================================================
// tg_fir : TG1, FIR-filter memory traffic
//   Per output sample: read 1 input sample, read NUM_TAPS coefficients,
//   write 1 output sample. Offered load 1/(1+ISSUE_GAP); default every cycle.
//
// Changes from v1:
//   * Module renamed sequential_traffic_gen -> tg_fir (matches file name).
//   * (step 2) Idle time now continues during a pause; only an issue is
//     blocked. Fixes undercounted stalls when a pause began mid-idle.
//   * New 'stall' output: high when the generator wants to issue but is
//     paused by FIFO backpressure. Feeds the traffic monitor (demand) and
//     the testbench stall statistics.
//   * Unused coeff_idx removed; counters sized instead of 'integer'.
//   * (step 2) ISSUE_GAP parameter sets the offered load: 1/(1+ISSUE_GAP).
//   * (coverage) OUT_BLOCK parameter: write outputs in blocks (default 1 =
//     original behaviour) so the DMA's write-burst gathering gets exercised.
// ============================================================================
// Lint waiver (reviewed): index counters are deliberately narrow and are
// widened into 32-bit address/data arithmetic. Stimulus model, not part of
// the synthesis top (adaptive_dma_top).
/* verilator lint_off WIDTHEXPAND */
module tg_fir #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter INPUT_BASE  = 32'h0001_0000,
    parameter COEFF_BASE  = 32'h0001_1000,
    parameter OUTPUT_BASE = 32'h0001_2000,
    parameter NUM_TAPS    = 8,
    parameter NUM_SAMPLES = 64,
    parameter ISSUE_GAP   = 0,     // idle cycles after each request (0 = 100% load)
    parameter OUT_BLOCK   = 1      // outputs written per block (1 = after every sample;
                                   // 4 = compute 4 samples, then write 4 consecutive
                                   // outputs: produces multi-beat write bursts)
)(
    input  wire                  clk,
    input  wire                  reset,
    input  wire                  fifo_pause,
    output reg                   req,
    output reg                   wr_en,
    output reg  [ADDR_WIDTH-1:0] addr,
    output reg  [DATA_WIDTH-1:0] data,
    output wire                  stall
);
    localparam [1:0] READ_SAMPLE = 2'd0,
                     READ_COEFF  = 2'd1,
                     WRITE_OUT   = 2'd2;

    reg [1:0]                         phase;
    reg [$clog2(NUM_SAMPLES)-1:0]     sample_idx;
    reg [$clog2(NUM_TAPS)-1:0]        tap_idx;
    reg [7:0]                         idle_count;
    reg [7:0]                         blk_cnt;    // samples computed in this block
    reg [7:0]                         wr_k;       // output being written in the block
    reg [$clog2(NUM_SAMPLES)-1:0]     blk_base;   // first sample of the block

    wire [$clog2(NUM_SAMPLES)-1:0] next_sample =
        (sample_idx == NUM_SAMPLES - 1) ? '0 : sample_idx + 1'b1;

    // A stall is a pause while the generator has a request ready to issue.
    assign stall = fifo_pause && (idle_count == 0) && !reset;

    always @(posedge clk) begin
        if (reset) begin
            req        <= 1'b0;
            wr_en      <= 1'b0;
            addr       <= INPUT_BASE;
            data       <= '0;
            phase      <= READ_SAMPLE;
            sample_idx <= '0;
            tap_idx    <= '0;
            idle_count <= 8'd0;
            blk_cnt    <= 8'd0;
            wr_k       <= 8'd0;
            blk_base   <= '0;
        end else if (idle_count > 0) begin
            // Idle (computing) time passes even while the FIFO is paused
            req        <= 1'b0;
            wr_en      <= 1'b0;
            idle_count <= idle_count - 1'b1;
        end else if (fifo_pause) begin
            // Request ready but blocked by backpressure: this is a stall
            req   <= 1'b0;
            wr_en <= 1'b0;
        end else begin
            req        <= 1'b1;
            idle_count <= ISSUE_GAP;
            case (phase)
                READ_SAMPLE: begin
                    wr_en <= 1'b0;
                    addr  <= INPUT_BASE + sample_idx * 4;
                    data  <= sample_idx;
                    phase <= READ_COEFF;
                end
                READ_COEFF: begin
                    wr_en <= 1'b0;
                    addr  <= COEFF_BASE + tap_idx * 4;
                    data  <= tap_idx;
                    if (tap_idx == NUM_TAPS - 1) begin
                        tap_idx <= '0;
                        if (blk_cnt == OUT_BLOCK - 1) begin
                            blk_cnt <= 8'd0;
                            wr_k    <= 8'd0;
                            phase   <= WRITE_OUT;
                        end else begin
                            blk_cnt    <= blk_cnt + 1'b1;
                            sample_idx <= next_sample;
                            phase      <= READ_SAMPLE;
                        end
                    end else begin
                        tap_idx <= tap_idx + 1'b1;
                    end
                end
                WRITE_OUT: begin
                    // data is a workload tag, not FIR arithmetic
                    wr_en <= 1'b1;
                    addr  <= OUTPUT_BASE + (blk_base + wr_k) * 4;
                    data  <= blk_base + wr_k;
                    if (wr_k == OUT_BLOCK - 1) begin
                        sample_idx <= next_sample;
                        blk_base   <= next_sample;
                        phase      <= READ_SAMPLE;
                    end else begin
                        wr_k <= wr_k + 1'b1;
                    end
                end
                default: begin
                    phase <= READ_SAMPLE;
                    req   <= 1'b0;
                    wr_en <= 1'b0;
                end
            endcase
        end
    end
endmodule
/* verilator lint_on WIDTHEXPAND */
