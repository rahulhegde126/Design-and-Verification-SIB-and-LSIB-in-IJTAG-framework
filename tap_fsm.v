// ============================================================
//  tap_fsm.v  –  JTAG TAP Controller FSM (IEEE 1149.1)
//  Used as the access engine for IJTAG (IEEE 1687) networks.
//
//  Outputs:
//    capture_dr  – High during Capture-DR state
//    shift_dr    – High during Shift-DR state
//    update_dr   – High during Update-DR state
//    sel_dr      – High from Capture-DR through Update-DR
//    capture_ir  – High during Capture-IR state
//    shift_ir    – High during Shift-IR state
//    update_ir   – High during Update-IR state
//    tlr         – High in Test-Logic-Reset state
// ============================================================
`timescale 1ns/1ps

module tap_fsm (
    input  wire  tck,
    input  wire  tms,
    input  wire  trst_n,     // Async active-low reset

    // DR scan controls (fed to SIB / LSIB scan chains)
    output reg   capture_dr,
    output reg   shift_dr,
    output reg   update_dr,
    output reg   sel_dr,     // DR scan path active

    // IR scan controls
    output reg   capture_ir,
    output reg   shift_ir,
    output reg   update_ir,

    output reg   tlr         // Test-Logic-Reset
);

    // ---- State encoding ----------------------------------------
    localparam [3:0]
        S_TLR    = 4'd0,
        S_RTI    = 4'd1,
        S_SEL_DR = 4'd2,
        S_CAP_DR = 4'd3,
        S_SHF_DR = 4'd4,
        S_EX1_DR = 4'd5,
        S_PAU_DR = 4'd6,
        S_EX2_DR = 4'd7,
        S_UPD_DR = 4'd8,
        S_SEL_IR = 4'd9,
        S_CAP_IR = 4'd10,
        S_SHF_IR = 4'd11,
        S_EX1_IR = 4'd12,
        S_PAU_IR = 4'd13,
        S_EX2_IR = 4'd14,
        S_UPD_IR = 4'd15;

    reg [3:0] state, nxt;

    // ---- State register ----------------------------------------
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) state <= S_TLR;
        else         state <= nxt;
    end

    // ---- Next-state combinational logic ------------------------
    always @(*) begin
        case (state)
            S_TLR:    nxt = tms ? S_TLR    : S_RTI;
            S_RTI:    nxt = tms ? S_SEL_DR : S_RTI;
            S_SEL_DR: nxt = tms ? S_SEL_IR : S_CAP_DR;
            S_CAP_DR: nxt = tms ? S_EX1_DR : S_SHF_DR;
            S_SHF_DR: nxt = tms ? S_EX1_DR : S_SHF_DR;
            S_EX1_DR: nxt = tms ? S_UPD_DR : S_PAU_DR;
            S_PAU_DR: nxt = tms ? S_EX2_DR : S_PAU_DR;
            S_EX2_DR: nxt = tms ? S_UPD_DR : S_SHF_DR;
            S_UPD_DR: nxt = tms ? S_SEL_DR : S_RTI;
            S_SEL_IR: nxt = tms ? S_TLR    : S_CAP_IR;
            S_CAP_IR: nxt = tms ? S_EX1_IR : S_SHF_IR;
            S_SHF_IR: nxt = tms ? S_EX1_IR : S_SHF_IR;
            S_EX1_IR: nxt = tms ? S_UPD_IR : S_PAU_IR;
            S_PAU_IR: nxt = tms ? S_EX2_IR : S_PAU_IR;
            S_EX2_IR: nxt = tms ? S_UPD_IR : S_SHF_IR;
            S_UPD_IR: nxt = tms ? S_SEL_DR : S_RTI;
            default:  nxt = S_TLR;
        endcase
    end

    // ---- Output decode (combinational) -------------------------
    always @(*) begin
        capture_dr = (state == S_CAP_DR);
        shift_dr   = (state == S_SHF_DR);
        update_dr  = (state == S_UPD_DR);
        capture_ir = (state == S_CAP_IR);
        shift_ir   = (state == S_SHF_IR);
        update_ir  = (state == S_UPD_IR);
        tlr        = (state == S_TLR);

        // sel_dr: active throughout a DR scan cycle
        sel_dr = (state == S_CAP_DR) || (state == S_SHF_DR) ||
                 (state == S_EX1_DR) || (state == S_PAU_DR) ||
                 (state == S_EX2_DR) || (state == S_UPD_DR);
    end

endmodule
