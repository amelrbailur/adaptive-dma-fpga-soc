`timescale 1ns/1ps
// ============================================================================
// tg_sparse : TG3, sparse-matrix (CSR SpMV) memory traffic
//   Per nonzero: read row_ptr, read col_idx, read value, write result.
//   A pseudo-random idle gap of 0..MAX_IDLE cycles follows each request.
//
// Changes from v1:
//   * Module renamed random_traffic_gen -> tg_sparse.
//   * Idle gap now really spans 0..MAX_IDLE. v1 used lfsr[1:0] % 5, which
//     can only produce 0..3. The LFSR slice is now sized from MAX_IDLE.
//   * (step 2) Idle time now continues during a pause; only an issue is
//     blocked. Fixes undercounted stalls when a pause began mid-idle.
//   * New 'stall' output (wants to issue but paused by backpressure).
//   * Counters sized instead of 'integer'.
//   * (coverage) ROW_BLOCK parameter: contiguous col_idx / value reads per
//     row (default 0 = original order) to exercise DMA read gathering.
// ============================================================================
// Lint waiver (reviewed): index counters are deliberately narrow and are
// widened into 32-bit address/data arithmetic. Stimulus model, not part of
// the synthesis top (adaptive_dma_top).
/* verilator lint_off WIDTHEXPAND */
module tg_sparse #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter NNZ         = 16,
    parameter ROWPTR_BASE = 32'h0002_0000,
    parameter COLIDX_BASE = 32'h0002_1000,
    parameter VALUES_BASE = 32'h0002_2000,
    parameter OUTPUT_BASE = 32'h0002_3000,
    parameter MAX_IDLE    = 4,
    parameter ROW_BLOCK   = 0      // 0 = per-nonzero order (default);
                                   // 1 = per 4-nonzero row: row_ptr, 4 col_idx
                                   //     (contiguous), 4 values (contiguous), write
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
    localparam [1:0] READ_ROWPTR  = 2'd0,
                     READ_COLIDX  = 2'd1,
                     READ_VALUE   = 2'd2,
                     WRITE_RESULT = 2'd3;

    // Bits of LFSR needed to cover 0..MAX_IDLE (must be <= 8)
    localparam RW = (MAX_IDLE < 1) ? 1 : $clog2(MAX_IDLE + 1);

    reg [1:0]               phase;
    reg [$clog2(NNZ)-1:0]   nz_idx;
    reg [7:0]               idle_count;
    reg [1:0]               sub;        // element within the row (ROW_BLOCK mode)
    wire [$clog2(NNZ)-1:0]  elem = nz_idx + sub;

    // 8-bit maximal-length LFSR (taps 8,6,5,4); seed must be nonzero
    reg  [7:0] lfsr;
    wire       feedback = lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3];

    assign stall = fifo_pause && (idle_count == 0) && !reset;

    always @(posedge clk) begin
        if (reset) begin
            lfsr       <= 8'hA5;
            idle_count <= 8'd0;
            sub        <= 2'd0;
            nz_idx     <= '0;
            phase      <= READ_ROWPTR;
            req        <= 1'b0;
            wr_en      <= 1'b0;
            addr       <= ROWPTR_BASE;
            data       <= '0;
        end else if (idle_count > 0) begin
            // Idle time passes even while the FIFO is paused
            req        <= 1'b0;
            wr_en      <= 1'b0;
            idle_count <= idle_count - 1'b1;
        end else if (fifo_pause) begin
            // Request ready but blocked by backpressure: this is a stall
            req   <= 1'b0;
            wr_en <= 1'b0;
        end else begin
            // Advance the LFSR once per request, so the idle-gap sequence is
            // identical whichever arbiter is used.
            lfsr <= {lfsr[6:0], feedback};
            req  <= 1'b1;

                case (phase)
                    READ_ROWPTR: begin
                        wr_en <= 1'b0;
                        addr  <= ROWPTR_BASE + (nz_idx / 4) * 4;
                        data  <= nz_idx / 4;
                        phase <= READ_COLIDX;
                    end
                    READ_COLIDX: begin
                        wr_en <= 1'b0;
                        addr  <= COLIDX_BASE + elem * 4;
                        data  <= (elem * 3) % 8;
                        if (ROW_BLOCK == 0 || sub == 2'd3) begin
                            sub   <= 2'd0;
                            phase <= READ_VALUE;
                        end else
                            sub <= sub + 2'd1;
                    end
                    READ_VALUE: begin
                        wr_en <= 1'b0;
                        addr  <= VALUES_BASE + elem * 4;
                        data  <= (elem + 1) * 5;
                        if (ROW_BLOCK == 0 || sub == 2'd3) begin
                            sub   <= 2'd0;
                            phase <= WRITE_RESULT;
                        end else
                            sub <= sub + 2'd1;
                    end
                    WRITE_RESULT: begin
                        wr_en  <= 1'b1;
                        addr   <= OUTPUT_BASE + (nz_idx / 4) * 4;
                        data   <= nz_idx / 4;
                        if (ROW_BLOCK == 0)
                            nz_idx <= (nz_idx == NNZ - 1) ? '0 : nz_idx + 1'b1;
                        else
                            nz_idx <= (nz_idx >= NNZ - 4) ? '0 : nz_idx + 3'd4;
                        phase  <= READ_ROWPTR;
                    end
                endcase

            idle_count <= lfsr[RW-1:0] % (MAX_IDLE + 1);
        end
    end
endmodule
/* verilator lint_on WIDTHEXPAND */
