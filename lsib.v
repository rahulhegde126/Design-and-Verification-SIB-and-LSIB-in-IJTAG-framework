// ============================================================
//  lsib.v  –  Locked Segment Insertion Bit (IEEE 1687 IJTAG)
//
//  Extends the standard SIB with a LOCK mechanism.
//  When lock_in is asserted the update_reg is frozen:
//  scan-path writes are silently discarded, so the segment
//  stays in its last committed open/closed state.
//
//  Architecture
//  ─────────────────────────────────────────────────────────
//   cap_reg  – 1-bit capture / shift register (posedge TCK)
//   upd_reg  – 1-bit update register          (negedge TCK)
//              update is BLOCKED when lock_in = 1
//
//  Ports (same as sib.v, plus):
//    lock_in   – Async active-high lock (from OTP / fuse / security ctrl)
//    is_locked – Mirror of lock_in for monitoring
// ============================================================
`timescale 1ns/1ps

module lsib (
    input  wire  tck,
    input  wire  trst_n,

    input  wire  si,
    input  wire  from_so,
    input  wire  sel,
    input  wire  capture_en,
    input  wire  shift_en,
    input  wire  update_en,

    output wire  so,
    output wire  to_si,
    output wire  to_sel,
    output wire  sib_val,

    input  wire  lock_in,
    output wire  is_locked
);

    reg cap_reg;
    reg upd_reg;

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)                  cap_reg <= 1'b0;
        else if (sel && capture_en)   cap_reg <= upd_reg;
        else if (sel && shift_en)     cap_reg <= si;
    end

    always @(negedge tck or negedge trst_n) begin
        if (!trst_n)
            upd_reg <= 1'b0;
        else if (sel && update_en && !lock_in)
            upd_reg <= cap_reg;   // LOCK GUARD: blocked when lock_in=1
    end

    assign so        = upd_reg ? from_so : cap_reg;
    assign to_si     = cap_reg;
    assign to_sel    = sel & upd_reg;
    assign sib_val   = upd_reg;
    assign is_locked = lock_in;

endmodule
