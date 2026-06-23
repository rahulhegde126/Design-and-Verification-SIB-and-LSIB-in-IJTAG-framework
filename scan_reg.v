
//  scan_reg.v  –  Generic N-bit IJTAG Instrument (Scan Register)
//
//  Models a simple scan-accessible instrument cell.
//  This is the "leaf" element in an IJTAG network — the
//  actual instrument that SIBs protect and expose.
//
//  Architecture:
//    cap_reg[N-1:0]  – shift/capture register (posedge TCK)
//    upd_reg[N-1:0]  – update  register       (negedge TCK)
//    func_reg[N-1:0] – functional / shadow register
//
//  Scan order:  cap_reg[0] is closest to SO (exits first).
//               SI enters at cap_reg[N-1].
//
//  Parameters:
//    WIDTH  – number of scan bits (default 8)
// ============================================================
`timescale 1ns/1ps

module scan_reg #(
    parameter WIDTH = 8
) (
    input  wire             tck,
    input  wire             trst_n,

    // IJTAG scan control (from parent SIB's to_sel / TAP)
    input  wire             si,
    input  wire             sel,
    input  wire             capture_en,
    input  wire             shift_en,
    input  wire             update_en,

    output wire             so,          // Scan output (data[0] exits first)

    // Functional interface
    input  wire [WIDTH-1:0] func_in,     // Functional input data to capture
    output wire [WIDTH-1:0] func_out     // Updated value to drive logic
);

    reg [WIDTH-1:0] cap_reg;
    reg [WIDTH-1:0] upd_reg;

    // ----------------------------------------------------------
    // CAPTURE & SHIFT  (posedge TCK)
    // ----------------------------------------------------------
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            cap_reg <= {WIDTH{1'b0}};
        end else if (sel && capture_en) begin
            cap_reg <= upd_reg;             // capture current update state
        end else if (sel && shift_en) begin
            // Shift: new SI enters at MSB, LSB exits as SO
            cap_reg <= {si, cap_reg[WIDTH-1:1]};
        end
    end

    // ----------------------------------------------------------
    // UPDATE  (negedge TCK)
    // ----------------------------------------------------------
    always @(negedge tck or negedge trst_n) begin
        if (!trst_n) begin
            upd_reg <= {WIDTH{1'b0}};
        end else if (sel && update_en) begin
            upd_reg <= cap_reg;
        end
    end

    assign so       = cap_reg[0];          // LSB exits first
    assign func_out = upd_reg;

endmodule
