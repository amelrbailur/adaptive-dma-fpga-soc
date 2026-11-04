`timescale 1ns/1ps
// ============================================================================
// func_cov : functional coverage for tb_axi_system (testbench only)
//
// Each bin counts how often a design behaviour of interest happened.
// Written with plain counters (not covergroups) so it runs on any simulator;
// report() prints one "FCOV,<test>,<bin>,<hits>" line per bin, and
// cov/cov_summary.py merges the lines from every run of the coverage
// regression into one table (a bin is covered if any run hit it).
//
// Bins that depend on the arbiter type (override / hold) are only sampled
// in the adaptive configurations; in the others they report "n/a" (-1) and
// are covered by the adaptive runs of the regression.
// ============================================================================
module func_cov #(
    parameter integer ARB_TYPE = 3,
    parameter integer HOLD_MAX = 4
)(
    input wire clk,
    input wire reset
);
    localparam integer NB = 42;

    integer hit [0:NB-1];
    integer i;

    // ---------------- bin indices ----------------
    localparam integer B_ST_IDLE   = 0,  B_ST_GATHER = 1,  B_ST_AR    = 2,
                       B_ST_AW     = 3,  B_ST_W      = 4,
                       B_RLEN1     = 5,  /* 5..8  read  burst length 1..4 */
                       B_WLEN1     = 9,  /* 9..12 write burst length 1..4 */
                       B_AR_WAIT   = 13, B_AW_WAIT   = 14, B_W_WAIT   = 15,
                       B_B2B_RD    = 16,
                       B_GPOP0     = 17, /* 17..19 gather pop per channel */
                       B_GRANT0    = 20, /* 20..22 grant per channel      */
                       B_MEMBUSY   = 23,
                       B_AF0       = 24, /* 24..26 almost-full per FIFO   */
                       B_PUSHPOP0  = 27, /* 27..29 push+pop same cycle    */
                       B_RW_CPL    = 30,
                       B_ROW_HIT   = 31, B_ROW_MISS  = 32,
                       B_RATE_SAT  = 33, B_BURST_SAT = 34,
                       B_OVR0      = 35, /* 35..37 starvation override per channel */
                       B_HOLD      = 38, B_HOLD_LIM  = 39,
                       B_ERR_RESP  = 40, B_ERR_ID    = 41;

    function [8*24:1] bin_name(input integer b);
        case (b)
            0:  bin_name = "dma_state_IDLE";
            1:  bin_name = "dma_state_GATHER";
            2:  bin_name = "dma_state_AR_wait";
            3:  bin_name = "dma_state_AW_wait";
            4:  bin_name = "dma_state_W";
            5:  bin_name = "rd_burst_len1";
            6:  bin_name = "rd_burst_len2";
            7:  bin_name = "rd_burst_len3";
            8:  bin_name = "rd_burst_len4";
            9:  bin_name = "wr_burst_len1";
            10: bin_name = "wr_burst_len2";
            11: bin_name = "wr_burst_len3";
            12: bin_name = "wr_burst_len4";
            13: bin_name = "arvalid_wait_arready";
            14: bin_name = "awvalid_wait_awready";
            15: bin_name = "wvalid_wait_wready";
            16: bin_name = "accept_same_cycle_as_AR";
            17: bin_name = "gather_pop_FIR";
            18: bin_name = "gather_pop_MATMUL";
            19: bin_name = "gather_pop_SPARSE";
            20: bin_name = "grant_FIR";
            21: bin_name = "grant_MATMUL";
            22: bin_name = "grant_SPARSE";
            23: bin_name = "pending_but_mem_busy";
            24: bin_name = "almost_full_FIR";
            25: bin_name = "almost_full_MATMUL";
            26: bin_name = "almost_full_SPARSE";
            27: bin_name = "push_pop_same_cyc_FIR";
            28: bin_name = "push_pop_same_cyc_MATMUL";
            29: bin_name = "push_pop_same_cyc_SPARSE";
            30: bin_name = "rd_wr_complete_same_cyc";
            31: bin_name = "dram_row_hit";
            32: bin_name = "dram_row_miss";
            33: bin_name = "arrival_rate_saturated";
            34: bin_name = "burst_len_saturated";
            35: bin_name = "override_FIR";
            36: bin_name = "override_MATMUL";
            37: bin_name = "override_SPARSE";
            38: bin_name = "hold_keeps_channel";
            39: bin_name = "hold_limit_forces_switch";
            40: bin_name = "err_resp_detected";
            41: bin_name = "err_id_detected";
            default: bin_name = "?";
        endcase
    endfunction

    // ---------------- design-independent bins ----------------
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < NB; i = i + 1) hit[i] = 0;
            if (ARB_TYPE < 2)
                for (i = B_OVR0; i <= B_HOLD_LIM; i = i + 1) hit[i] = -1;   // n/a
        end else begin
            // DMA state machine
            case (tb_axi_system.dut.dma.state)
                3'd0: hit[B_ST_IDLE]   = hit[B_ST_IDLE]   + 1;
                3'd1: hit[B_ST_GATHER] = hit[B_ST_GATHER] + 1;
                3'd2: hit[B_ST_AR]     = hit[B_ST_AR]     + 1;
                3'd3: hit[B_ST_AW]     = hit[B_ST_AW]     + 1;
                3'd4: hit[B_ST_W]      = hit[B_ST_W]      + 1;
                default: ;
            endcase

            // Burst lengths at the address handshake
            if (tb_axi_system.arvalid && tb_axi_system.arready && tb_axi_system.arlen < 4)
                hit[B_RLEN1 + tb_axi_system.arlen] = hit[B_RLEN1 + tb_axi_system.arlen] + 1;
            if (tb_axi_system.awvalid && tb_axi_system.awready && tb_axi_system.awlen < 4)
                hit[B_WLEN1 + tb_axi_system.awlen] = hit[B_WLEN1 + tb_axi_system.awlen] + 1;

            // AXI wait states (valid held while ready is low)
            if (tb_axi_system.arvalid && !tb_axi_system.arready) hit[B_AR_WAIT] = hit[B_AR_WAIT] + 1;
            if (tb_axi_system.awvalid && !tb_axi_system.awready) hit[B_AW_WAIT] = hit[B_AW_WAIT] + 1;
            if (tb_axi_system.wvalid  && !tb_axi_system.wready)  hit[B_W_WAIT]  = hit[B_W_WAIT]  + 1;

            // New grant accepted in the same cycle a read burst is handed off
            if (tb_axi_system.dut.dma.accept && tb_axi_system.dut.dma.ar_hs)
                hit[B_B2B_RD] = hit[B_B2B_RD] + 1;

            // Gathering pops and grants per channel
            for (i = 0; i < 3; i = i + 1) begin
                if (tb_axi_system.dut.dpop[i]) hit[B_GPOP0 + i] = hit[B_GPOP0 + i] + 1;
                if (tb_axi_system.dut.grant == i) hit[B_GRANT0 + i] = hit[B_GRANT0 + i] + 1;
            end
            if (!tb_axi_system.dut.mem_ready &&
                !(tb_axi_system.dut.empty1 && tb_axi_system.dut.empty2 && tb_axi_system.dut.empty3))
                hit[B_MEMBUSY] = hit[B_MEMBUSY] + 1;

            // FIFOs
            if (tb_axi_system.dut.af1) hit[B_AF0]     = hit[B_AF0]     + 1;
            if (tb_axi_system.dut.af2) hit[B_AF0 + 1] = hit[B_AF0 + 1] + 1;
            if (tb_axi_system.dut.af3) hit[B_AF0 + 2] = hit[B_AF0 + 2] + 1;
            if (tb_axi_system.dut.fifo1.do_wr && tb_axi_system.dut.fifo1.do_rd) hit[B_PUSHPOP0]     = hit[B_PUSHPOP0]     + 1;
            if (tb_axi_system.dut.fifo2.do_wr && tb_axi_system.dut.fifo2.do_rd) hit[B_PUSHPOP0 + 1] = hit[B_PUSHPOP0 + 1] + 1;
            if (tb_axi_system.dut.fifo3.do_wr && tb_axi_system.dut.fifo3.do_rd) hit[B_PUSHPOP0 + 2] = hit[B_PUSHPOP0 + 2] + 1;

            // Completions
            if (tb_axi_system.rd_cpl_valid && tb_axi_system.wr_cpl_valid) hit[B_RW_CPL] = hit[B_RW_CPL] + 1;

            // Traffic monitor saturation
            if (tb_axi_system.dut.rate1 == 4'd15 || tb_axi_system.dut.rate2 == 4'd15 ||
                tb_axi_system.dut.rate3 == 4'd15)
                hit[B_RATE_SAT] = hit[B_RATE_SAT] + 1;
            if (tb_axi_system.dut.burst1 == 4'd15 || tb_axi_system.dut.burst2 == 4'd15 ||
                tb_axi_system.dut.burst3 == 4'd15)
                hit[B_BURST_SAT] = hit[B_BURST_SAT] + 1;

            // Error detection
            if (tb_axi_system.dut.err_status[0]) hit[B_ERR_RESP] = hit[B_ERR_RESP] + 1;
            if (tb_axi_system.dut.err_status[1]) hit[B_ERR_ID]   = hit[B_ERR_ID]   + 1;
        end
    end

    // ---------------- adaptive-arbiter bins ----------------
    // The arbiter instance path differs per configuration, so each one is
    // sampled inside its own generate branch (only one is elaborated).
`define ARB_COV(P) \
    always @(posedge clk) begin \
        if (!reset && P.mem_ready) begin \
            if (P.overdue && P.ovr_sel < 3) \
                hit[B_OVR0 + P.ovr_sel] = hit[B_OVR0 + P.ovr_sel] + 1; \
            if (!P.overdue && P.sticky && P.scr_sel != P.last_grant) \
                hit[B_HOLD] = hit[B_HOLD] + 1; \
            if (!P.overdue && HOLD_MAX > 1 && !P.empty_v[P.last_grant] && \
                P.hold_cnt >= HOLD_MAX && P.selected != P.last_grant) \
                hit[B_HOLD_LIM] = hit[B_HOLD_LIM] + 1; \
        end \
    end

    generate
        if (ARB_TYPE == 2) begin : g_v1
            `ARB_COV(tb_axi_system.dut.arbiter.g_adaptive.u_arb)
        end else if (ARB_TYPE == 3) begin : g_v2
            `ARB_COV(tb_axi_system.dut.arbiter.g_adaptive_v2.u_arb)
        end
    endgenerate
`undef ARB_COV

    // ---------------- report ----------------
    task report(input [8*24:1] test);
        integer b, covered, applicable;
        begin
            // DRAM row behaviour comes from the memory model's counters
            hit[B_ROW_HIT]  = tb_axi_system.mem.row_hits;
            hit[B_ROW_MISS] = tb_axi_system.mem.row_misses;

            covered = 0; applicable = 0;
            for (b = 0; b < NB; b = b + 1) begin
                $display("FCOV,%0s,%0s,%0d", test, bin_name(b), hit[b]);
                if (hit[b] >= 0) applicable = applicable + 1;
                if (hit[b] >  0) covered    = covered + 1;
            end
            $display("Functional coverage (this run): %0d of %0d applicable bins hit", covered, applicable);
        end
    endtask

endmodule
