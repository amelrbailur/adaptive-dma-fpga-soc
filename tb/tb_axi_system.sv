`timescale 1ns/1ps
// ============================================================================
// tb_axi_system : step-3 end-to-end testbench
//
//   3 accelerator traffic generators -> adaptive_dma_top (FIFOs, monitor,
//   arbiter, AXI3 burst DMA) -> axi3_mem_model (DRAM-like slave)
//
//   ARB_TYPE : 0 fixed, 1 round robin, 2 adaptive v1, 3 adaptive v2
//   SCENARIO : 0 HEAVY      traffic as step 2, DRAM LAT=10, T_MISS=4
//              1 BALANCED   traffic as step 2, same DRAM
//              2 LIGHT      traffic as step 2, same DRAM
//              3 SLOW_DRAM  BALANCED traffic, LAT=20, T_MISS=10
//              4 LOW        ~0.36 beats/cycle demand, below DRAM capacity
//              5 CONTIG     BALANCED load, contiguous access orders:
//                           FIR writes outputs in blocks of 4, MATMUL reads
//                           whole A rows, SPARSE reads 4 col_idx / 4 values
//                           per row (coverage scenario: write bursts and
//                           gathering on every channel)
//   MAX_BURST: longest AXI burst the DMA may form (1 disables bursting)
//
// Metrics
//   throughput  : completed beats per cycle (RLAST / BRESP seen)
//   latency     : request READY at accelerator -> its burst completes on AXI
//                 (avg, p99, max; max also counts requests still queued)
//   fairness    : Jain index over completed / demand cycles per channel
//   missed      : most grants given to other channels while this channel
//                 had a request waiting (starvation in grant units)
//   row hits    : DRAM row-buffer hit rate seen by the memory model
//   burst       : average beats per AXI burst
//
// Checks: FIFO scoreboard (order/data), AXI3 protocol checker, every popped
// request completes by the end of the drain, missed-grant bound for round
// robin (<= 2) and adaptive v2 (<= WAIT_OVERRIDE + 3).
// ============================================================================
module tb_axi_system;

    parameter integer ARB_TYPE   = 3;
    parameter integer SCENARIO   = 0;
    parameter integer SIM_CYCLES = 5000;
    parameter integer MAX_BURST  = 4;
    parameter integer HOLD_MAX   = 4;
    parameter integer MAX_OUT    = 8;     // outstanding bursts per direction
    parameter integer BP         = 0;     // 1 = random AXI backpressure from memory
    parameter integer ERR        = 0;     // 1 = SLVERR, 2 = wrong RID, 3 = wrong BID
    parameter integer SOLO       = 0;     // 1 = only FIR issues requests (coverage:
                                          //     long single-channel grant runs)
    parameter         COV_TEST   = "run"; // name used in functional coverage output

    localparam integer DEPTH         = 16;
    localparam integer AF_THRESH     = 12;
    localparam integer WAIT_OVERRIDE = 12;

    localparam integer FIR_GAP = (SCENARIO == 0) ? 0 : (SCENARIO == 2) ? 3  : (SCENARIO == 4) ? 7  : 2;
    localparam integer FIR_BLK = (SCENARIO == 5) ? 4 : 1;
    localparam integer CONTIG  = (SCENARIO == 5) ? 1 : 0;
    localparam integer MM_IDLE = (SCENARIO == 0) ? 4 : (SCENARIO == 2) ? 12 : (SCENARIO == 4) ? 28 : 8;
    localparam integer SP_IDLE = (SCENARIO == 2) ? 8 : (SCENARIO == 4) ? 16 : 4;
    localparam integer MEM_LAT = (SCENARIO == 3) ? 20 : 10;
    localparam integer MEM_MISS= (SCENARIO == 3) ? 10 : 4;

    localparam integer TSW = 16;
    localparam integer PW  = 65;
    localparam integer CW  = $clog2(DEPTH) + 1;
    localparam integer HB  = 1024;
    localparam integer MISS_BOUND = (ARB_TYPE == 1) ? 2 : (ARB_TYPE == 3) ? WAIT_OVERRIDE + 3 : 1 << 30;

    reg clk, reset;
    reg [TSW-1:0] now;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    always @(posedge clk) if (reset) now <= '0; else now <= now + 1'b1;

    // ---------------- generators ----------------
    wire        req1, req2, req3, wr1, wr2, wr3, stall1, stall2, stall3;
    wire [31:0] addr1, addr2, addr3, data1, data2, data3;
    wire        pause1, pause2, pause3, acc1, acc2, acc3;
    reg         stop;      // holds the generators after the measurement window

    tg_fir    #(.ISSUE_GAP(FIR_GAP), .OUT_BLOCK(FIR_BLK)) tg1 (.clk(clk), .reset(reset), .fifo_pause(pause1 || stop),
        .req(req1), .wr_en(wr1), .addr(addr1), .data(data1), .stall(stall1));
    tg_matmul #(.IDLE_CYCLES(MM_IDLE), .ROW_FIRST(CONTIG)) tg2 (.clk(clk), .reset(reset), .fifo_pause(pause2 || stop || SOLO),
        .req(req2), .wr_en(wr2), .addr(addr2), .data(data2), .stall(stall2));
    tg_sparse #(.MAX_IDLE(SP_IDLE), .ROW_BLOCK(CONTIG)) tg3 (.clk(clk), .reset(reset), .fifo_pause(pause3 || stop || SOLO),
        .req(req3), .wr_en(wr3), .addr(addr3), .data(data3), .stall(stall3));

    // Timestamp = cycle the request became ready (now minus stall cycles)
    reg  [TSW-1:0] srun1, srun2, srun3;
    wire [TSW-1:0] ts1 = now - srun1, ts2 = now - srun2, ts3 = now - srun3;
    always @(posedge clk) begin
        if (reset) begin srun1 <= 0; srun2 <= 0; srun3 <= 0; end
        else begin
            srun1 <= acc1 ? (stall1 ? 1 : 0) : (stall1 ? srun1 + 1'b1 : srun1);
            srun2 <= acc2 ? (stall2 ? 1 : 0) : (stall2 ? srun2 + 1'b1 : srun2);
            srun3 <= acc3 ? (stall3 ? 1 : 0) : (stall3 ? srun3 + 1'b1 : srun3);
        end
    end

    // ---------------- DUT ----------------
    wire [1:0]  awid, wid, bid, arid, rid, bresp, rresp, awburst, arburst, grant;
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire [3:0]  awlen, arlen, wstrb;
    wire [2:0]  awsize, arsize;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rlast, rvalid, rready;
    wire        rd_cpl_valid, wr_cpl_valid;
    wire [1:0]  rd_cpl_ch, wr_cpl_ch;
    wire [4:0]  rd_cpl_len, wr_cpl_len;
    wire [MAX_BURST*TSW-1:0] rd_cpl_tags, wr_cpl_tags;

    adaptive_dma_top #(.ARB_TYPE(ARB_TYPE), .TAG_W(TSW), .DEPTH(DEPTH), .AF_THRESH(AF_THRESH),
                       .WAIT_OVERRIDE(WAIT_OVERRIDE), .HOLD_MAX(HOLD_MAX),
                       .MAX_BURST(MAX_BURST), .MAX_OUT(MAX_OUT)) dut (
        .clk(clk), .reset(reset),
        .req1_valid(req1), .req2_valid(req2), .req3_valid(req3),
        .req1_wr(wr1), .req2_wr(wr2), .req3_wr(wr3),
        .req1_addr(addr1), .req2_addr(addr2), .req3_addr(addr3),
        .req1_data(data1), .req2_data(data2), .req3_data(data3),
        .req1_tag(ts1), .req2_tag(ts2), .req3_tag(ts3),
        .req1_stall(stall1), .req2_stall(stall2), .req3_stall(stall3),
        .pause1(pause1), .pause2(pause2), .pause3(pause3),
        .accept1(acc1), .accept2(acc2), .accept3(acc3),
        .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awvalid(awvalid), .m_awready(awready),
        .m_wid(wid), .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast),
        .m_wvalid(wvalid), .m_wready(wready),
        .m_bid(bid), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
        .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arvalid(arvalid), .m_arready(arready),
        .m_rid(rid), .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast),
        .m_rvalid(rvalid), .m_rready(rready),
        .rd_cpl_valid(rd_cpl_valid), .rd_cpl_ch(rd_cpl_ch), .rd_cpl_len(rd_cpl_len),
        .rd_cpl_tags(rd_cpl_tags),
        .wr_cpl_valid(wr_cpl_valid), .wr_cpl_ch(wr_cpl_ch), .wr_cpl_len(wr_cpl_len),
        .wr_cpl_tags(wr_cpl_tags),
        .rd_data_valid(), .rd_data_ch(), .rd_data(), .rd_data_last(),
        .err_status(), .grant(grant));

    // ---------------- functional coverage (portable counters) ----------------
    func_cov #(.ARB_TYPE(ARB_TYPE), .HOLD_MAX(HOLD_MAX)) fcov (.clk(clk), .reset(reset));

    axi3_mem_model #(.LAT(MEM_LAT), .T_MISS(MEM_MISS), .BP(BP), .ERR(ERR)) mem (
        .clk(clk), .reset(reset),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));

    axi3_checker chk (
        .clk(clk), .reset(reset),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rlast(rlast), .rvalid(rvalid), .rready(rready));

    // ---------------- per-channel statistics ----------------
    `define CHAN_STATS(N, C, NM) \
    chan_stats3 #(.PW(PW), .TSW(TSW), .CW(CW), .HB(HB), .MAX_BURST(MAX_BURST), \
                  .CH(C), .MISS_BOUND(MISS_BOUND), .NAME(NM)) cs``N ( \
        .clk(clk), .reset(reset), .now(now), \
        .push(acc``N), .push_ts(ts``N), .push_payload({wr``N, addr``N, data``N}), \
        .pop(dut.fifo``N.rd_en && !dut.fifo``N.empty), .dout(dut.fifo``N.dout), \
        .empty(dut.fifo``N.empty), .stall(stall``N), .grant(grant), \
        .ar_hs(arvalid && arready), .arid(arid), .arlen(arlen), \
        .aw_hs(awvalid && awready), .awid(awid), .awlen(awlen), \
        .rd_cpl(rd_cpl_valid), .rd_ch(rd_cpl_ch), .rd_len(rd_cpl_len), .rd_tags(rd_cpl_tags), \
        .wr_cpl(wr_cpl_valid), .wr_ch(wr_cpl_ch), .wr_len(wr_cpl_len), .wr_tags(wr_cpl_tags));

    `CHAN_STATS(1, 0, "FIR   ")
    `CHAN_STATS(2, 1, "MATMUL")
    `CHAN_STATS(3, 2, "SPARSE")

    // ---------------- run and report ----------------
    reg [8*10:1] scen_name, arb_name;
    integer cyc, i, cum, p99_all, max_all, drain;
    integer total_served, total_errors, total_stall, total_lat, total_bursts, total_beats;
    integer h_all [0:HB-1];
    real    x1, x2, x3, jain, thr, rowhit, avgburst;

    function real ratio(input integer s, input integer o);
        ratio = (o > 0) ? (1.0 * s) / o : 1.0;
    endfunction

    function integer max3(input integer a, input integer b, input integer c);
        max3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
    endfunction

    initial begin
        case (SCENARIO)
            0: scen_name = "HEAVY";
            1: scen_name = "BALANCED";
            2: scen_name = "LIGHT";
            3: scen_name = "SLOW_DRAM";
            4: scen_name = "LOW";
            default: scen_name = "CONTIG";
        endcase
        case (ARB_TYPE)
            0: arb_name = "FIXED";
            1: arb_name = "RR";
            2: arb_name = "ADAPTIVE";
            default: arb_name = "ADAPT_V2";
        endcase

        reset = 1'b1;
        stop  = 1'b0;
        repeat (4) @(negedge clk);
        reset = 1'b0;

        for (cyc = 1; cyc <= SIM_CYCLES; cyc = cyc + 1) @(negedge clk);

        // Snapshot the measurement window, then let in-flight bursts drain
        // (generators keep running; only completions inside the window count).
        cs1.freeze = 1; cs2.freeze = 1; cs3.freeze = 1;
        total_served = cs1.served + cs2.served + cs3.served;
        total_lat    = cs1.lat_sum + cs2.lat_sum + cs3.lat_sum;
        total_stall  = cs1.stall_cycles + cs2.stall_cycles + cs3.stall_cycles;
        total_bursts = cs1.bursts + cs2.bursts + cs3.bursts;
        total_beats  = cs1.beats + cs2.beats + cs3.beats;
        for (i = 0; i < HB; i = i + 1) h_all[i] = cs1.hist[i] + cs2.hist[i] + cs3.hist[i];
        cum = 0; p99_all = 0;
        for (i = 0; i < HB; i = i + 1) begin
            cum = cum + h_all[i];
            if (p99_all == 0 && total_served > 0 && cum * 100 >= total_served * 99) p99_all = i;
        end
        max_all = max3(cs1.max_lat_incl_pending(now), cs2.max_lat_incl_pending(now),
                       cs3.max_lat_incl_pending(now));
        x1   = ratio(cs1.served, cs1.offered);
        x2   = ratio(cs2.served, cs2.offered);
        x3   = ratio(cs3.served, cs3.offered);
        jain = (x1 + x2 + x3) * (x1 + x2 + x3) / (3.0 * (x1*x1 + x2*x2 + x3*x3));
        thr  = (1.0 * total_served) / SIM_CYCLES;
        rowhit   = (mem.row_hits + mem.row_misses > 0)
                 ? (1.0 * mem.row_hits) / (mem.row_hits + mem.row_misses) : 0.0;
        avgburst = (total_bursts > 0) ? (1.0 * total_beats) / total_bursts : 0.0;

        // Drain: hold the generators, let the DMA empty the FIFOs and finish
        // every in-flight burst, then check nothing was lost inside the DMA.
        stop  = 1'b1;
        drain = 0;
        while (drain < 20000 &&
               !(dut.empty1 && dut.empty2 && dut.empty3 &&
                 cs1.popped == cs1.completed_all && cs2.popped == cs2.completed_all &&
                 cs3.popped == cs3.completed_all)) begin
            @(negedge clk); drain = drain + 1;
        end
        cs1.check_drained(); cs2.check_drained(); cs3.check_drained();

        // err_status must match what was injected (none in normal runs).
        // An injected wrong RID is also, correctly, flagged once by the
        // AXI checker (rule R7); that one is expected, not an error.
        if (dut.err_status !== ((ERR == 1) ? 2'b01 : (ERR >= 2) ? 2'b10 : 2'b00)) begin
            $display("ERROR: DMA err_status = %b, expected %b", dut.err_status,
                     (ERR == 1) ? 2'b01 : (ERR >= 2) ? 2'b10 : 2'b00);
            chk.errors = chk.errors + 1;
        end else if (ERR != 0) begin
            $display("Injected error detected by DMA: err_status = %b (as expected)", dut.err_status);
        end
        if (ERR == 2) chk.errors = chk.errors - 1;
        total_errors = cs1.errors + cs2.errors + cs3.errors + chk.errors;

        $display("");
        $display("====================================================================================");
        $display("  %0s arbiter | scenario %0s | %0d cycles | DRAM lat %0d, row miss +%0d | max burst %0d",
                 arb_name, scen_name, SIM_CYCLES, MEM_LAT, MEM_MISS, MAX_BURST);
        $display("====================================================================================");
        $display("Channel | Done   | Demand | Done/Dem | Lat avg | Lat p99 | Lat max* | MaxMissed | Stall | Burst");
        $display("--------+--------+--------+----------+---------+---------+----------+-----------+-------+------");
        cs1.report(now); cs2.report(now); cs3.report(now);
        $display("------------------------------------------------------------------------------------");
        $display("Throughput : %0.3f beats/cycle completed", thr);
        $display("Latency    : avg %0d, p99 %0d, max* %0d cycles (ready at accelerator -> AXI completion)",
                 (total_served > 0) ? total_lat / total_served : 0, p99_all, max_all);
        $display("Fairness   : Jain %0.3f", jain);
        $display("DRAM       : row-hit rate %0.1f%%, avg burst %0.2f beats", 100.0 * rowhit, avgburst);
        $display("Stalls     : %0d generator stall cycles", total_stall);
        $display("Checks     : AXI protocol errors %0d, scoreboard/bound/drain errors %0d",
                 chk.errors, cs1.errors + cs2.errors + cs3.errors);
        $display("* max includes requests still waiting in a FIFO at the end of the window");
        if (total_errors == 0) $display("RESULT: PASS");
        else                   $display("RESULT: FAIL (%0d errors)", total_errors);

        cs1.csv(scen_name, arb_name, now);
        cs2.csv(scen_name, arb_name, now);
        cs3.csv(scen_name, arb_name, now);
        fcov.report(COV_TEST);
        $display("SUM,%0s,%0s,%0.3f,%0.3f,%0d,%0d,%0d,%0d,%0d,%0.3f,%0.2f",
                 scen_name, arb_name, thr, jain,
                 (total_served > 0) ? total_lat / total_served : 0, p99_all, max_all,
                 total_stall, total_errors, rowhit, avgburst);
        $finish;
    end

endmodule


// ============================================================================
// chan_stats3 : scoreboard + end-to-end statistics for one channel
// ============================================================================
module chan_stats3 #(
    parameter integer PW         = 65,
    parameter integer TSW        = 16,
    parameter integer CW         = 5,
    parameter integer HB         = 1024,
    parameter integer MAX_BURST  = 4,
    parameter integer CH         = 0,
    parameter integer MISS_BOUND = 1 << 30,
    parameter integer SBD        = 64,
    parameter         NAME       = "CH    "
)(
    input wire                       clk,
    input wire                       reset,
    input wire [TSW-1:0]             now,
    input wire                       push,
    input wire [TSW-1:0]             push_ts,
    input wire [PW-1:0]              push_payload,
    input wire                       pop,
    input wire [TSW+PW-1:0]          dout,
    input wire                       empty,
    input wire                       stall,
    input wire [1:0]                 grant,
    input wire                       ar_hs,
    input wire [1:0]                 arid,
    input wire [3:0]                 arlen,
    input wire                       aw_hs,
    input wire [1:0]                 awid,
    input wire [3:0]                 awlen,
    input wire                       rd_cpl,
    input wire [1:0]                 rd_ch,
    input wire [4:0]                 rd_len,
    input wire [MAX_BURST*TSW-1:0]   rd_tags,
    input wire                       wr_cpl,
    input wire [1:0]                 wr_ch,
    input wire [4:0]                 wr_len,
    input wire [MAX_BURST*TSW-1:0]   wr_tags
);
    reg [PW-1:0]  sb     [0:SBD-1];
    reg [TSW-1:0] push_t [0:SBD-1];
    integer sb_w, sb_r;

    integer hist [0:HB-1];
    integer served, offered, lat_sum, lat_max, errors, stall_cycles;
    integer popped, completed_all, bursts, beats, missed, max_missed, i, j;
    reg     pop_d, freeze;
    reg [TSW-1:0] lat;

    task record(input [TSW-1:0] tag);
        begin
            completed_all = completed_all + 1;
            if (!freeze) begin
                lat     = now - tag;
                served  = served + 1;
                lat_sum = lat_sum + lat;
                if (lat > lat_max) lat_max = lat;
                hist[(lat >= HB) ? HB-1 : lat] = hist[(lat >= HB) ? HB-1 : lat] + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            sb_w = 0; sb_r = 0; served = 0; offered = 0; lat_sum = 0; lat_max = 0;
            errors = 0; stall_cycles = 0; popped = 0; completed_all = 0;
            bursts = 0; beats = 0; missed = 0; max_missed = 0;
            pop_d = 0; freeze = 0;
            for (i = 0; i < HB; i = i + 1) hist[i] = 0;
        end else begin
            // FIFO scoreboard: entry popped last edge is now on dout
            if (pop_d) begin
                if (sb_r == sb_w) begin
                    $display("ERROR [%s] @%0t: pop with empty scoreboard", NAME, $time);
                    errors = errors + 1;
                end else begin
                    if (dout[PW-1:0] !== sb[sb_r % SBD]) begin
                        $display("ERROR [%s] @%0t: FIFO data mismatch", NAME, $time);
                        errors = errors + 1;
                    end
                    sb_r = sb_r + 1;
                end
            end
            if (push) begin
                sb[sb_w % SBD]     = push_payload;
                push_t[sb_w % SBD] = push_ts;
                sb_w = sb_w + 1;
            end
            if (pop) popped = popped + 1;
            pop_d = pop;

            // Completions (read and write can complete in the same cycle)
            if (rd_cpl && rd_ch == CH)
                for (j = 0; j < rd_len; j = j + 1) record(rd_tags[j*TSW +: TSW]);
            if (wr_cpl && wr_ch == CH)
                for (j = 0; j < wr_len; j = j + 1) record(wr_tags[j*TSW +: TSW]);

            if (!freeze) begin
                // Bursts issued for this channel
                if (ar_hs && arid == CH) begin bursts = bursts + 1; beats = beats + arlen + 1; end
                if (aw_hs && awid == CH) begin bursts = bursts + 1; beats = beats + awlen + 1; end

                // Missed grants while waiting
                if (empty || grant == CH) missed = 0;
                else if (grant != 2'd3)   missed = missed + 1;
                if (missed > max_missed) max_missed = missed;
                if (missed > MISS_BOUND) begin
                    $display("ERROR [%s] @%0t: missed %0d grants (bound %0d)", NAME, $time, missed, MISS_BOUND);
                    errors = errors + 1;
                end

                if (push || stall) offered = offered + 1;
                if (stall)         stall_cycles = stall_cycles + 1;
            end
        end
    end

    function integer max_lat_incl_pending(input [TSW-1:0] t);
        reg [TSW-1:0] age;
        begin
            max_lat_incl_pending = lat_max;
            if (sb_r != sb_w) begin
                age = t - push_t[sb_r % SBD];
                if (age > max_lat_incl_pending) max_lat_incl_pending = age;
            end
        end
    endfunction

    function integer p99(input dummy);
        integer k, cum;
        begin
            p99 = 0; cum = 0;
            for (k = 0; k < HB; k = k + 1) begin
                cum = cum + hist[k];
                if (p99 == 0 && served > 0 && cum * 100 >= served * 99) p99 = k;
            end
        end
    endfunction

    // After the drain, everything popped from the FIFO must have completed
    task check_drained;
        begin
            if (completed_all != popped) begin
                $display("ERROR [%s]: %0d requests popped but %0d completed after drain",
                         NAME, popped, completed_all);
                errors = errors + 1;
            end
        end
    endtask

    task report(input [TSW-1:0] t);
        begin
            $display("%s  | %6d | %6d | %7d%% | %7d | %7d | %8d | %9d | %5d | %5.2f",
                     NAME, served, offered, (offered > 0) ? served * 100 / offered : 0,
                     (served > 0) ? lat_sum / served : 0, p99(1'b0),
                     max_lat_incl_pending(t), max_missed, stall_cycles,
                     (bursts > 0) ? (1.0 * beats) / bursts : 0.0);
        end
    endtask

    task csv(input [8*10:1] scen, input [8*10:1] arb, input [TSW-1:0] t);
        begin
            $display("CSV,%0s,%0s,%0s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                     scen, arb, NAME, served, offered,
                     (served > 0) ? lat_sum / served : 0, p99(1'b0),
                     max_lat_incl_pending(t), max_missed, stall_cycles, errors);
        end
    endtask

endmodule
