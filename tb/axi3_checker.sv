`timescale 1ns/1ps
// ============================================================================
// axi3_checker : AXI3 protocol checks on the master side (testbench only)
//   Written as clocked procedural checks so it runs on any simulator.
//   The same rules become SVA properties for Jasper in the formal step.
//
//   R1  AR/AW/W: once VALID is high it stays high until READY.
//   R2  AR/AW/W: address/len/id/data stay stable while VALID && !READY.
//   R3  AxSIZE = 32-bit, AxBURST = INCR, AxLEN <= 15 (AXI3 limit).
//   R4  A burst never crosses a 4 KB boundary.
//   R5  WLAST on exactly beat AWLEN of each write (W follows AW order).
//   R6  WID matches the AWID of the burst it belongs to.
//   R7  Read responses: RID matches the in-order outstanding AR.
//   R8  No W beat before its AW (this master never sends write data early).
// ============================================================================
module axi3_checker (
    input wire        clk,
    input wire        reset,
    input wire [1:0]  awid,  input wire [31:0] awaddr, input wire [3:0] awlen,
    input wire [2:0]  awsize, input wire [1:0] awburst,
    input wire        awvalid, input wire awready,
    input wire [1:0]  wid,   input wire [31:0] wdata,  input wire wlast,
    input wire        wvalid, input wire wready,
    input wire [1:0]  arid,  input wire [31:0] araddr, input wire [3:0] arlen,
    input wire [2:0]  arsize, input wire [1:0] arburst,
    input wire        arvalid, input wire arready,
    input wire [1:0]  rid,   input wire rlast, input wire rvalid, input wire rready
);
    integer errors;

    reg        ar_pend, aw_pend, w_pend;
    reg [37:0] ar_hold, aw_hold;
    reg [34:0] w_hold;      // {wlast, wid[1:0], wdata[31:0]} = 35 bits

    reg [3:0]  aw_q_len [$];
    reg [1:0]  aw_q_id  [$];
    reg [1:0]  ar_q_id  [$];
    integer    w_beat, dummy;

    task fail(input [8*40:1] msg);
        begin
            $display("AXI ERROR @%0t: %0s", $time, msg);
            errors = errors + 1;
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            errors = 0; ar_pend = 0; aw_pend = 0; w_pend = 0; w_beat = 0;
            aw_q_len.delete(); aw_q_id.delete(); ar_q_id.delete();
        end else begin
            // R1 / R2 : stability while waiting for READY
            if (ar_pend && !arvalid)                              fail("R1 ARVALID dropped before ARREADY");
            if (ar_pend && arvalid && {arid, araddr, arlen} !== ar_hold) fail("R2 AR fields changed while waiting");
            if (aw_pend && !awvalid)                              fail("R1 AWVALID dropped before AWREADY");
            if (aw_pend && awvalid && {awid, awaddr, awlen} !== aw_hold) fail("R2 AW fields changed while waiting");
            if (w_pend && !wvalid)                                fail("R1 WVALID dropped before WREADY");
            if (w_pend && wvalid && {wlast, wid, wdata} !== w_hold) fail("R2 W fields changed while waiting");

            ar_pend = arvalid && !arready;  ar_hold = {arid, araddr, arlen};
            aw_pend = awvalid && !awready;  aw_hold = {awid, awaddr, awlen};
            w_pend  = wvalid  && !wready;   w_hold  = {wlast, wid, wdata};

            // R3 / R4 on every valid address beat
            if (arvalid) begin
                if (arsize !== 3'b010 || arburst !== 2'b01) fail("R3 AR size/burst");
                if ({20'd0, araddr[11:0]} + (arlen + 1) * 4 > 4096) fail("R4 AR crosses 4KB");
            end
            if (awvalid) begin
                if (awsize !== 3'b010 || awburst !== 2'b01) fail("R3 AW size/burst");
                if ({20'd0, awaddr[11:0]} + (awlen + 1) * 4 > 4096) fail("R4 AW crosses 4KB");
            end

            // Track bursts
            if (awvalid && awready) begin aw_q_len.push_back(awlen); aw_q_id.push_back(awid); end
            if (arvalid && arready) ar_q_id.push_back(arid);

            // R5 / R6 / R8 : W beats
            if (wvalid && wready) begin
                if (aw_q_len.size() == 0) fail("R8 W beat before its AW");
                else begin
                    if (wid !== aw_q_id[0])                    fail("R6 WID != AWID");
                    if (wlast !== (w_beat == aw_q_len[0]))     fail("R5 WLAST on wrong beat");
                    if (wlast) begin
                        dummy = aw_q_len.pop_front(); dummy = aw_q_id.pop_front(); w_beat = 0;
                    end else
                        w_beat = w_beat + 1;
                end
            end

            // R7 : read responses in order
            if (rvalid && rready) begin
                if (ar_q_id.size() == 0)        fail("R7 R beat with no outstanding AR");
                else begin
                    if (rid !== ar_q_id[0])     fail("R7 RID mismatch");
                    if (rlast) dummy = ar_q_id.pop_front();
                end
            end
        end
    end
endmodule
