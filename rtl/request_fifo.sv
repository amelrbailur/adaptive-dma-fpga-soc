`timescale 1ns/1ps
// ============================================================================
// request_fifo : synchronous FIFO with occupancy count and almost-full flag
//
// Changes from v1:
//   * almost_full is now computed from the NEXT count, so it is exact for the
//     current occupancy (v1 lagged one cycle behind count). This tightens the
//     backpressure loop: with THRESH=12 the FIFO now peaks at 13, not 14.
//   * (step 3) 'head' output: combinational view of the head entry, so the
//     DMA can inspect the next request before popping it (burst gathering).
//   * Width is generic; the testbench packs a 16-bit enqueue timestamp in the
//     upper bits so latency can be measured per request.
// ============================================================================
module request_fifo #(
    parameter integer DATA_WIDTH         = 81,
    parameter integer DEPTH              = 16,   // must be a power of two
    parameter integer ALMOST_FULL_THRESH = 12
)(
    input  wire                   clk,
    input  wire                   reset,

    input  wire                   wr_en,
    input  wire [DATA_WIDTH-1:0]  din,

    input  wire                   rd_en,
    output reg  [DATA_WIDTH-1:0]  dout,     // valid the cycle after rd_en
    output wire [DATA_WIDTH-1:0]  head,     // current head entry (first-word
                                            // fall-through view), valid when !empty

    output wire                   full,
    output wire                   empty,
    output reg                    almost_full,
    output reg  [$clog2(DEPTH):0] count
);

    localparam integer AW = $clog2(DEPTH);

    // Sized constants (no mixed-width compares or arithmetic)
    localparam [AW:0]   DEPTH_C = DEPTH[AW:0];
    localparam [AW:0]   AFT_C   = ALMOST_FULL_THRESH[AW:0];
    localparam [AW:0]   ONE_C   = {{AW{1'b0}}, 1'b1};
    localparam [AW-1:0] PONE_C  = {{(AW-1){1'b0}}, 1'b1};

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0]         wr_ptr, rd_ptr;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    reg [AW:0] count_next;

    assign head  = mem[rd_ptr];
    assign full  = (count == DEPTH_C);
    assign empty = (count == {(AW+1){1'b0}});

    always @* begin
        case ({do_wr, do_rd})
            2'b10:   count_next = count + ONE_C;
            2'b01:   count_next = count - ONE_C;
            default: count_next = count;
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            wr_ptr      <= '0;
            rd_ptr      <= '0;
            count       <= '0;
            dout        <= '0;
            almost_full <= 1'b0;
        end else begin
            if (do_wr) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + PONE_C;   // wraps by design (power-of-2 depth)
            end
            if (do_rd) begin
                dout   <= mem[rd_ptr];
                rd_ptr <= rd_ptr + PONE_C;
            end
            count       <= count_next;
            almost_full <= (count_next >= AFT_C);
        end
    end

endmodule
