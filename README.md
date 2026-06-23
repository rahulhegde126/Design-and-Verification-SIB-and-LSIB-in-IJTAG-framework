# IJTAG SIB & LSIB — IEEE 1687 RTL Implementation

Design and verification of **Segment Insertion Bit (SIB)** and **Locked Segment Insertion Bit (LSIB)** in the IJTAG framework, implemented in Verilog HDL.

> PES University · Electronics & Communication Engineering

---

## What is this project?

Modern chips have hundreds of internal test components. Classic JTAG puts them all in one long chain — to reach one register, you must shift through all of them. **IJTAG (IEEE 1687)** solves this by adding **SIBs** — 1-bit gates that can bypass or include any branch of the chain on demand.

This project implements a small IJTAG network with:
- A **SIB** — opens/closes a segment of the scan chain
- An **LSIB** — same as SIB, but with a hardware lock (e.g. an OTP fuse) that permanently blocks changes after deployment
- Two 8-bit test instruments gated behind them

---

## File Overview

| File | Description |
|---|---|
| `tap_fsm.v` | 16-state JTAG TAP controller (IEEE 1149.1) |
| `sib.v` | Segment Insertion Bit |
| `lsib.v` | Locked Segment Insertion Bit |
| `scan_reg.v` | Generic N-bit scan register (models a test instrument) |
| `ijtag_top.v` | Top-level — wires everything together |
| `tb_ijtag.v` | Self-checking testbench |

---

## Network Topology

```
TDI ──► [ SIB_0 ] ──► [ LSIB_1 ] ──► [ Instrument A : 8-bit ]
                           │
                      [ SIB_2 ] ──► [ Instrument B : 8-bit ]
                           │
                          TDO
```

The chain length changes dynamically based on which SIBs are open:

| SIB_0 | LSIB_1 | SIB_2 | Chain Length |
|:---:|:---:|:---:|:---:|
| 0 | — | — | 1 bit |
| 1 | 0 | 0 | 3 bits |
| 1 | 1 | 0 | 11 bits |
| 1 | 0 | 1 | 11 bits |
| 1 | 1 | 1 | 19 bits |

---

## How SIB Works

A SIB has two registers inside:
- **`cap_reg`** — shifts data in (posedge TCK)
- **`upd_reg`** — commits the new state (negedge TCK)

The output mux is the key:
```verilog
assign so = upd_reg ? from_so : cap_reg;
//          open: data flows through segment
//          closed: segment is bypassed
```

To **open** a SIB, shift a `1` into it and trigger Update-DR.  
To **close** it, shift a `0`.

---

## How LSIB Works (Lock Mechanism)

LSIB is identical to SIB with one addition — a `lock_in` input:

```verilog
// Normal SIB:
if (sel && update_en)           upd_reg <= cap_reg;

// LSIB — blocked when locked:
if (sel && update_en && !lock_in)  upd_reg <= cap_reg;
```

| `lock_in` | Result |
|:---:|---|
| `0` | Works like a normal SIB |
| `1` | **Frozen** — no JTAG sequence can change it |

In practice, `lock_in` is driven by an OTP fuse. Before deployment: `lock_in = 0` (full access). After deployment: fuse blown → `lock_in = 1` → Instrument A permanently inaccessible.

---

## Running the Simulation

```bash
# With Icarus Verilog
iverilog -o sim_out tap_fsm.v sib.v lsib.v scan_reg.v ijtag_top.v tb_ijtag.v
vvp sim_out
```

Expected result:
```
PASS: 30   FAIL: 0
*** ALL TESTS PASSED ***
```

---

## Test Cases

| TC | What it tests |
|---|---|
| TC-01 | Reset — all SIBs closed |
| TC-02 | Open SIB_0, chain grows 1→3 bits |
| TC-03 | Open LSIB_1, write & read back Instrument A |
| TC-04 | Open SIB_2, write & read both instruments |
| TC-05 | Close LSIB_1 |
| TC-06 | Re-open LSIB_1, then assert lock |
| TC-07 | Try to change locked LSIB_1 — must be rejected |
| TC-08 | Reset clears everything; LSIB_1 works again after unlock |

---

## Synthesis (Cadence Genus)

| Metric | Value |
|---|---|
| Cell count | 186 |
| Total area | 2404.454 units |
| Total power | ~71.1 µW |
| Timing slack | +2 ps (timing met) |
