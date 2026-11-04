`timescale 1ns/1ps
// ============================================================================
// axi3_dma_master : turns arbitrated channel requests into AXI3 bursts
//
// Flow per burst
//   1. The arbiter grants channel g (grant != 3, only while accept_ready).
//      The arbiter's rd_en pops g's head; this block captures that same
//      head entry as beat 0.
//   2. GATHER: while the next entry at g's head is the same direction, the
//      next word address (addr + 4), does not start a new 4 KB page, and the
//      burst is shorter than MAX_BURST, pop it too (via 'pop').
//   3. Issue one INCR burst: AR for reads; AW then W beats for writes.
//      valid stays asserted with stable fields until ready (AXI rule).
//   4. Each issued burst is recorded in an in-order tracker. RLAST / BRESP
//      pops it and raises a completion carrying the per-beat tags, so the
//      testbench can measure end-to-end latency per request.
//   5. Read data is returned on the rd_data_* stream, tagged with the
//      channel (RID), for the accelerators to consume.
//   6. err_status flags (sticky until reset):
//        [0] resp_err : RRESP or BRESP was not OKAY (SLVERR / DECERR)
//        [1] id_err   : RID / BID did not match the oldest outstanding
//                       burst, or a response arrived with nothing outstanding
//
// AXI3 details (Zynq-7000 HP ports are AXI3): AxLEN is 4 bits (max 16
// beats), WID is present, AxSIZE = 32-bit, AxBURST = INCR. ID = channel.
// Responses are assumed in order per direction (single slave, in-order).
//
// Throughput: a single-beat read can be issued and a new grant accepted in
// the same cycle, so reads can sustain one burst per cycle. Writes take
// AW + len W cycles.
// ============================================================================
module axi3_dma_master #(
    parameter integer ADDR_W    = 32,
    parameter integer DATA_W    = 32,
    parameter integer TAG_W     = 16,
    parameter integer MAX_BURST = 4,     // <= 16 for AXI3
    parameter integer MAX_OUT   = 8      // outstanding bursts per direction (power of 2)
)(
    input  wire                       clk,
    input  wire                       reset,

    // ---------------- from the request FIFOs / arbiter ----------------
    input  wire [2:0]                 empty,
    input  wire [2:0]                 head_wr,
    input  wire [3*ADDR_W-1:0]        head_addr,
    input  wire [3*DATA_W-1:0]        head_data,
    input  wire [3*TAG_W-1:0]         head_tag,
    input  wire [1:0]                 grant,          // 3 = no grant
    output wire                       accept_ready,   // -> arbiter mem_ready
    output wire [2:0]                 pop,            // extra pops while gathering

    // ---------------- AXI3 master: write address ----------------
    output wire [1:0]                 awid,
    output wire [ADDR_W-1:0]          awaddr,
    output wire [3:0]                 awlen,
    output wire [2:0]                 awsize,
    output wire [1:0]                 awburst,
    output wire                       awvalid,
    input  wire                       awready,
    // ---------------- write data ----------------
    output wire [1:0]                 wid,
    output wire [DATA_W-1:0]          wdata,
    output wire [DATA_W/8-1:0]        wstrb,
    output wire                       wlast,
    output wire                       wvalid,
    input  wire                       wready,
    // ---------------- write response ----------------
    input  wire [1:0]                 bid,
    input  wire [1:0]                 bresp,
    input  wire                       bvalid,
    output wire                       bready,
    // ---------------- read address ----------------
    output wire [1:0]                 arid,
    output wire [ADDR_W-1:0]          araddr,
    output wire [3:0]                 arlen,
    output wire [2:0]                 arsize,
    output wire [1:0]                 arburst,
    output wire                       arvalid,
    input  wire                       arready,
    // ---------------- read data ----------------
    input  wire [1:0]                 rid,
    input  wire [DATA_W-1:0]          rdata,
    input  wire [1:0]                 rresp,
    input  wire                       rlast,
    input  wire                       rvalid,
    output wire                       rready,

    // ---------------- completions ----------------
    output wire                       rd_cpl_valid,
    output wire [1:0]                 rd_cpl_ch,
    output wire [4:0]                 rd_cpl_len,     // beats
    output wire [MAX_BURST*TAG_W-1:0] rd_cpl_tags,    // beat i at [i*TAG_W +: TAG_W]
    output wire                       wr_cpl_valid,
    output wire [1:0]                 wr_cpl_ch,
    output wire [4:0]                 wr_cpl_len,
    output wire [MAX_BURST*TAG_W-1:0] wr_cpl_tags,

    // ---------------- read data return ----------------
    output wire                       rd_data_valid,
    output wire [1:0]                 rd_data_ch,
    output wire [DATA_W-1:0]          rd_data,
    output wire                       rd_data_last,

    // ---------------- status ----------------
    output reg  [1:0]                 err_status      // {id_err, resp_err}
);

    localparam [2:0] S_IDLE = 3'd0, S_GATHER = 3'd1, S_AR = 3'd2, S_AW = 3'd3, S_W = 3'd4;
    localparam integer TRK_W = 2 + 5 + MAX_BURST*TAG_W;
    localparam integer IW    = (MAX_BURST > 1) ? $clog2(MAX_BURST) : 1;   // beat index width
    localparam integer OW    = $clog2(MAX_OUT) + 1;                        // tracker count width
    localparam [4:0]    MB5      = MAX_BURST[4:0];
    localparam [OW-1:0] MOUT     = MAX_OUT[OW-1:0];
    localparam [OW-1:0] MOUT_M1  = MOUT - 1'b1;

    // synthesis translate_off
    initial if (MAX_BURST > 16 || MAX_BURST < 1)
        $error("axi3_dma_master: MAX_BURST must be 1..16 for AXI3");
    // synthesis translate_on

    // ---------------------------------------------------------------
    // Burst buffer
    // ---------------------------------------------------------------
    reg  [2:0]                 state;
    reg  [1:0]                 ch;
    reg                        dir;           // 1 = write
    reg  [ADDR_W-1:0]          base;
    reg  [ADDR_W:0]            next_addr_r;   // address the next gathered beat must have
    reg  [4:0]                 len;           // beats gathered
    reg  [3:0]                 beat;          // W beat index
    reg  [DATA_W-1:0]          bdata [0:MAX_BURST-1];
    reg  [MAX_BURST*TAG_W-1:0] btags;

    // Per-channel vectors padded to 4 entries so every 2-bit channel index
    // is in range (channel 3 does not exist: empty, never selected).
    wire [3:0]          empty4     = {1'b1, empty};
    wire [3:0]          head_wr4   = {1'b0, head_wr};
    wire [4*ADDR_W-1:0] head_addr4 = {{ADDR_W{1'b0}}, head_addr};
    wire [4*DATA_W-1:0] head_data4 = {{DATA_W{1'b0}}, head_data};
    wire [4*TAG_W-1:0]  head_tag4  = {{TAG_W{1'b0}},  head_tag};

    // Head of the channel being gathered
    wire              h_wr   = head_wr4[ch];
    wire [ADDR_W-1:0] h_addr = head_addr4[ch*ADDR_W +: ADDR_W];
    wire [DATA_W-1:0] h_data = head_data4[ch*DATA_W +: DATA_W];
    wire [TAG_W-1:0]  h_tag  = head_tag4 [ch*TAG_W  +: TAG_W];

    // AxLEN encoding (beats - 1); len is 0 only while idle, guard anyway
    wire [4:0] len_m1 = (len == 5'd0) ? 5'd0 : len - 5'd1;

    // Each channel's head address + 4, computed in parallel (one bit wider so
    // it cannot wrap). The expected next address is REGISTERED from these,
    // so the gather check below is a plain equality compare. (Timing: Genus
    // fused 'h_addr == last + 4' into one slow add-compare tree on the
    // critical path FIFO head -> gather check -> AR issue -> grant.)
    wire [ADDR_W:0] head_p4 [0:3];
    genvar gc;
    generate
        for (gc = 0; gc < 4; gc = gc + 1) begin : g_hp4
            assign head_p4[gc] = {1'b0, head_addr4[gc*ADDR_W +: ADDR_W]}
                               + {{(ADDR_W-2){1'b0}}, 3'd4};
        end
    endgenerate

    wire extend_ok = (state == S_GATHER) && (len < MB5) && !empty4[ch] &&
                     (h_wr == dir) && ({1'b0, h_addr} == next_addr_r) &&
                     (h_addr[11:0] != 12'd0);

    // ---------------------------------------------------------------
    // Trackers (in-order outstanding bursts)
    // ---------------------------------------------------------------
    wire [TRK_W-1:0]          rd_trk_head, wr_trk_head;
    wire                      rd_trk_empty, wr_trk_empty;
    wire [OW-1:0]             rd_cnt, wr_cnt;

    // ---------------------------------------------------------------
    // Channel handshakes
    // ---------------------------------------------------------------
    assign arvalid = (state == S_GATHER && !extend_ok && !dir) || (state == S_AR);
    assign awvalid = (state == S_GATHER && !extend_ok &&  dir) || (state == S_AW);
    assign wvalid  = (state == S_W);

    wire ar_hs = arvalid && arready;
    wire aw_hs = awvalid && awready;
    wire r_hs  = rvalid  && rready;
    wire b_hs  = bvalid  && bready;

    assign arid    = ch;
    assign araddr  = base;
    assign arlen   = len_m1[3:0];
    assign arsize  = 3'b010;            // 4 bytes per beat
    assign arburst = 2'b01;             // INCR

    assign awid    = ch;
    assign awaddr  = base;
    assign awlen   = len_m1[3:0];
    assign awsize  = 3'b010;
    assign awburst = 2'b01;

    assign wid     = ch;
    assign wdata   = bdata[beat[IW-1:0]];
    assign wstrb   = {DATA_W/8{1'b1}};
    assign wlast   = ({1'b0, beat} == len_m1);

    assign rready  = 1'b1;
    assign bready  = 1'b1;

    // New grant can be taken when idle, or in the same cycle a read burst
    // is handed off (tracker must have room for both).
    assign accept_ready = (((state == S_IDLE) && (rd_cnt < MOUT)) ||
                           (ar_hs && (rd_cnt < MOUT_M1))) && (wr_cnt < MOUT);

    wire accept = accept_ready && (grant != 2'd3);

    // One-hot pop of the channel being gathered (decode, no variable shift)
    assign pop = {3{extend_ok}} & {(ch == 2'd2), (ch == 2'd1), (ch == 2'd0)};

    // Tag vector for a new burst: beat 0 = popped head, other beats zero
    // (single continuous assignment; generate handles MAX_BURST = 1)
    wire [TAG_W-1:0]           grant_tag = head_tag4[grant*TAG_W +: TAG_W];
    wire [MAX_BURST*TAG_W-1:0] first_tags;
    generate
        if (MAX_BURST > 1) begin : g_ftags
            assign first_tags = {{((MAX_BURST-1)*TAG_W){1'b0}}, grant_tag};
        end else begin : g_ftag1
            assign first_tags = grant_tag;
        end
    endgenerate

    // ---------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            ch    <= 2'd0;
            dir   <= 1'b0;
            base  <= '0;
            next_addr_r <= '0;
            len   <= 5'd0;
            beat  <= 4'd0;
            btags <= '0;
            for (i = 0; i < MAX_BURST; i = i + 1) bdata[i] <= '0;
        end else if (accept) begin
            // Start a new burst with the head the arbiter just popped
            ch       <= grant;
            dir      <= head_wr4[grant];
            base     <= head_addr4[grant*ADDR_W +: ADDR_W];
            next_addr_r <= head_p4[grant];
            bdata[0] <= head_data4[grant*DATA_W +: DATA_W];
            btags    <= first_tags;
            len      <= 5'd1;
            beat     <= 4'd0;
            state    <= S_GATHER;
        end else begin
            case (state)
                S_GATHER: begin
                    if (extend_ok) begin
                        bdata[len[IW-1:0]]       <= h_data;
                        btags[len[IW-1:0]*TAG_W +: TAG_W] <= h_tag;
                        len                      <= len + 5'd1;
                        next_addr_r              <= head_p4[ch];
                    end else if (!dir) begin
                        state <= arready ? S_IDLE : S_AR;
                    end else begin
                        state <= awready ? S_W : S_AW;
                        beat  <= 4'd0;
                    end
                end
                S_AR: if (arready) state <= S_IDLE;
                S_AW: if (awready) begin state <= S_W; beat <= 4'd0; end
                S_W:  if (wready) begin
                          if (wlast) state <= S_IDLE;
                          else       beat  <= beat + 4'd1;
                      end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Tracker FIFOs (reuse request_fifo; 'head' is first-word fall-through)
    // ---------------------------------------------------------------
    request_fifo #(.DATA_WIDTH(TRK_W), .DEPTH(MAX_OUT), .ALMOST_FULL_THRESH(MAX_OUT)) rd_trk (
        .clk(clk), .reset(reset),
        .wr_en(ar_hs), .din({ch, len, btags}),
        .rd_en(r_hs && rlast), .dout(), .head(rd_trk_head),
        .full(), .empty(rd_trk_empty), .almost_full(), .count(rd_cnt));

    request_fifo #(.DATA_WIDTH(TRK_W), .DEPTH(MAX_OUT), .ALMOST_FULL_THRESH(MAX_OUT)) wr_trk (
        .clk(clk), .reset(reset),
        .wr_en(aw_hs), .din({ch, len, btags}),
        .rd_en(b_hs), .dout(), .head(wr_trk_head),
        .full(), .empty(wr_trk_empty), .almost_full(), .count(wr_cnt));

    assign rd_cpl_valid = r_hs && rlast && !rd_trk_empty;
    assign {rd_cpl_ch, rd_cpl_len, rd_cpl_tags} = rd_trk_head;
    assign wr_cpl_valid = b_hs && !wr_trk_empty;
    assign {wr_cpl_ch, wr_cpl_len, wr_cpl_tags} = wr_trk_head;

    // ---------------------------------------------------------------
    // Read data return and response checking
    // ---------------------------------------------------------------
    assign rd_data_valid = r_hs;
    assign rd_data_ch    = rid;
    assign rd_data       = rdata;
    assign rd_data_last  = rlast;

    wire r_id_bad = r_hs && (rd_trk_empty || (rid != rd_cpl_ch));
    wire b_id_bad = b_hs && (wr_trk_empty || (bid != wr_cpl_ch));

    always @(posedge clk) begin
        if (reset)
            err_status <= 2'b00;
        else begin
            if ((r_hs && rresp != 2'b00) || (b_hs && bresp != 2'b00)) err_status[0] <= 1'b1;
            if (r_id_bad || b_id_bad)                                  err_status[1] <= 1'b1;
        end
    end

endmodule
