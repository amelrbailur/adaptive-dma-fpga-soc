`timescale 1ns/1ps
// ============================================================================
// tb_arbiter_compare : step-2 comparison testbench
//
// One run = one arbiter (ARB_TYPE) under one traffic scenario (SCENARIO).
// run.sh sweeps all combinations and collects the CSV lines.
//
//   ARB_TYPE : 0 fixed priority, 1 round robin, 2 adaptive v1, 3 adaptive v2
//   SCENARIO : 0 HEAVY      FIR 100%, MATMUL 50% bursty, SPARSE ~33%  (~1.8x oversubscribed)
//              1 BALANCED   FIR 33%,  MATMUL 33%, SPARSE ~33%         (~1.0x, at capacity)
//              2 LIGHT      FIR 25%,  MATMUL 25%, SPARSE ~20%         (~0.7x, under capacity)
//              3 SLOW_MEM   BALANCED traffic, memory at half bandwidth (~2x)
//              4 SWITCH_PEN BALANCED traffic, +2 cycles per channel switch
//
// Metrics (per channel and overall):
//   throughput  : requests dequeued per cycle
//   latency     : cycles from the request being READY at the accelerator to
//                 its grant. Includes time stalled at the source by
//                 backpressure, not just time in the FIFO (otherwise an
//                 arbiter that lets FIFOs fill looks artificially fast).
//                 avg, p99 (histogram), max. Max also includes requests
//                 still waiting at the end, so starvation is visible.
//   fairness    : Jain's index over x_i = served_i / offered_i
//   stalls      : cycles a generator had a request ready but was paused
//
// Checks (any arbiter): scoreboard order/data, no writes into a full FIFO.
// Check (adaptive only): starvation counter stays within its bound.
// ============================================================================
module tb_arbiter_compare;

    parameter integer ARB_TYPE       = 3;
    parameter integer SCENARIO       = 0;
    parameter integer SIM_CYCLES     = 5000;
    parameter integer VERBOSE_CYCLES = 0;

    parameter integer DEPTH         = 16;
    parameter integer AF_THRESH     = 12;
    parameter integer WAIT_OVERRIDE = 12;

    // ADAPT_V2 tuning knobs (ignored by the other arbiters)
    parameter integer HOLD_MAX = 4;
    parameter integer W_OCC    = 4;
    parameter integer W_WAIT   = 3;
    parameter integer W_RATE   = 2;
    parameter integer W_BURST  = 1;

    // ---------------- scenario knobs ----------------
    localparam integer FIR_GAP  = (SCENARIO == 0) ? 0  : (SCENARIO == 2) ? 3  : 2;
    localparam integer MM_IDLE  = (SCENARIO == 0) ? 4  : (SCENARIO == 2) ? 12 : 8;
    localparam integer SP_IDLE  = (SCENARIO == 2) ? 8  : 4;
    localparam integer MEM_SI   = (SCENARIO == 3) ? 2  : 1;
    localparam integer MEM_SP   = (SCENARIO == 4) ? 2  : 0;

    // Starvation bound in cycles. v1 counts cycles; v2 counts missed grants,
    // each of which can take up to MEM_SI + MEM_SP cycles.
    localparam integer WAIT_BOUND = (ARB_TYPE == 3)
                                  ? (WAIT_OVERRIDE + 3) * (MEM_SI + MEM_SP) + 2
                                  : WAIT_OVERRIDE + 3*(MEM_SI + MEM_SP) + 2;

    localparam integer PW  = 65;
    localparam integer TSW = 16;
    localparam integer FW  = PW + TSW;
    localparam integer CW  = $clog2(DEPTH) + 1;
    localparam integer HB  = 1024;           // latency histogram bins

    reg clk, reset;
    reg [TSW-1:0] now;

    wire        req1, req2, req3, wr1, wr2, wr3;
    wire [31:0] addr1, addr2, addr3, data1, data2, data3;
    wire        stall1, stall2, stall3;

    wire [FW-1:0] dout1, dout2, dout3;
    wire          full1, full2, full3, empty1, empty2, empty3, af1, af2, af3;
    wire [CW-1:0] count1, count2, count3;

    wire acc1 = req1 && !full1;
    wire acc2 = req2 && !full2;
    wire acc3 = req3 && !full3;

    wire [3:0] rate1, rate2, rate3, burst1, burst2, burst3;
    wire       rd1, rd2, rd3, mem_ready;
    wire [1:0] grant;
    wire [7:0] score1, score2, score3, wait1, wait2, wait3;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk)
        if (reset) now <= '0;
        else       now <= now + 1'b1;

    // Stall cycles accumulated by the request currently waiting at each
    // generator. Subtracted from 'now' to timestamp a request from when it
    // became ready rather than when the FIFO accepted it.
    reg  [TSW-1:0] srun1, srun2, srun3;
    wire [TSW-1:0] ts1 = now - srun1;
    wire [TSW-1:0] ts2 = now - srun2;
    wire [TSW-1:0] ts3 = now - srun3;

    always @(posedge clk) begin
        if (reset) begin
            srun1 <= '0; srun2 <= '0; srun3 <= '0;
        end else begin
            srun1 <= acc1 ? (stall1 ? 1 : 0) : (stall1 ? srun1 + 1'b1 : srun1);
            srun2 <= acc2 ? (stall2 ? 1 : 0) : (stall2 ? srun2 + 1'b1 : srun2);
            srun3 <= acc3 ? (stall3 ? 1 : 0) : (stall3 ? srun3 + 1'b1 : srun3);
        end
    end

    // ============================================================
    // DUT
    // ============================================================
    tg_fir    #(.ISSUE_GAP(FIR_GAP))  tg1 (.clk(clk), .reset(reset), .fifo_pause(af1),
        .req(req1), .wr_en(wr1), .addr(addr1), .data(data1), .stall(stall1));
    tg_matmul #(.IDLE_CYCLES(MM_IDLE)) tg2 (.clk(clk), .reset(reset), .fifo_pause(af2),
        .req(req2), .wr_en(wr2), .addr(addr2), .data(data2), .stall(stall2));
    tg_sparse #(.MAX_IDLE(SP_IDLE))   tg3 (.clk(clk), .reset(reset), .fifo_pause(af3),
        .req(req3), .wr_en(wr3), .addr(addr3), .data(data3), .stall(stall3));

    request_fifo #(.DATA_WIDTH(FW), .DEPTH(DEPTH), .ALMOST_FULL_THRESH(AF_THRESH)) fifo1 (
        .clk(clk), .reset(reset), .wr_en(acc1), .din({ts1, wr1, addr1, data1}),
        .rd_en(rd1), .dout(dout1), .full(full1), .empty(empty1), .almost_full(af1), .count(count1));
    request_fifo #(.DATA_WIDTH(FW), .DEPTH(DEPTH), .ALMOST_FULL_THRESH(AF_THRESH)) fifo2 (
        .clk(clk), .reset(reset), .wr_en(acc2), .din({ts2, wr2, addr2, data2}),
        .rd_en(rd2), .dout(dout2), .full(full2), .empty(empty2), .almost_full(af2), .count(count2));
    request_fifo #(.DATA_WIDTH(FW), .DEPTH(DEPTH), .ALMOST_FULL_THRESH(AF_THRESH)) fifo3 (
        .clk(clk), .reset(reset), .wr_en(acc3), .din({ts3, wr3, addr3, data3}),
        .rd_en(rd3), .dout(dout3), .full(full3), .empty(empty3), .almost_full(af3), .count(count3));

    traffic_monitor monitor (
        .clk(clk), .reset(reset),
        .accepted_req({acc3, acc2, acc1}), .stalled({stall3, stall2, stall1}),
        .arrival_rate1(rate1), .arrival_rate2(rate2), .arrival_rate3(rate3),
        .burst_len1(burst1),   .burst_len2(burst2),   .burst_len3(burst3));

    arbiter_select #(.ARB_TYPE(ARB_TYPE), .DEPTH(DEPTH), .WAIT_OVERRIDE(WAIT_OVERRIDE),
                     .HOLD_MAX(HOLD_MAX), .W_OCC(W_OCC), .W_WAIT(W_WAIT),
                     .W_RATE(W_RATE), .W_BURST(W_BURST)) arbiter (
        .clk(clk), .reset(reset), .mem_ready(mem_ready),
        .empty1(empty1), .empty2(empty2), .empty3(empty3),
        .fifo_count1(count1), .fifo_count2(count2), .fifo_count3(count3),
        .almost_full1(af1), .almost_full2(af2), .almost_full3(af3),
        .arrival_rate1(rate1), .arrival_rate2(rate2), .arrival_rate3(rate3),
        .burst_len1(burst1), .burst_len2(burst2), .burst_len3(burst3),
        .rd_en1(rd1), .rd_en2(rd2), .rd_en3(rd3), .grant(grant),
        .score1(score1), .score2(score2), .score3(score3),
        .waiting1(wait1), .waiting2(wait2), .waiting3(wait3));

    mem_port_model #(.SERVICE_INTERVAL(MEM_SI), .SWITCH_PENALTY(MEM_SP)) mem (
        .clk(clk), .reset(reset),
        .accept(grant != 2'd3), .accept_ch(grant), .ready(mem_ready));

    // ============================================================
    // Per-channel checkers
    // ============================================================
    chan_stats #(.PW(PW), .TSW(TSW), .CW(CW), .HB(HB), .WAIT_BOUND(WAIT_BOUND),
                 .CHECK_WAIT(ARB_TYPE >= 2), .NAME("FIR   ")) cs1 (
        .clk(clk), .reset(reset), .now(now), .push(acc1), .push_ts(ts1), .push_payload({wr1, addr1, data1}),
        .pop(rd1 && !empty1), .dout(dout1), .req(req1), .full(full1),
        .stall(stall1), .af(af1), .count(count1), .waiting(wait1));
    chan_stats #(.PW(PW), .TSW(TSW), .CW(CW), .HB(HB), .WAIT_BOUND(WAIT_BOUND),
                 .CHECK_WAIT(ARB_TYPE >= 2), .NAME("MATMUL")) cs2 (
        .clk(clk), .reset(reset), .now(now), .push(acc2), .push_ts(ts2), .push_payload({wr2, addr2, data2}),
        .pop(rd2 && !empty2), .dout(dout2), .req(req2), .full(full2),
        .stall(stall2), .af(af2), .count(count2), .waiting(wait2));
    chan_stats #(.PW(PW), .TSW(TSW), .CW(CW), .HB(HB), .WAIT_BOUND(WAIT_BOUND),
                 .CHECK_WAIT(ARB_TYPE >= 2), .NAME("SPARSE")) cs3 (
        .clk(clk), .reset(reset), .now(now), .push(acc3), .push_ts(ts3), .push_payload({wr3, addr3, data3}),
        .pop(rd3 && !empty3), .dout(dout3), .req(req3), .full(full3),
        .stall(stall3), .af(af3), .count(count3), .waiting(wait3));

    // ============================================================
    // Run and report
    // ============================================================
    reg [8*10:1] scen_name, arb_name;
    integer cyc, i, total_served, total_errors, total_stall, total_lat, cum, p99_all, max_all;
    integer h_all [0:HB-1];
    real    x1, x2, x3, jain, thr;

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
            3: scen_name = "SLOW_MEM";
            default: scen_name = "SWITCH_PEN";
        endcase
        case (ARB_TYPE)
            0: arb_name = "FIXED";
            1: arb_name = "RR";
            2: arb_name = "ADAPTIVE";
            default: arb_name = "ADAPT_V2";
        endcase

        reset = 1'b1;
        repeat (4) @(negedge clk);
        reset = 1'b0;

        if (VERBOSE_CYCLES > 0) begin
            $display("Cycle | Occ F/M/S  | Score F/M/S   | Gnt | Wait F/M/S | AF  | Stall | rdy");
        end

        for (cyc = 1; cyc <= SIM_CYCLES; cyc = cyc + 1) begin
            @(negedge clk);
            if (cyc <= VERBOSE_CYCLES)
                $display("%5d | %2d %2d %2d   | %3d %3d %3d   |  %0d  | %3d %3d %3d | %b%b%b | %b%b%b   | %b",
                         cyc, count1, count2, count3, score1, score2, score3, grant,
                         wait1, wait2, wait3, af1, af2, af3, stall1, stall2, stall3, mem_ready);
        end
        @(negedge clk); #1;

        total_served = cs1.served + cs2.served + cs3.served;
        total_errors = cs1.errors + cs2.errors + cs3.errors;
        total_stall  = cs1.stall_cycles + cs2.stall_cycles + cs3.stall_cycles;
        total_lat    = cs1.lat_sum + cs2.lat_sum + cs3.lat_sum;

        // Overall p99 from the merged histogram
        for (i = 0; i < HB; i = i + 1) h_all[i] = cs1.hist[i] + cs2.hist[i] + cs3.hist[i];
        cum = 0; p99_all = 0;
        for (i = 0; i < HB; i = i + 1) begin
            cum = cum + h_all[i];
            if (p99_all == 0 && cum * 100 >= total_served * 99) p99_all = (i == 0) ? 0 : i;
        end
        max_all = max3(cs1.max_lat_incl_pending(now), cs2.max_lat_incl_pending(now),
                       cs3.max_lat_incl_pending(now));

        x1   = ratio(cs1.served, cs1.offered);
        x2   = ratio(cs2.served, cs2.offered);
        x3   = ratio(cs3.served, cs3.offered);
        jain = (x1 + x2 + x3) * (x1 + x2 + x3) / (3.0 * (x1*x1 + x2*x2 + x3*x3));
        thr  = (1.0 * total_served) / SIM_CYCLES;

        $display("");
        $display("===============================================================================");
        $display("  %0s  arbiter  |  scenario %0s  |  %0d cycles  |  mem interval %0d, switch penalty %0d",
                 arb_name, scen_name, SIM_CYCLES, MEM_SI, MEM_SP);
        $display("===============================================================================");
        $display("Channel | Served | Offered | Srv/Off | Lat avg | Lat p99 | Lat max* | MaxWait | Stall");
        $display("--------+--------+---------+---------+---------+---------+----------+---------+------");
        cs1.report(now);
        cs2.report(now);
        cs3.report(now);
        $display("-------------------------------------------------------------------------------");
        $display("Throughput  : %0.3f req/cycle   (memory capacity %0.3f)", thr, 1.0 / MEM_SI);
        $display("Latency     : avg %0d, p99 %0d, max* %0d cycles",
                 (total_served > 0) ? total_lat / total_served : 0, p99_all, max_all);
        $display("Fairness    : Jain index %0.3f  (1.0 = every channel gets the same share of its demand)", jain);
        $display("Stalls      : %0d generator stall cycles", total_stall);
        $display("* max includes requests still queued at the end of the run");
        if (total_errors == 0) $display("RESULT: PASS");
        else                   $display("RESULT: FAIL (%0d errors)", total_errors);

        // Machine-readable lines for run.sh / summarize.py
        cs1.csv(scen_name, arb_name, now);
        cs2.csv(scen_name, arb_name, now);
        cs3.csv(scen_name, arb_name, now);
        $display("SUM,%0s,%0s,%0.3f,%0.3f,%0d,%0d,%0d,%0d,%0d",
                 scen_name, arb_name, thr, jain,
                 (total_served > 0) ? total_lat / total_served : 0, p99_all, max_all,
                 total_stall, total_errors);
        $finish;
    end

endmodule


// ============================================================================
// chan_stats : scoreboard + statistics for one channel (testbench only)
// ============================================================================
module chan_stats #(
    parameter integer PW         = 65,
    parameter integer TSW        = 16,
    parameter integer CW         = 5,
    parameter integer HB         = 1024,
    parameter integer WAIT_BOUND = 14,
    parameter integer CHECK_WAIT = 1,
    parameter integer SBD        = 64,
    parameter         NAME       = "CH    "
)(
    input  wire               clk,
    input  wire               reset,
    input  wire [TSW-1:0]     now,
    input  wire               push,
    input  wire [TSW-1:0]     push_ts,       // time the request became ready
    input  wire [PW-1:0]      push_payload,
    input  wire               pop,
    input  wire [TSW+PW-1:0]  dout,
    input  wire               req,
    input  wire               full,
    input  wire               stall,
    input  wire               af,
    input  wire [CW-1:0]      count,
    input  wire [7:0]         waiting
);
    reg [PW-1:0]  sb     [0:SBD-1];
    reg [TSW-1:0] push_t [0:SBD-1];
    integer       sb_w, sb_r;

    integer hist [0:HB-1];
    integer served, offered, lat_sum, lat_max, errors;
    integer stall_cycles, max_wait, i;

    reg           pop_d;
    reg [TSW-1:0] pop_time;
    reg [TSW-1:0] lat;

    always @(posedge clk) begin
        if (reset) begin
            sb_w = 0; sb_r = 0;
            served = 0; offered = 0; lat_sum = 0; lat_max = 0; errors = 0;
            stall_cycles = 0; max_wait = 0;
            pop_d = 1'b0; pop_time = '0;
            for (i = 0; i < HB; i = i + 1) hist[i] = 0;
        end else begin
            // Entry popped on the previous edge is now on dout
            if (pop_d) begin
                if (sb_r == sb_w) begin
                    $display("ERROR [%s] @%0t: dequeue with empty scoreboard", NAME, $time);
                    errors = errors + 1;
                end else begin
                    if (dout[PW-1:0] !== sb[sb_r % SBD]) begin
                        $display("ERROR [%s] @%0t: data mismatch got %h exp %h",
                                 NAME, $time, dout[PW-1:0], sb[sb_r % SBD]);
                        errors = errors + 1;
                    end
                    sb_r = sb_r + 1;
                end
                lat     = pop_time - dout[TSW+PW-1:PW];
                served  = served + 1;
                lat_sum = lat_sum + lat;
                if (lat > lat_max) lat_max = lat;
                hist[(lat >= HB) ? HB-1 : lat] = hist[(lat >= HB) ? HB-1 : lat] + 1;
            end

            if (push) begin
                if (sb_w - sb_r >= SBD) begin
                    $display("ERROR [%s] @%0t: scoreboard overflow", NAME, $time);
                    errors = errors + 1;
                end
                sb[sb_w % SBD]     = push_payload;
                push_t[sb_w % SBD] = push_ts;
                sb_w = sb_w + 1;
            end

            if (req && full) begin
                $display("ERROR [%s] @%0t: write attempted into full FIFO", NAME, $time);
                errors = errors + 1;
            end
            if (CHECK_WAIT && waiting > WAIT_BOUND) begin
                $display("ERROR [%s] @%0t: waiting=%0d exceeds bound %0d",
                         NAME, $time, waiting, WAIT_BOUND);
                errors = errors + 1;
            end

            if (push || stall)      offered      = offered + 1;
            if (stall)              stall_cycles = stall_cycles + 1;
            if (waiting > max_wait) max_wait     = waiting;

            pop_d    = pop;
            pop_time = now;
        end
    end

    // Worst latency, counting requests still queued at the end of the run
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

    function integer p99;
        input dummy;
        integer j, cum;
        begin
            p99 = 0; cum = 0;
            for (j = 0; j < HB; j = j + 1) begin
                cum = cum + hist[j];
                if (p99 == 0 && served > 0 && cum * 100 >= served * 99) p99 = (j == 0) ? 0 : j;
            end
        end
    endfunction

    task report(input [TSW-1:0] t);
        begin
            $display("%s  | %6d | %7d | %6d%% | %7d | %7d | %8d | %7d | %5d",
                     NAME, served, offered,
                     (offered > 0) ? served * 100 / offered : 0,
                     (served > 0) ? lat_sum / served : 0,
                     p99(1'b0), max_lat_incl_pending(t), max_wait, stall_cycles);
        end
    endtask

    task csv(input [8*10:1] scen, input [8*10:1] arb, input [TSW-1:0] t);
        begin
            $display("CSV,%0s,%0s,%0s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                     scen, arb, NAME, served, offered,
                     (served > 0) ? lat_sum / served : 0,
                     p99(1'b0), max_lat_incl_pending(t), max_wait, stall_cycles, errors);
        end
    endtask

endmodule
