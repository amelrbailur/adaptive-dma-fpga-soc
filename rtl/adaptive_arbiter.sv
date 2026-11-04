`timescale 1ns/1ps
// ============================================================================
// adaptive_arbiter : score-based 3-channel arbiter with starvation override
//
// Step 1 changes from v1:
//   * No dividers. Every metric is normalised to 0..15 with shifts/saturation,
//     and the weights are small integers (4:3:2:1 keeps your 40:30:20:10
//     ratio). Each score is a few shift-adds instead of /255, /100, /15.
//   * Wait is normalised against 15 (just above WAIT_OVERRIDE), not WAIT_MAX.
//     In v1 the wait term could add at most ~1 point before the override
//     fired, so W_WAIT had no effect. Now it spans the full 0..15 range.
//   * Scores are REGISTERED. Grant uses scores that are one cycle old, which
//     takes the multiply-add out of the rd_en critical path.
//   * Selection written as a rotating loop over the three channels. Behaviour
//     is unchanged: overdue channels first (longest wait wins), otherwise the
//     highest score; ties go to the next channel after the last grant.
//
// Step 2 changes:
//   * mem_ready input: no grant is issued while the downstream memory port
//     is busy (same port list as fixed_priority_arbiter and rr_arbiter).
//   * Starvation counters moved to the shared wait_counters module.
//
// Tuning (ADAPT_V2 = WAIT_MODE 1, HOLD_MAX > 1):
//   * WAIT_MODE = 1: the override and the wait score use MISSED GRANTS
//     (grant opportunities given to another channel) instead of raw cycles.
//     With slow memory every channel waited > WAIT_OVERRIDE cycles, so the
//     override fired constantly and v1 behaved like round robin. Counting
//     grant opportunities makes the threshold independent of memory speed.
//   * HOLD_MAX > 1: burst hold. Keep granting the same channel for up to
//     HOLD_MAX consecutive grants while it still has requests and no other
//     channel is overdue. Cuts channel switches (row misses / AXI burst
//     changes) and is the grant granularity the AXI burst master will need.
//   * WAIT_MODE = 0 and HOLD_MAX = 1 give exactly the v1 behaviour.
//
//   Max score = 15*(W_OCC+W_WAIT+W_RATE+W_BURST) + AF_BONUS = 150 + 30 = 180,
//   which fits in SCORE_W = 8 bits.
// ============================================================================
module adaptive_arbiter #(
    parameter integer DEPTH         = 16,
    parameter integer W_OCC         = 4,
    parameter integer W_WAIT        = 3,
    parameter integer W_RATE        = 2,
    parameter integer W_BURST       = 1,
    parameter integer AF_BONUS      = 30,
    parameter integer WAIT_MAX      = 255,
    parameter integer WAIT_OVERRIDE = 12,
    parameter integer SCORE_W       = 8,
    parameter integer WAIT_MODE     = 0,    // 0 = cycles, 1 = missed grants
    parameter integer HOLD_MAX      = 1     // 1 = no burst hold
)(
    input  wire                     clk,
    input  wire                     reset,
    input  wire                     mem_ready,

    input  wire                     empty1, empty2, empty3,
    input  wire [$clog2(DEPTH):0]   fifo_count1, fifo_count2, fifo_count3,
    input  wire                     almost_full1, almost_full2, almost_full3,
    input  wire [3:0]               arrival_rate1, arrival_rate2, arrival_rate3,
    input  wire [3:0]               burst_len1, burst_len2, burst_len3,

    output reg                      rd_en1, rd_en2, rd_en3,
    output reg  [1:0]               grant,          // 3 = idle
    output reg  [SCORE_W-1:0]       score1, score2, score3,
    output wire [7:0]               waiting1, waiting2, waiting3
);

    localparam integer CW  = $clog2(DEPTH) + 1;
    localparam integer LG2 = $clog2(DEPTH);

    // Sized copies of the integer parameters (lint-clean comparisons)
    localparam [7:0]         WMAX8    = WAIT_MAX[7:0];
    localparam [7:0]         WOVR8    = WAIT_OVERRIDE[7:0];
    localparam [7:0]         HOLD8    = HOLD_MAX[7:0];
    localparam [SCORE_W-1:0] W_OCC_S  = W_OCC[SCORE_W-1:0];
    localparam [SCORE_W-1:0] W_WAIT_S = W_WAIT[SCORE_W-1:0];
    localparam [SCORE_W-1:0] W_RATE_S = W_RATE[SCORE_W-1:0];
    localparam [SCORE_W-1:0] W_BRST_S = W_BURST[SCORE_W-1:0];
    localparam [SCORE_W-1:0] AF_S     = AF_BONUS[SCORE_W-1:0];

    // synthesis translate_off
    initial begin
        if (15*(W_OCC+W_WAIT+W_RATE+W_BURST) + AF_BONUS > (1<<SCORE_W) - 1)
            $warning("adaptive_arbiter: scores can saturate at %0d with these weights", (1<<SCORE_W) - 1);
        if (WAIT_OVERRIDE > 15)
            $warning("adaptive_arbiter: WAIT_OVERRIDE > 15, wait term saturates before override");
    end
    // synthesis translate_on

    // ---------------------------------------------------------------
    // Normalisation helpers (shifts and saturation only)
    // ---------------------------------------------------------------
    function automatic [3:0] norm_occ;
        input [CW-1:0] c;
        reg   [CW+3:0] s;
        begin
            s = {4'd0, c};
            if (LG2 >= 4) s = s >> (LG2 - 4);
            else          s = s << (4 - LG2);
            norm_occ = (s > {{CW{1'b0}}, 4'd15}) ? 4'd15 : s[3:0];
        end
    endfunction

    function automatic [3:0] norm_wait;
        input [7:0] w;
        begin
            norm_wait = (w > 8'd15) ? 4'd15 : w[3:0];
        end
    endfunction

    // Sum computed SCORE_W+7 bits wide (4 terms of 255*15 plus a bonus fit),
    // then saturated, so no weight setting can wrap the score. This matters
    // once the weights become software-programmable.
    localparam integer SW = SCORE_W + 7;

    // weight x 4-bit input as four conditional shifted adds (no '*').
    // Same logic synthesis would build, but explicit, so formal tools
    // reason about real values instead of abstracting a multiplier
    // (Jasper Superlint gave a spurious overflow on the '*' version).
    // Works unchanged when the weights become programmable registers.
    function automatic [SW-1:0] wmul;
        input [SCORE_W-1:0] w;
        input [3:0]         x;
        reg   [SW-1:0]      wide;
        begin
            wide = {7'd0, w};
            wmul = (x[0] ? wide       : {SW{1'b0}})
                 + (x[1] ? wide << 1  : {SW{1'b0}})
                 + (x[2] ? wide << 2  : {SW{1'b0}})
                 + (x[3] ? wide << 3  : {SW{1'b0}});
        end
    endfunction

    function automatic [SCORE_W-1:0] calc_score;
        input [3:0] occ, wt, rate, burst;
        input       af;
        reg   [SW-1:0] sum;
        begin
            sum = (wmul(W_OCC_S, occ)  + wmul(W_WAIT_S, wt))
                + (wmul(W_RATE_S, rate) + wmul(W_BRST_S, burst))
                + (af ? {7'd0, AF_S} : {SW{1'b0}});
            calc_score = (sum > {7'd0, {SCORE_W{1'b1}}}) ? {SCORE_W{1'b1}} : sum[SCORE_W-1:0];
        end
    endfunction

    // ---------------------------------------------------------------
    // Age used by the policy: cycles (v1) or missed grants (v2)
    //   cycles mode increments every cycle while waiting, exactly like
    //   the 'waiting' outputs; grants mode only when the memory port
    //   was free and someone else got it.
    // ---------------------------------------------------------------
    reg  [7:0] age1, age2, age3;
    wire       opportunity = (WAIT_MODE == 0) || mem_ready;

    always @(posedge clk) begin
        if (reset) begin
            age1 <= 8'd0; age2 <= 8'd0; age3 <= 8'd0;
        end else begin
            if (rd_en1 || empty1)                     age1 <= 8'd0;
            else if (opportunity && age1 < WMAX8)  age1 <= age1 + 8'd1;
            if (rd_en2 || empty2)                     age2 <= 8'd0;
            else if (opportunity && age2 < WMAX8)  age2 <= age2 + 8'd1;
            if (rd_en3 || empty3)                     age3 <= 8'd0;
            else if (opportunity && age3 < WMAX8)  age3 <= age3 + 8'd1;
        end
    end

    // ---------------------------------------------------------------
    // Registered scores (computed combinationally, then flopped)
    // ---------------------------------------------------------------
    wire [SCORE_W-1:0] score1_n = calc_score(norm_occ(fifo_count1), norm_wait(age1),
                                             arrival_rate1, burst_len1, almost_full1);
    wire [SCORE_W-1:0] score2_n = calc_score(norm_occ(fifo_count2), norm_wait(age2),
                                             arrival_rate2, burst_len2, almost_full2);
    wire [SCORE_W-1:0] score3_n = calc_score(norm_occ(fifo_count3), norm_wait(age3),
                                             arrival_rate3, burst_len3, almost_full3);

    always @(posedge clk) begin
        if (reset) begin
            score1 <= '0;
            score2 <= '0;
            score3 <= '0;
        end else begin
            score1 <= score1_n;
            score2 <= score2_n;
            score3 <= score3_n;
        end
    end

    // ---------------------------------------------------------------
    // Grant selection
    // ---------------------------------------------------------------
    reg  [1:0]           last_grant;

    // 4-entry arrays indexed by the 2-bit channel number (entry 3 = no
    // channel: always empty), so every index is in range and is a plain mux.
    wire [3:0]         empty_v = {1'b1, empty3, empty2, empty1};
    wire [7:0]         wait_a  [0:3];
    wire [SCORE_W-1:0] score_a [0:3];
    assign wait_a[0]  = age1;   assign wait_a[1]  = age2;
    assign wait_a[2]  = age3;   assign wait_a[3]  = 8'd0;
    assign score_a[0] = score1; assign score_a[1] = score2;
    assign score_a[2] = score3; assign score_a[3] = {SCORE_W{1'b0}};

    reg  [1:0]           ovr_sel, scr_sel, selected;
    reg  [7:0]           oldest;
    reg  [SCORE_W-1:0]   best;
    reg                  overdue, any_ready, sticky;
    reg  [7:0]           hold_cnt;    // consecutive grants to last_grant
    reg  [1:0]           idx;
    integer              k;

    // Next channel in rotation order 0 -> 1 -> 2 -> 0
    function automatic [1:0] next_ch;
        input [1:0] c;
        begin
            next_ch = (c >= 2'd2) ? 2'd0 : c + 2'd1;
        end
    endfunction

    always @* begin
        ovr_sel   = 2'd3;
        scr_sel   = 2'd3;
        oldest    = 8'd0;
        best      = '0;
        overdue   = 1'b0;
        any_ready = 1'b0;

        // Visit channels starting after last_grant (rotating priority).
        // Strict '>' means the first channel in rotation order wins ties.
        idx = last_grant;
        for (k = 0; k < 3; k = k + 1) begin
            idx = next_ch(idx);

            if (!empty_v[idx]) begin
                if (wait_a[idx] >= WOVR8 &&
                    (!overdue || wait_a[idx] > oldest)) begin
                    overdue = 1'b1;
                    oldest  = wait_a[idx];
                    ovr_sel = idx;
                end

                if (!any_ready || score_a[idx] > best) begin
                    any_ready = 1'b1;
                    best      = score_a[idx];
                    scr_sel   = idx;
                end
            end
        end

        // Burst hold: stay on the last channel while it has work
        sticky = (HOLD_MAX > 1) && !empty_v[last_grant] && (hold_cnt < HOLD8);

        if (!mem_ready)   selected = 2'd3;
        else if (overdue) selected = ovr_sel;
        else if (sticky)  selected = last_grant;
        else              selected = scr_sel;

        grant  = selected;
        rd_en1 = (selected == 2'd0);
        rd_en2 = (selected == 2'd1);
        rd_en3 = (selected == 2'd2);
    end

    // ---------------------------------------------------------------
    // Rotation state and starvation counters
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            last_grant <= 2'd2;            // channel 0 first
            hold_cnt   <= HOLD8;           // no hold right after reset
        end else if (selected != 2'd3) begin
            last_grant <= selected;
            if (selected == last_grant && hold_cnt != 8'hFF) hold_cnt <= hold_cnt + 8'd1;
            else if (selected != last_grant)                 hold_cnt <= 8'd1;
        end
    end

    wait_counters #(.WAIT_MAX(WAIT_MAX)) u_wait (
        .clk(clk), .reset(reset),
        .empty1(empty1), .empty2(empty2), .empty3(empty3),
        .rd_en1(rd_en1), .rd_en2(rd_en2), .rd_en3(rd_en3),
        .waiting1(waiting1), .waiting2(waiting2), .waiting3(waiting3));

endmodule
