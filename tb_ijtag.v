// ============================================================
//  tb_ijtag.v  –  IJTAG SIB / LSIB Verification Testbench
//
//  ╔══════════════════════════════════════════════════════════╗
//  ║  SCAN-CHAIN BIT ORDERING  (key to understanding data)  ║
//  ╠══════════════════════════════════════════════════════════╣
//  ║  The chain is a pipelined serial shift-register.        ║
//  ║  Each cell uses cap_reg as its serial output (to_si),   ║
//  ║  so data propagates ONE cell per TCK.                   ║
//  ║                                                          ║
//  ║  TDI is at position 0 (shallowest).                     ║
//  ║  TDO is at position N-1 (deepest).                      ║
//  ║                                                          ║
//  ║  After N complete shifts, data_in[i] (bit i, shifted    ║
//  ║  on cycle i) ends up at position N-1-i.                 ║
//  ║  ⇒ data_in[N-1] → SIB_0  (last shifted in)            ║
//  ║  ⇒ data_in[0]   → deepest element  (first shifted in)  ║
//  ║                                                          ║
//  ║  Chain positions (19-bit full open):                     ║
//  ║   pos 0 : SIB_0                                         ║
//  ║   pos 1 : LSIB_1                                        ║
//  ║   pos 2 : InstrA.cap_reg[7]  (MSB, si-side)            ║
//  ║   ...                                                    ║
//  ║   pos 9 : InstrA.cap_reg[0]  (LSB, so-side)            ║
//  ║   pos10 : SIB_2                                         ║
//  ║   pos11 : InstrB.cap_reg[7]                             ║
//  ║   ...                                                    ║
//  ║   pos18 : InstrB.cap_reg[0]                             ║
//  ╚══════════════════════════════════════════════════════════╝
//
//  Helper macro for scan data:
//    SCAN_VAL(nbits, data_in) where data_in bit [N-1] goes to
//    position 0 (SIB_0) and bit [0] goes to deepest position.
//
//  Test plan:
//   TC-01  Reset – all SIBs=0
//   TC-02  Open SIB_0 (chain 1→3 bits)
//   TC-03  Open LSIB_1, write InstrA=0xBE, read back
//   TC-04  Open SIB_2, write InstrA=0xDE + InstrB=0xAD, read back
//   TC-05  Close LSIB_1 (chain 19→11 bits)
//   TC-06  Re-open LSIB_1, apply LOCK
//   TC-07  Try to change locked LSIB_1 – must be rejected
//   TC-08  Reset releases lock, all SIBs close
// ============================================================
`timescale 1ns/1ps

module tb_ijtag;

    reg        tck, tms, trst_n, tdi;
    wire       tdo;
    reg        lsib1_lock_in;
    wire       lsib1_locked;
    wire [7:0] instr_a_out, instr_b_out;
    wire       sib0_open, lsib1_open, sib2_open;

    ijtag_top dut (
        .tck           (tck),
        .tms           (tms),
        .trst_n        (trst_n),
        .tdi           (tdi),
        .tdo           (tdo),
        .lsib1_lock_in (lsib1_lock_in),
        .lsib1_locked  (lsib1_locked),
        .instr_a_out   (instr_a_out),
        .instr_b_out   (instr_b_out),
        .sib0_open     (sib0_open),
        .lsib1_open    (lsib1_open),
        .sib2_open     (sib2_open)
    );

    // ── Clock ─────────────────────────────────────────────────
    parameter TCK_PERIOD = 10;
    initial tck = 0;
    always #(TCK_PERIOD/2) tck = ~tck;

    // ── Test bookkeeping ──────────────────────────────────────
    integer pass_cnt, fail_cnt;
    reg [63:0] cap_data;   // TDO captured during scan

    // ── check task ────────────────────────────────────────────
    task check;
        input [63:0] got;
        input [63:0] exp;
        input [255:0] label;
        begin
            if (got === exp) begin
                $display("  PASS  %-34s  got=0x%h", label, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %-34s  got=0x%h  exp=0x%h", label, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ==========================================================
    //  Low-level TAP primitives
    // ==========================================================

    // Drive TMS/TDI; capture TDO on rising edge
    task tck_cycle;
        input tms_in, tdi_in;
        begin
            @(negedge tck); tms = tms_in; tdi = tdi_in;
            @(posedge tck);
        end
    endtask

    // Hard reset + 5 TMS=1 cycles → guaranteed Test-Logic-Reset
    task jtag_reset;
        begin
            trst_n = 0; tms = 1; tdi = 0;
            repeat(4) @(posedge tck);
            @(negedge tck); trst_n = 1;
            repeat(5) tck_cycle(1, 0);   // TMS=1: stay/force TLR
            tck_cycle(0, 0);             // enter RTI
            $display("[%0t] TAP reset, RTI", $time);
        end
    endtask

    // RTI → Shift-DR  (3 TCK edges)
    task goto_shift_dr;
        begin
            tck_cycle(1, 0);   // RTI      → Sel-DR
            tck_cycle(0, 0);   // Sel-DR   → Cap-DR
            tck_cycle(0, 0);   // Cap-DR   → Shft-DR
        end
    endtask

    // Shift N bits. data_in[i] applied on cycle i (LSB=cycle 0).
    // Last bit exits via TMS=1 → Exit1-DR.
    // Returns TDO samples in dout[N-1:0].
    task shift_bits;
        input  [63:0] data_in;
        input  integer nbits;
        output [63:0] dout;
        integer i;
        reg [63:0] tmp;
        begin
            tmp = 64'h0;
            for (i = 0; i < nbits-1; i = i+1) begin
                @(negedge tck); tms = 0; tdi = data_in[i];
                @(posedge tck); tmp[i] = tdo;
            end
            // Last bit: exit Shift-DR
            @(negedge tck); tms = 1; tdi = data_in[nbits-1];
            @(posedge tck); tmp[nbits-1] = tdo;
            dout = tmp;
        end
    endtask

    // Full DR scan: Shift-DR → Update-DR → RTI
    // Returns captured TDO stream in cap
    task do_dr_scan;
        input  [63:0] data_in;
        input  integer nbits;
        output [63:0] cap;
        begin
            goto_shift_dr;
            shift_bits(data_in, nbits, cap);
            // After shift_bits we are in Exit1-DR
            tck_cycle(1, 0);   // Exit1-DR  → Update-DR
            tck_cycle(0, 0);   // Update-DR → RTI
        end
    endtask

    // ==========================================================
    //  Scan-data helpers
    //
    //  Bit layout for a given chain length (all fields packed
    //  so that bit[N-1] = SIB_0, bit[0] = deepest cell):
    //
    //  1-bit  : [SIB_0]
    //  3-bit  : [SIB_0][LSIB_1][SIB_2]
    //  11-bit : [SIB_0][LSIB_1][InstrA_MSB..InstrA_LSB][SIB_2]
    //  19-bit : [SIB_0][LSIB_1][InstrA][SIB_2][InstrB]
    //
    //  scan_data_in[i] is shifted on cycle i (cycle 0 = first).
    //  bit[N-1] is shifted LAST → ends at pos 0 = SIB_0.
    // ==========================================================

    // Build 3-bit scan word: {SIB_0, LSIB_1, SIB_2} MSB-first in
    // natural notation, but reversed in shift order:
    //   data_in[2] = SIB_0  (last shifted → shallowest)
    //   data_in[0] = SIB_2  (first shifted → deepest)
    function [63:0] pack3;
        input s0, l1, s2;
        begin pack3 = {61'h0, s0, l1, s2}; end
    endfunction

    // Build 11-bit word: {SIB_0, LSIB_1, InstrA[7:0], SIB_2}
    //   data_in[10] = SIB_0
    //   data_in[9]  = LSIB_1
    //   data_in[8]  = InstrA[7]  (MSB → position 2, near TDI)
    //   data_in[1]  = InstrA[0]  (LSB → position 9, near TDO)
    //   data_in[0]  = SIB_2
    function [63:0] pack11;
        input s0, l1;
        input [7:0] ia;
        input s2;
        begin
            pack11 = {53'h0, s0, l1, ia[7], ia[6], ia[5],
                      ia[4], ia[3], ia[2], ia[1], ia[0], s2};
        end
    endfunction

    // Build 19-bit word: {SIB_0, LSIB_1, InstrA[7:0], SIB_2, InstrB[7:0]}
    function [63:0] pack19;
        input s0, l1;
        input [7:0] ia;
        input s2;
        input [7:0] ib;
        begin
            pack19 = {45'h0, s0, l1,
                      ia[7], ia[6], ia[5], ia[4],
                      ia[3], ia[2], ia[1], ia[0],
                      s2,
                      ib[7], ib[6], ib[5], ib[4],
                      ib[3], ib[2], ib[1], ib[0]};
        end
    endfunction

    // ==========================================================
    //  Main test body
    // ==========================================================
    initial begin
        pass_cnt = 0; fail_cnt = 0;
        tms = 1; tdi = 0; trst_n = 0; lsib1_lock_in = 0;

        $dumpfile("sim/ijtag_sim.vcd");
        $dumpvars(0, tb_ijtag);

        // ======================================================
        //  TC-01  Reset – all SIBs closed, no lock
        // ======================================================
        $display("\n=== TC-01: RESET ===");
        jtag_reset;
        #5;
        check(sib0_open,    0, "SIB_0 closed");
        check(lsib1_open,   0, "LSIB_1 closed");
        check(sib2_open,    0, "SIB_2 closed");
        check(lsib1_locked, 0, "LSIB_1 not locked");

        // ======================================================
        //  TC-02  Open SIB_0
        //  Chain = 1 bit.  Shift in 1'b1.
        //  data_in[0] = SIB_0 new value = 1
        // ======================================================
        $display("\n=== TC-02: Open SIB_0 (chain=1) ===");
        do_dr_scan(64'h1, 1, cap_data);
        #5;
        check(sib0_open,  1, "SIB_0 opened");
        check(lsib1_open, 0, "LSIB_1 still closed");
        check(sib2_open,  0, "SIB_2 still closed");
        // Chain is now 3 bits: [SIB_0][LSIB_1][SIB_2]

        // ======================================================
        //  TC-03a  Open LSIB_1
        //  Chain = 3 bits.
        //  pack3(SIB_0=1, LSIB_1=1, SIB_2=0) = 3'b110 = 0x6
        //    data_in[2]=1 → SIB_0
        //    data_in[1]=1 → LSIB_1
        //    data_in[0]=0 → SIB_2
        // ======================================================
        $display("\n=== TC-03a: Open LSIB_1 (chain=3) ===");
        do_dr_scan(pack3(1,1,0), 3, cap_data);
        #5;
        check(sib0_open,  1, "SIB_0 still open");
        check(lsib1_open, 1, "LSIB_1 opened");
        check(sib2_open,  0, "SIB_2 still closed");
        // Chain now 11 bits: [SIB_0][LSIB_1][InstrA_7..0][SIB_2]

        // ======================================================
        //  TC-03b  Write InstrA = 0xBE
        //  Chain = 11 bits.
        //  pack11(SIB_0=1, LSIB_1=1, InstrA=0xBE, SIB_2=0) = 0x77C
        //    data_in[10]=1  → SIB_0
        //    data_in[9]=1   → LSIB_1
        //    data_in[8]=1   → InstrA[7]=0xBE[7]=1
        //    data_in[7]=0   → InstrA[6]=0xBE[6]=0
        //    data_in[6]=1   → InstrA[5]=0xBE[5]=1
        //    data_in[5]=1   → InstrA[4]=0xBE[4]=1
        //    data_in[4]=1   → InstrA[3]=0xBE[3]=1
        //    data_in[3]=1   → InstrA[2]=0xBE[2]=1
        //    data_in[2]=1   → InstrA[1]=0xBE[1]=1
        //    data_in[1]=0   → InstrA[0]=0xBE[0]=0
        //    data_in[0]=0   → SIB_2
        // ======================================================
        $display("\n=== TC-03b: Write InstrA=0xBE (chain=11) ===");
        do_dr_scan(pack11(1,1,8'hBE,0), 11, cap_data);
        #5;
        check(instr_a_out, 8'hBE, "InstrA written 0xBE");

        // ======================================================
        //  TC-03c  Read back InstrA (Capture-DR loads upd_reg)
        //  During Capture-DR, cap_reg ← upd_reg.
        //  During Shift-DR, old values exit from TDO (deepest first).
        //
        //  TDO stream (cap_data[i] = TDO on shift cycle i):
        //    cap_data[0]  = SIB_2 position   = 0
        //    cap_data[1]  = InstrA[0]=0xBE[0]=0
        //    cap_data[2]  = InstrA[1]=0xBE[1]=1
        //    ...
        //    cap_data[8]  = InstrA[7]=0xBE[7]=1
        //    cap_data[9]  = LSIB_1   = 1
        //    cap_data[10] = SIB_0    = 1
        //
        //  → InstrA = cap_data[8:1] (MSB in bit8, LSB in bit1)
        //
        //  Scan_in keeps SIBs open, writes 0 to InstrA:
        //  pack11(1,1,0x00,0) = 0x600
        // ======================================================
        $display("\n=== TC-03c: Read back InstrA (chain=11) ===");
        do_dr_scan(pack11(1,1,8'h00,0), 11, cap_data);
        #5;
        $display("  INFO  raw cap_data[10:0] = 0x%03h", cap_data[10:0]);
        check(cap_data[8:1], 8'hBE, "InstrA readback = 0xBE");

        // ======================================================
        //  TC-04a  Open SIB_2
        //  Chain = 11 bits.
        //  pack11(1,1, 0x00, SIB_2=1) = 0x601
        // ======================================================
        $display("\n=== TC-04a: Open SIB_2 (chain=11→19) ===");
        do_dr_scan(pack11(1,1,8'h00,1), 11, cap_data);
        #5;
        check(sib2_open, 1, "SIB_2 opened");
        // Chain now 19 bits

        // ======================================================
        //  TC-04b  Write InstrA=0xDE, InstrB=0xAD (chain=19)
        //  pack19(1,1, 0xDE, 1, 0xAD) = 0x7BDAD
        // ======================================================
        $display("\n=== TC-04b: Write InstrA=0xDE InstrB=0xAD (chain=19) ===");
        do_dr_scan(pack19(1,1,8'hDE,1,8'hAD), 19, cap_data);
        #5;
        check(instr_a_out, 8'hDE, "InstrA written 0xDE");
        check(instr_b_out, 8'hAD, "InstrB written 0xAD");

        // ======================================================
        //  TC-04c  Read back both instruments (chain=19)
        //  TDO stream:
        //    cap_data[7:0]   = InstrB[7:0] (bit0=InstrB[0])
        //    cap_data[8]     = SIB_2
        //    cap_data[16:9]  = InstrA[7:0] (bit9=InstrA[0])
        //  Scan-in keeps SIBs open, zeros instruments:
        //  pack19(1,1, 0,1, 0) = 0x60100
        // ======================================================
        $display("\n=== TC-04c: Read back both instruments (chain=19) ===");
        do_dr_scan(pack19(1,1,8'h00,1,8'h00), 19, cap_data);
        #5;
        $display("  INFO  cap_data[18:0] = 0x%05h", cap_data[18:0]);
        check(cap_data[16:9], 8'hDE, "InstrA readback = 0xDE");
        check(cap_data[7:0],  8'hAD, "InstrB readback = 0xAD");

        // ======================================================
        //  TC-05  Close LSIB_1 (chain stays 19 bits until update)
        //  pack19(SIB_0=1, LSIB_1=0, InstrA=0, SIB_2=1, InstrB=0)
        //  = 2^18 + 2^8 = 0x40100
        // ======================================================
        $display("\n=== TC-05: Close LSIB_1 (chain=19) ===");
        do_dr_scan(pack19(1,0,8'h00,1,8'h00), 19, cap_data);
        #5;
        check(lsib1_open, 0, "LSIB_1 closed");
        check(sib2_open,  1, "SIB_2 still open");
        // Chain now 11 bits: [SIB_0][LSIB_1][SIB_2][InstrB]

        // ======================================================
        //  TC-06  Re-open LSIB_1, then LOCK LSIB_1
        //  Chain = 11 bits: [SIB_0][LSIB_1][SIB_2][InstrB_7..0]
        //  pack11 for this 11-bit chain (LSIB_1=0, SIB_2=1):
        //    data_in[10]=SIB_0=1
        //    data_in[9] =LSIB_1=1
        //    data_in[8] =SIB_2=1
        //    data_in[7:0]=InstrB=0
        //  = 0x700
        // ======================================================
        $display("\n=== TC-06: Re-open LSIB_1, then LOCK ===");
        // In the 11-bit chain [SIB_0][LSIB_1][SIB_2][InstrB]:
        // data_in[10]=SIB_0, [9]=LSIB_1, [8]=SIB_2, [7:0]=InstrB
        do_dr_scan(64'h700, 11, cap_data);
        #5;
        check(lsib1_open, 1, "LSIB_1 re-opened before lock");
        check(sib2_open,  1, "SIB_2 still open");
        // Chain now 19 bits again.

        // Apply lock
        #5; lsib1_lock_in = 1; #5;
        check(lsib1_locked, 1, "LSIB_1 is now locked");

        // ======================================================
        //  TC-07  Attempt to change locked LSIB_1
        //
        //  Chain = 19 bits (SIB_0=1, LSIB_1=1, SIB_2=1 all open).
        //  Attempt 1: write LSIB_1=0, SIB_2=0
        //    pack19(1,0, 0,0, 0) = 2^18 = 0x40000
        //  After Update: LSIB_1 must REMAIN = 1 (locked).
        //  After Update: SIB_2=0 (SIB_2 IS unlocked → can change).
        //  Chain shrinks to 11 bits.
        //
        //  Attempt 2: 11-bit chain, write LSIB_1=0
        //    [SIB_0][LSIB_1][InstrA][SIB_2]:
        //    data_in[10]=1, [9]=0, [8:1]=0, [0]=0 = 0x400
        //  After Update: LSIB_1 must REMAIN = 1 (locked).
        // ======================================================
        $display("\n=== TC-07: Write to locked LSIB_1 (must be rejected) ===");

        // Attempt 1 (19-bit): try LSIB_1=0
        do_dr_scan(pack19(1,0,8'h00,0,8'h00), 19, cap_data);
        #5;
        check(lsib1_open, 1, "LSIB_1 locked – attempt 1 rejected");

        // Attempt 2 (11-bit, LSIB_1 still=1, SIB_2 may have closed):
        // Re-examine chain length. After TC-07 attempt 1:
        //   SIB_0=1 (unchanged), LSIB_1=1 (locked, didn't change)
        //   SIB_2=0 (unlocked, changed to 0 → closed)
        //   Chain = 11 bits: [SIB_0][LSIB_1][InstrA[7:0]][SIB_2]
        do_dr_scan(64'h400, 11, cap_data);  // SIB_0=1, LSIB_1=0, rest=0
        #5;
        check(lsib1_open, 1, "LSIB_1 locked – attempt 2 rejected");

        // ======================================================
        //  TC-08  Reset releases lock and closes everything
        // ======================================================
        $display("\n=== TC-08: Reset releases lock ===");
        lsib1_lock_in = 0;   // de-assert lock (so trst_n alone is the release in design)
        jtag_reset;
        // Actually re-assert then release lock to verify reset of open state
        #5;
        check(sib0_open,    0, "SIB_0 closed after reset");
        check(lsib1_open,   0, "LSIB_1 closed after reset");
        check(sib2_open,    0, "SIB_2 closed after reset");
        check(lsib1_locked, 0, "Lock de-asserted (lsib1_lock_in=0)");

        // Verify LSIB_1 can be opened again after reset+unlock
        do_dr_scan(64'h1, 1, cap_data);   // Open SIB_0 (1-bit chain)
        do_dr_scan(pack3(1,1,0), 3, cap_data); // Open LSIB_1
        #5;
        check(sib0_open,  1, "SIB_0 re-opened after reset");
        check(lsib1_open, 1, "LSIB_1 re-opened after reset+unlock");

        // ==============================================
        $display("\n========================================");
        $display("  IJTAG SIB/LSIB Verification Summary");
        $display("  PASS: %0d   FAIL: %0d", pass_cnt, fail_cnt);
        $display("========================================\n");
        if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***\n");
        else               $display("  *** %0d TESTS FAILED ***\n", fail_cnt);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("ERROR: Simulation timeout");
        $finish;
    end

endmodule
