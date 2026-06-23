// ============================================================
//  ijtag_top.v  –  IJTAG Network Top-Level
//
//  Hierarchical IJTAG network demonstrating SIB and LSIB.
//
//  Scan-chain topology (TDI → TDO):
//  ─────────────────────────────────────────────────────────
//
//   TDI ──► [SIB_0]
//                │  SIB_0=1: segment inserted
//                ▼
//           [LSIB_1]──►(LSIB_1=1)──►[Instr_A : 8-bit]
//                │
//                ▼ (LSIB_1 SO chains into SIB_2 SI)
//           [SIB_2] ──►(SIB_2=1) ──►[Instr_B : 8-bit]
//                │
//                └── back to SIB_0.from_so ──► TDO
//
//  Dynamic chain lengths:
//   SIB_0=0                             →  1 bit
//   SIB_0=1, LSIB_1=0, SIB_2=0         →  3 bits
//   SIB_0=1, LSIB_1=1, SIB_2=0         → 11 bits
//   SIB_0=1, LSIB_1=0, SIB_2=1         → 11 bits
//   SIB_0=1, LSIB_1=1, SIB_2=1         → 19 bits
//
//  Lock:
//   lsib1_lock_in – drive high to freeze LSIB_1's update_reg
// ============================================================
`timescale 1ns/1ps

module ijtag_top (
    input  wire       tck,
    input  wire       tms,
    input  wire       trst_n,
    input  wire       tdi,
    output wire       tdo,

    input  wire       lsib1_lock_in,   // External lock for LSIB_1
    output wire       lsib1_locked,    // Lock status monitor

    output wire [7:0] instr_a_out,
    output wire [7:0] instr_b_out,

    output wire       sib0_open,
    output wire       lsib1_open,
    output wire       sib2_open
);

    // ----------------------------------------------------------
    // TAP controller
    // ----------------------------------------------------------
    wire cap_dr, shft_dr, upd_dr, sel_dr;
    wire cap_ir, shft_ir, upd_ir, tlr_out;

    tap_fsm u_tap (
        .tck        (tck),   .tms        (tms),
        .trst_n     (trst_n),
        .capture_dr (cap_dr), .shift_dr   (shft_dr),
        .update_dr  (upd_dr), .sel_dr     (sel_dr),
        .capture_ir (cap_ir), .shift_ir   (shft_ir),
        .update_ir  (upd_ir), .tlr        (tlr_out)
    );

    // ----------------------------------------------------------
    // SIB_0 – top-level gating SIB
    // ----------------------------------------------------------
    wire sib0_so, sib0_to_si, sib0_to_sel, sib0_from_so;

    sib u_sib0 (
        .tck        (tck),    .trst_n     (trst_n),
        .si         (tdi),    .from_so    (sib0_from_so),
        .sel        (sel_dr), .capture_en (cap_dr),
        .shift_en   (shft_dr),.update_en  (upd_dr),
        .so         (sib0_so),.to_si      (sib0_to_si),
        .to_sel     (sib0_to_sel), .sib_val(sib0_open)
    );

    assign tdo = sib0_so;

    // ----------------------------------------------------------
    // LSIB_1 – locked SIB inside SIB_0 segment
    // ----------------------------------------------------------
    wire lsib1_so, lsib1_to_si, lsib1_to_sel;
    wire instr_a_so;

    lsib u_lsib1 (
        .tck        (tck),         .trst_n     (trst_n),
        .si         (sib0_to_si),  .from_so    (instr_a_so),
        .sel        (sib0_to_sel), .capture_en (cap_dr),
        .shift_en   (shft_dr),     .update_en  (upd_dr),
        .so         (lsib1_so),    .to_si      (lsib1_to_si),
        .to_sel     (lsib1_to_sel),.sib_val    (lsib1_open),
        .lock_in    (lsib1_lock_in),.is_locked (lsib1_locked)
    );

    // ----------------------------------------------------------
    // Instrument A – 8-bit under LSIB_1
    // ----------------------------------------------------------
    scan_reg #(.WIDTH(8)) u_instr_a (
        .tck        (tck),           .trst_n     (trst_n),
        .si         (lsib1_to_si),   .sel        (lsib1_to_sel),
        .capture_en (cap_dr),        .shift_en   (shft_dr),
        .update_en  (upd_dr),        .so         (instr_a_so),
        .func_in    (8'h00),         .func_out   (instr_a_out)
    );

    // ----------------------------------------------------------
    // SIB_2 – second SIB, after LSIB_1 in SIB_0's segment
    // ----------------------------------------------------------
    wire sib2_so, sib2_to_si, sib2_to_sel;
    wire instr_b_so;

    sib u_sib2 (
        .tck        (tck),         .trst_n     (trst_n),
        .si         (lsib1_so),    .from_so    (instr_b_so),
        .sel        (sib0_to_sel), .capture_en (cap_dr),
        .shift_en   (shft_dr),     .update_en  (upd_dr),
        .so         (sib2_so),     .to_si      (sib2_to_si),
        .to_sel     (sib2_to_sel), .sib_val    (sib2_open)
    );

    assign sib0_from_so = sib2_so;

    // ----------------------------------------------------------
    // Instrument B – 8-bit under SIB_2
    // ----------------------------------------------------------
    scan_reg #(.WIDTH(8)) u_instr_b (
        .tck        (tck),          .trst_n     (trst_n),
        .si         (sib2_to_si),   .sel        (sib2_to_sel),
        .capture_en (cap_dr),       .shift_en   (shft_dr),
        .update_en  (upd_dr),       .so         (instr_b_so),
        .func_in    (8'h00),        .func_out   (instr_b_out)
    );

endmodule
