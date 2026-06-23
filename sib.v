// ============================================================
//  sib.v  –  Segment Insertion Bit (IEEE 1687 IJTAG)
//
//  The SIB is the fundamental building block of an IJTAG
//  network. It is a 1-bit scan cell that dynamically inserts
//  or bypasses an instrument segment in the active scan chain.
//
//  Scan-chain behaviour (controlled by update_reg):
//  ┌───────────────────────────────────────────────────────┐
//  │  update_reg = 0  │  SO ← SI          (segment BYPASSED)│
//  │  update_reg = 1  │  SO ← from_so     (segment INSERTED) │
//  └───────────────────────────────────────────────────────┘
//
//  The segment's select (to_sel) is asserted only when both
//  the parent select (sel) and update_reg are high.
//
//  Timing:
//    cap_reg  – sampled on RISING  edge of TCK
//    upd_reg  – sampled on FALLING edge of TCK  (JTAG std)
//
//  Ports:
//    si        – Scan input (from previous chain element)
//    from_so   – Scan output from the inserted segment's tail
//    sel       – Segment selected by parent (TAP or enclosing SIB)
//    capture_en– High during Capture-DR TAP state
//    shift_en  – High during Shift-DR   TAP state
//    update_en – High during Update-DR  TAP state
//    so        – Scan output to next chain element
//    to_si     – Scan input  to segment head
//    to_sel    – Select for all elements inside this segment
//    sib_val   – Current update_reg value (for monitoring)
// ============================================================
`timescale 1ns/1ps

module sib (
    input  wire  tck,
    input  wire  trst_n,     // Async active-low reset

    // Scan interface
    input  wire  si,         // Scan data in
    input  wire  from_so,    // Scan data from segment tail
    input  wire  sel,        // Select from parent

    // TAP state strobes
    input  wire  capture_en,
    input  wire  shift_en,
    input  wire  update_en,

    // Outputs
    output wire  so,         // Scan data out (to next element)
    output wire  to_si,      // Feed into segment head
    output wire  to_sel,     // Cascaded select into segment
    output wire  sib_val     // Readable SIB state (update_reg)
);

    reg cap_reg;   // Capture / shift register  (posedge TCK)
    reg upd_reg;   // Update  register          (negedge TCK)

    // ----------------------------------------------------------
    // CAPTURE & SHIFT  (rising edge)
    // ----------------------------------------------------------
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            cap_reg <= 1'b0;
        end else if (sel && capture_en) begin
            cap_reg <= upd_reg;   // reflect current segment state
        end else if (sel && shift_en) begin
            cap_reg <= si;        // shift new SIB value in
        end
    end

    // ----------------------------------------------------------
    // UPDATE  (falling edge – per IEEE 1149.1 / 1687 spec)
    // ----------------------------------------------------------
    always @(negedge tck or negedge trst_n) begin
        if (!trst_n) begin
            upd_reg <= 1'b0;      // power-on: segment excluded (safe)
        end else if (sel && update_en) begin
            upd_reg <= cap_reg;   // commit shifted value
        end
    end

    // ----------------------------------------------------------
    // Scan-chain bypass / insert mux
    // ----------------------------------------------------------
    assign so      = upd_reg ? from_so : cap_reg; // include or bypass
    assign to_si   = cap_reg;                     // registered serial output → segment
    assign to_sel  = sel & upd_reg;
    assign sib_val = upd_reg;

endmodule
