`timescale 1ns/1ps
// ============================================================================
// axi3_mem_model : behavioural DRAM-like AXI3 slave (testbench only)
//
//   * 4 banks, bank = addr[13:12], row = addr[31:14], one open row per bank.
//   * Shared data bus: one beat per cycle, bursts transfer back to back.
//   * Bank-level parallelism: a row miss needs T_MISS cycles of
//     precharge + activate in ITS bank, which can overlap data transfers
//     from other banks. So a miss is cheap when neighbouring requests use
//     other banks, and expensive when two streams fight over the same bank
//     with different rows. That bank conflict is what the arbiter's burst
//     hold and the DMA's burst gathering reduce.
//   * In-order (no FR-FCFS reordering): requests are scheduled oldest first,
//     reads and writes sharing the DRAM. A write is scheduled once all its
//     W beats have arrived. The scheduler looks at most T_MISS cycles ahead
//     of the data bus, which is what lets activations overlap transfers.
//   * Read data / write response appear LAT cycles after the data transfer.
//     Responses are in order per direction.
//   * AR/AW queues hold QDEPTH entries; arready/awready drop when full.
//   * Read data returned is the address (easy to eyeball in waveforms).
//   * BP = 1: random backpressure. ARREADY / AWREADY / WREADY are each low
//     about 25% of the time (LFSR), to exercise the master's wait states.
//   * ERR = 1: the 20th read burst returns SLVERR on its last beat and the
//     20th write burst gets BRESP = SLVERR (tests err_status[0]).
//     ERR = 2: the 20th read burst comes back with a wrong RID on its
//     first beat (tests err_status[1]). Data and ordering stay correct.
//     ERR = 3: the 20th write response comes back with a wrong BID
//     (tests the BID half of err_status[1]).
// ============================================================================
module axi3_mem_model #(
    parameter integer LAT    = 10,
    parameter integer T_MISS = 4,
    parameter integer QDEPTH = 8,
    parameter integer BP     = 0,
    parameter integer ERR    = 0
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [1:0]  awid,
    input  wire [31:0] awaddr,
    input  wire [3:0]  awlen,
    input  wire        awvalid,
    output reg         awready,
    input  wire [1:0]  wid,
    input  wire [31:0] wdata,
    input  wire        wlast,
    input  wire        wvalid,
    output reg         wready,
    output reg  [1:0]  bid,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,

    input  wire [1:0]  arid,
    input  wire [31:0] araddr,
    input  wire [3:0]  arlen,
    input  wire        arvalid,
    output reg         arready,
    output reg  [1:0]  rid,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rlast,
    output reg         rvalid,
    input  wire        rready
);
    // Request queues
    reg [31:0] ar_addr [$];  reg [3:0] ar_len [$];  reg [1:0] ar_id [$];  integer ar_t [$];
    reg [31:0] aw_addr [$];  reg [3:0] aw_len [$];  reg [1:0] aw_id [$];  integer aw_t [$];
    integer    w_bursts_done;

    // Response queues
    reg [31:0] r_addr [$];   reg [3:0] r_len [$];   reg [1:0] r_id [$];   integer r_time [$];
    reg [1:0]  b_id   [$];   integer b_time [$];
    integer    r_beat;

    // DRAM timing state
    reg [17:0] open_row   [0:3];
    reg        row_open   [0:3];
    integer    bank_ready [0:3];      // cycle the bank is free for a new activate
    integer    bus_free;              // cycle the data bus is next free

    integer now, row_hits, row_misses, rd_bursts, wr_bursts;
    integer r_done, b_done;           // response bursts handed back
    reg [15:0] lfsr;                  // backpressure randomness
    integer b, k, dummy, act, dstart, dend, beats;
    reg     pick_rd, have;
    reg [31:0] c_addr; reg [3:0] c_len; reg [1:0] c_id; reg c_wr;

    always @(posedge clk) begin
        if (reset) begin
            ar_addr.delete(); ar_len.delete(); ar_id.delete(); ar_t.delete();
            aw_addr.delete(); aw_len.delete(); aw_id.delete(); aw_t.delete();
            r_addr.delete();  r_len.delete();  r_id.delete();  r_time.delete();
            b_id.delete();    b_time.delete();
            w_bursts_done = 0; r_beat = 0; now = 0; bus_free = 0;
            row_hits = 0; row_misses = 0; rd_bursts = 0; wr_bursts = 0;
            r_done = 0; b_done = 0; lfsr = 16'hACE1;
            for (k = 0; k < 4; k = k + 1) begin open_row[k] = 0; row_open[k] = 0; bank_ready[k] = 0; end
            arready <= 1'b0; awready <= 1'b0; wready <= 1'b1;
            rvalid  <= 1'b0; bvalid  <= 1'b0; rlast <= 1'b0;
            rid <= 0; bid <= 0; rdata <= 0; rresp <= 0; bresp <= 0;
        end else begin
            now = now + 1;

            // ---------- accept requests ----------
            if (arvalid && arready) begin
                ar_addr.push_back(araddr); ar_len.push_back(arlen);
                ar_id.push_back(arid);     ar_t.push_back(now);
            end
            if (awvalid && awready) begin
                aw_addr.push_back(awaddr); aw_len.push_back(awlen);
                aw_id.push_back(awid);     aw_t.push_back(now);
            end
            if (wvalid && wready && wlast) w_bursts_done = w_bursts_done + 1;

            // ---------- response handshakes ----------
            if (rvalid && rready) begin
                if (r_beat == r_len[0]) begin
                    r_done = r_done + 1;
                    dummy = r_addr.pop_front(); dummy = r_len.pop_front();
                    dummy = r_id.pop_front();   dummy = r_time.pop_front();
                    r_beat = 0;
                end else
                    r_beat = r_beat + 1;
            end
            if (bvalid && bready) begin
                b_done = b_done + 1;
                dummy = b_id.pop_front(); dummy = b_time.pop_front();
            end

            // ---------- schedule one request (oldest first) ----------
            // Look ahead at most T_MISS cycles of queued bus work, so an
            // activate can overlap the transfer in progress.
            if (bus_free <= now + T_MISS) begin
                have = 0;
                pick_rd = (ar_addr.size() > 0) &&
                          (aw_addr.size() == 0 || w_bursts_done == 0 || ar_t[0] <= aw_t[0]);
                if (pick_rd) begin
                    c_addr = ar_addr.pop_front(); c_len = ar_len.pop_front();
                    c_id   = ar_id.pop_front();   dummy = ar_t.pop_front();
                    c_wr = 0; have = 1; rd_bursts = rd_bursts + 1;
                end else if (aw_addr.size() > 0 && w_bursts_done > 0) begin
                    c_addr = aw_addr.pop_front(); c_len = aw_len.pop_front();
                    c_id   = aw_id.pop_front();   dummy = aw_t.pop_front();
                    w_bursts_done = w_bursts_done - 1;
                    c_wr = 1; have = 1; wr_bursts = wr_bursts + 1;
                end

                if (have) begin
                    b     = c_addr[13:12];
                    beats = c_len + 1;
                    if (row_open[b] && open_row[b] == c_addr[31:14]) begin
                        row_hits = row_hits + 1;
                        dstart   = (bus_free > now) ? bus_free : now;
                    end else begin
                        row_misses  = row_misses + 1;
                        act         = (bank_ready[b] > now) ? bank_ready[b] : now;
                        dstart      = act + T_MISS;
                        if (bus_free > dstart) dstart = bus_free;
                        open_row[b] = c_addr[31:14];
                        row_open[b] = 1;
                    end
                    dend          = dstart + beats;
                    bus_free      = dend;
                    bank_ready[b] = dend;

                    if (c_wr) begin
                        b_id.push_back(c_id); b_time.push_back(dend + LAT);
                    end else begin
                        r_addr.push_back(c_addr); r_len.push_back(c_len);
                        r_id.push_back(c_id);     r_time.push_back(dend + LAT);
                    end
                end
            end

            // ---------- drive outputs for next cycle ----------
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            arready <= (ar_addr.size() < QDEPTH) && (BP == 0 || (lfsr[1:0] != 2'b00));
            awready <= (aw_addr.size() < QDEPTH) && (BP == 0 || (lfsr[5:4] != 2'b00));
            wready  <= (BP == 0) || (lfsr[9:8] != 2'b00);

            if (r_addr.size() > 0 && now >= r_time[0]) begin
                rvalid <= 1'b1;
                rid    <= (ERR == 2 && r_done == 19 && r_beat == 0) ? ~r_id[0] : r_id[0];
                rdata  <= r_addr[0] + 4 * r_beat;
                rlast  <= (r_beat == r_len[0]);
                rresp  <= (ERR == 1 && r_done == 19 && r_beat == r_len[0]) ? 2'b10 : 2'b00;
            end else begin
                rvalid <= 1'b0;
                rlast  <= 1'b0;
            end

            if (b_id.size() > 0 && now >= b_time[0]) begin
                bvalid <= 1'b1;
                bid    <= (ERR == 3 && b_done == 19) ? ~b_id[0] : b_id[0];
                bresp  <= (ERR == 1 && b_done == 19) ? 2'b10 : 2'b00;
            end else
                bvalid <= 1'b0;
        end
    end
endmodule
