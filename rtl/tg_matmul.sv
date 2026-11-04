`timescale 1ns/1ps
// ============================================================================
// tg_matmul : TG2, matrix-multiplication memory traffic (bursty)
//   C[i][j] = sum_k A[i][k]*B[k][j]: alternates A and B reads, then writes C.
//   Issues BURST_LEN requests back to back, then idles IDLE_CYCLES.
//
// Changes from v1:
//   * Module renamed bursty_traffic_gen -> tg_matmul.
//   * (step 2) Idle time now continues during a pause; only an issue is
//     blocked. Fixes undercounted stalls when a pause began mid-idle.
//   * New 'stall' output (wants to issue but paused by backpressure).
//   * Counters sized instead of 'integer'.
//   * (coverage) ROW_FIRST parameter: contiguous A-row reads (default 0 =
//     original order) so the DMA's read gathering is exercised on this channel.
// ============================================================================
// Lint waiver (reviewed): index counters are deliberately narrow and are
// widened into 32-bit address/data arithmetic. Stimulus model, not part of
// the synthesis top (adaptive_dma_top).
/* verilator lint_off WIDTHEXPAND */
module tg_matmul #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter MATRIX_N    = 8,
    parameter A_BASE      = 32'h0003_0000,
    parameter B_BASE      = 32'h0003_1000,
    parameter C_BASE      = 32'h0003_2000,
    parameter BURST_LEN   = 4,
    parameter IDLE_CYCLES = 4,
    parameter ROW_FIRST   = 0      // 0 = alternate A/B reads (default);
                                   // 1 = read the whole A row (contiguous),
                                   //     then the B column, then write C
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
    localparam [1:0] READ_A  = 2'd0,
                     READ_B  = 2'd1,
                     WRITE_C = 2'd2;

    localparam NW = $clog2(MATRIX_N);

    reg [1:0]  phase;
    reg [NW-1:0] row_idx, col_idx, k_idx;
    reg [7:0]  burst_count;
    reg [7:0]  idle_count;

    // A stall is a pause during the active (non-idle) part of the pattern.
    assign stall = fifo_pause && (idle_count == 0) && !reset;

    always @(posedge clk) begin
        if (reset) begin
            req         <= 1'b0;
            wr_en       <= 1'b0;
            addr        <= A_BASE;
            data        <= '0;
            phase       <= READ_A;
            row_idx     <= '0;
            col_idx     <= '0;
            k_idx       <= '0;
            burst_count <= 8'd0;
            idle_count  <= 8'd0;
        end else if (idle_count > 0) begin
            // Idle time between bursts passes even while the FIFO is paused
            req        <= 1'b0;
            wr_en      <= 1'b0;
            idle_count <= idle_count - 1'b1;
        end else if (fifo_pause) begin
            // Request ready but blocked by backpressure: this is a stall
            req   <= 1'b0;
            wr_en <= 1'b0;
        end else begin
            req <= 1'b1;

            if (burst_count == BURST_LEN - 1) begin
                burst_count <= 8'd0;
                idle_count  <= IDLE_CYCLES;
            end else begin
                burst_count <= burst_count + 1'b1;
            end

            case (phase)
                READ_A: begin
                    wr_en <= 1'b0;
                    addr  <= A_BASE + (row_idx * MATRIX_N + k_idx) * 4;
                    data  <= row_idx * MATRIX_N + k_idx;
                    if (ROW_FIRST == 0)
                        phase <= READ_B;
                    else if (k_idx == MATRIX_N - 1) begin
                        k_idx <= '0;
                        phase <= READ_B;
                    end else
                        k_idx <= k_idx + 1'b1;
                end
                READ_B: begin
                    wr_en <= 1'b0;
                    addr  <= B_BASE + (k_idx * MATRIX_N + col_idx) * 4;
                    data  <= k_idx * MATRIX_N + col_idx;
                    if (k_idx == MATRIX_N - 1) begin
                        k_idx <= '0;
                        phase <= WRITE_C;
                    end else begin
                        k_idx <= k_idx + 1'b1;
                        if (ROW_FIRST == 0) phase <= READ_A;
                    end
                end
                WRITE_C: begin
                    wr_en <= 1'b1;
                    addr  <= C_BASE + (row_idx * MATRIX_N + col_idx) * 4;
                    data  <= row_idx * MATRIX_N + col_idx;
                    phase <= READ_A;
                    if (col_idx == MATRIX_N - 1) begin
                        col_idx <= '0;
                        row_idx <= (row_idx == MATRIX_N - 1) ? '0 : row_idx + 1'b1;
                    end else begin
                        col_idx <= col_idx + 1'b1;
                    end
                end
                default: begin
                    phase <= READ_A;
                    req   <= 1'b0;
                    wr_en <= 1'b0;
                end
            endcase
        end
    end
endmodule
/* verilator lint_on WIDTHEXPAND */
