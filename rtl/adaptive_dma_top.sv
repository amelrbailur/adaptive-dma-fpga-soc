`timescale 1ns/1ps
// ============================================================================
// adaptive_dma_top : the synthesizable DMA subsystem (the DUT for Genus/Innovus)
//
//   accelerator request ports (x3) -> request FIFOs -> arbiter -> AXI3 DMA
//                                  \-> traffic monitor --^
//
//   Per channel n:
//     reqN_valid/wr/addr/data/tag : request from accelerator n (tag is an
//                                   opaque per-request field returned on
//                                   completion; the testbench puts a
//                                   timestamp there, hardware can set TAG_W=1)
//     reqN_stall                  : accelerator has a request but is paused
//     pauseN                      : backpressure to accelerator n (almost full)
//
//   ARB_TYPE: 0 fixed, 1 round robin, 2 adaptive v1, 3 adaptive v2
//   (an AXI-Lite mode register replaces this parameter in step 4)
// ============================================================================
module adaptive_dma_top #(
    parameter integer ARB_TYPE      = 3,
    parameter integer ADDR_W        = 32,
    parameter integer DATA_W        = 32,
    parameter integer TAG_W         = 16,
    parameter integer DEPTH         = 16,
    parameter integer AF_THRESH     = 12,
    parameter integer WAIT_OVERRIDE = 12,
    parameter integer HOLD_MAX      = 4,
    parameter integer MAX_BURST     = 4,
    parameter integer MAX_OUT       = 8
)(
    input  wire                       clk,
    input  wire                       reset,

    // ---------------- accelerator request ports ----------------
    input  wire                       req1_valid, req2_valid, req3_valid,
    input  wire                       req1_wr,    req2_wr,    req3_wr,
    input  wire [ADDR_W-1:0]          req1_addr,  req2_addr,  req3_addr,
    input  wire [DATA_W-1:0]          req1_data,  req2_data,  req3_data,
    input  wire [TAG_W-1:0]           req1_tag,   req2_tag,   req3_tag,
    input  wire                       req1_stall, req2_stall, req3_stall,
    output wire                       pause1,     pause2,     pause3,
    output wire                       accept1,    accept2,    accept3,

    // ---------------- AXI3 master ----------------
    output wire [1:0]                 m_awid,
    output wire [ADDR_W-1:0]          m_awaddr,
    output wire [3:0]                 m_awlen,
    output wire [2:0]                 m_awsize,
    output wire [1:0]                 m_awburst,
    output wire                       m_awvalid,
    input  wire                       m_awready,
    output wire [1:0]                 m_wid,
    output wire [DATA_W-1:0]          m_wdata,
    output wire [DATA_W/8-1:0]        m_wstrb,
    output wire                       m_wlast,
    output wire                       m_wvalid,
    input  wire                       m_wready,
    input  wire [1:0]                 m_bid,
    input  wire [1:0]                 m_bresp,
    input  wire                       m_bvalid,
    output wire                       m_bready,
    output wire [1:0]                 m_arid,
    output wire [ADDR_W-1:0]          m_araddr,
    output wire [3:0]                 m_arlen,
    output wire [2:0]                 m_arsize,
    output wire [1:0]                 m_arburst,
    output wire                       m_arvalid,
    input  wire                       m_arready,
    input  wire [1:0]                 m_rid,
    input  wire [DATA_W-1:0]          m_rdata,
    input  wire [1:0]                 m_rresp,
    input  wire                       m_rlast,
    input  wire                       m_rvalid,
    output wire                       m_rready,

    // ---------------- completions ----------------
    output wire                       rd_cpl_valid,
    output wire [1:0]                 rd_cpl_ch,
    output wire [4:0]                 rd_cpl_len,
    output wire [MAX_BURST*TAG_W-1:0] rd_cpl_tags,
    output wire                       wr_cpl_valid,
    output wire [1:0]                 wr_cpl_ch,
    output wire [4:0]                 wr_cpl_len,
    output wire [MAX_BURST*TAG_W-1:0] wr_cpl_tags,

    // ---------------- read data return to accelerators ----------------
    output wire                       rd_data_valid,
    output wire [1:0]                 rd_data_ch,     // which accelerator
    output wire [DATA_W-1:0]          rd_data,
    output wire                       rd_data_last,

    // ---------------- status / observability ----------------
    output wire [1:0]                 err_status,     // {id_err, resp_err}, sticky
    output wire [1:0]                 grant
);

    localparam integer FW = TAG_W + 1 + ADDR_W + DATA_W;   // {tag, wr, addr, data}
    localparam integer CW = $clog2(DEPTH) + 1;

    wire [FW-1:0] head1, head2, head3;
    wire          full1, full2, full3, empty1, empty2, empty3, af1, af2, af3;
    wire [CW-1:0] count1, count2, count3;
    wire          ard1, ard2, ard3;            // arbiter pops
    wire [2:0]    dpop;                        // DMA gather pops
    wire          mem_ready;

    assign accept1 = req1_valid && !full1;
    assign accept2 = req2_valid && !full2;
    assign accept3 = req3_valid && !full3;
    assign pause1  = af1;
    assign pause2  = af2;
    assign pause3  = af3;

    // ---------------- request FIFOs ----------------
    request_fifo #(.DATA_WIDTH(FW), .DEPTH(DEPTH), .ALMOST_FULL_THRESH(AF_THRESH)) fifo1 (
        .clk(clk), .reset(reset), .wr_en(accept1),
        .din({req1_tag, req1_wr, req1_addr, req1_data}),
        .rd_en(ard1 || dpop[0]), .dout(), .head(head1),
        .full(full1), .empty(empty1), .almost_full(af1), .count(count1));
    request_fifo #(.DATA_WIDTH(FW), .DEPTH(DEPTH), .ALMOST_FULL_THRESH(AF_THRESH)) fifo2 (
        .clk(clk), .reset(reset), .wr_en(accept2),
        .din({req2_tag, req2_wr, req2_addr, req2_data}),
        .rd_en(ard2 || dpop[1]), .dout(), .head(head2),
        .full(full2), .empty(empty2), .almost_full(af2), .count(count2));
    request_fifo #(.DATA_WIDTH(FW), .DEPTH(DEPTH), .ALMOST_FULL_THRESH(AF_THRESH)) fifo3 (
        .clk(clk), .reset(reset), .wr_en(accept3),
        .din({req3_tag, req3_wr, req3_addr, req3_data}),
        .rd_en(ard3 || dpop[2]), .dout(), .head(head3),
        .full(full3), .empty(empty3), .almost_full(af3), .count(count3));

    // ---------------- traffic monitor ----------------
    wire [3:0] rate1, rate2, rate3, burst1, burst2, burst3;

    traffic_monitor monitor (
        .clk(clk), .reset(reset),
        .accepted_req({accept3, accept2, accept1}),
        .stalled({req3_stall, req2_stall, req1_stall}),
        .arrival_rate1(rate1), .arrival_rate2(rate2), .arrival_rate3(rate3),
        .burst_len1(burst1),   .burst_len2(burst2),   .burst_len3(burst3));

    // ---------------- arbiter ----------------
    arbiter_select #(.ARB_TYPE(ARB_TYPE), .DEPTH(DEPTH), .WAIT_OVERRIDE(WAIT_OVERRIDE),
                     .HOLD_MAX(HOLD_MAX)) arbiter (
        .clk(clk), .reset(reset), .mem_ready(mem_ready),
        .empty1(empty1), .empty2(empty2), .empty3(empty3),
        .fifo_count1(count1), .fifo_count2(count2), .fifo_count3(count3),
        .almost_full1(af1), .almost_full2(af2), .almost_full3(af3),
        .arrival_rate1(rate1), .arrival_rate2(rate2), .arrival_rate3(rate3),
        .burst_len1(burst1), .burst_len2(burst2), .burst_len3(burst3),
        .rd_en1(ard1), .rd_en2(ard2), .rd_en3(ard3), .grant(grant),
        .score1(), .score2(), .score3(),
        .waiting1(), .waiting2(), .waiting3());

    // ---------------- AXI3 DMA master ----------------
    // head layout: {tag, wr, addr, data}
    axi3_dma_master #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .TAG_W(TAG_W),
                      .MAX_BURST(MAX_BURST), .MAX_OUT(MAX_OUT)) dma (
        .clk(clk), .reset(reset),
        .empty({empty3, empty2, empty1}),
        .head_wr  ({head3[ADDR_W+DATA_W], head2[ADDR_W+DATA_W], head1[ADDR_W+DATA_W]}),
        .head_addr({head3[DATA_W +: ADDR_W], head2[DATA_W +: ADDR_W], head1[DATA_W +: ADDR_W]}),
        .head_data({head3[0 +: DATA_W], head2[0 +: DATA_W], head1[0 +: DATA_W]}),
        .head_tag ({head3[FW-1 -: TAG_W], head2[FW-1 -: TAG_W], head1[FW-1 -: TAG_W]}),
        .grant(grant), .accept_ready(mem_ready), .pop(dpop),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize),
        .awburst(m_awburst), .awvalid(m_awvalid), .awready(m_awready),
        .wid(m_wid), .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast),
        .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize),
        .arburst(m_arburst), .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
        .rvalid(m_rvalid), .rready(m_rready),
        .rd_cpl_valid(rd_cpl_valid), .rd_cpl_ch(rd_cpl_ch), .rd_cpl_len(rd_cpl_len),
        .rd_cpl_tags(rd_cpl_tags),
        .wr_cpl_valid(wr_cpl_valid), .wr_cpl_ch(wr_cpl_ch), .wr_cpl_len(wr_cpl_len),
        .wr_cpl_tags(wr_cpl_tags),
        .rd_data_valid(rd_data_valid), .rd_data_ch(rd_data_ch), .rd_data(rd_data),
        .rd_data_last(rd_data_last), .err_status(err_status));

endmodule
