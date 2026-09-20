# mc6809i provenance

The SAC-I main CPU is an **MC6809E** at 1.25 MHz (`balsente.cpp:1378`). This directory holds
Greg Miller's cycle-accurate 6809 core, in the fork that converts it to clock enables.

## What is here

| File | What |
|---|---|
| `mc6809i.v` | **The module this core instantiates.** jotego's fork. |
| `mc6809i_upstream_reference.v` | Greg Miller's original, verbatim, for diffing. Not compiled. |
| `LICENSE-mc6809.md` | upstream's licence file, verbatim. |

## Upstream

- Original: <https://github.com/cavnex/mc6809>, commit `17e94a6ef163be8b79a9b15b2e814847b6062f0f`
  (2020-11-26). Greg Miller, "Cycle-Accurate MC6809/E implementation, Verilog".
- Fork taken: <https://github.com/jotego/jtcores>, `modules/jtframe/hdl/cpu/mc6809i.v`, last
  changed at commit `a543adc55b5bfc916a84d85770c8093aa18ca337` (2023-11-05, "mc6809: verilator
  lint_off SIDEEFFECT"); fetched from jtcores master `7a9167f00b86aa7339a3b2b877193df993ca84a8`.

## Licence

Upstream offers a choice of two licences (`LICENSE-mc6809.md`): a stock **BSD 3-clause** for
those who redistribute source, or a binary-only modified licence. **This project takes the
BSD 3-clause option**, which requires retaining the copyright notice and disclaimer in source
redistributions — both files keep Greg Miller's header intact.

jotego's fork carries no jotego copyright notice of its own; the file is Greg Miller's work under
his terms, with jotego's modifications. jtcores as a project is GPL-3.0, so if that is read as
covering the modifications, GPL-3.0 applies to them — either reading is compatible with this
core's GPL-3.0 licence. Recorded in `THIRD-PARTY.md`.

## What jotego changed, and why this fork rather than upstream

199 substantive lines differ (the rest of the diff is trailing whitespace). Verified by
`diff <(sed 's/[[:space:]]*$//' mc6809i_upstream_reference.v) <(sed 's/[[:space:]]*$//' mc6809i.v)`.

1. **`E`/`Q` inputs become `clk` + `cen_E`/`cen_Q` clock enables**, marked `(*direct_enable*)`.
   Upstream clocks logic on the 6809's own E and Q phases as real clocks; a MiSTer core wants one
   `clk_sys` with enables. This project's 1.25 MHz E comes from a 40 MHz `clk_sys` divided by 32,
   so the enable form is exactly what is needed — this is the reason for taking the fork.
2. **The NMI latch is made synchronous.** Upstream uses
   `always @(negedge NMISample2 or posedge wNMIClear)` — an asynchronous latch with two
   non-reset-like edges, which Quartus does not infer cleanly. The fork samples both signals on
   `cen_Q` and edge-detects them. SAC-I leaves NMI unconnected (`balsente.cpp` header: "NMI not
   connected"), so this matters less here than it does elsewhere, but the synthesisable form is
   still what we want.
3. **An `OP` output** is added, high when the bus cycle is an opcode fetch. Not needed by this
   board — SAC-I has no opcode encryption — but harmless, and it is the hook a Konami-1-style
   board would need.
4. **An `s_wr` register** flagging writes to S ("JT addition").
5. **Verilator lint pragmas** (`CASEX`, `UNOPTFLAT`, `SIDEEFFECT`) and `tracing_off`/`tracing_on`
   guards around the state visible under `VERILATOR_KEEP_CPU`, plus `SIMULATION`-only
   `alu_busy`/`stack_busy` wires.
6. `\`timescale 1ns / 1ns` is dropped.

**No local changes in this repository.** `mc6809i.v` is byte-identical to jtcores at the commit
above; `.gitattributes` marks this directory `-text` so that stays checkable and `git log -p`
here is the record of any future divergence.

## Proven where

`mc6809i.v` in this form ships in jotego's jtcores (Ghosts'n Goblins and every other 6809 board
jtframe serves). Miller's original ships in MiSTer-devel Arcade-Druaga, CoCo2_MiSTer,
MO_MiSTer, FM-7_MiSTer, and in the Arcade-Gyruss core as the basis of its KONAMI-1.

## On "run the upstream tests on arrival"

**Upstream ships no testbench.** `documentation/Validation.md` describes validation against real
hardware (a GODIL replacing the 6809 in a Williams Defender and a Vectrex), not a simulation
suite. There is therefore no upstream regression to run, and WORKFLOW §12's rule cannot be
satisfied literally.

What replaces it here, in order:

1. **jotego's differential harness**, `cores/gng/ver/6809/{6809.c,cpu_check.c,emu.h}` in jtcores —
   a C 6809 emulator run against the RTL. Evaluate and, if it is usable standalone, vendor it
   under `sim/` as this module's regression.
2. **The Phase 0 gate itself**: the CPU boots `sentetst` and matches MAME's bus trace access by
   access. That is a stronger test than any unit bench for the integration this project cares
   about, and it is a roadmap exit criterion regardless.

## What has been run

**Criterion 2 is met.** `sim/cpu_boot_tb` instantiates this module against RAM, the cartridge
ROM-window mapper and a replay of MAME's I/O reads, and logs every bus cycle:

- 400,000 bus cycles of `sentetst` from reset.
- **All 52,232 writes identical to MAME's** in address, byte lanes, data and order
  (`scripts/compare_boot_trace.py compare sentetst`).
- 12,171 of 400,000 cycles (3.04%) differ, **every one of them a non-VMA or prefetch address
  choice**, zero functional differences (`scripts/classify_trace_diff.py sentetst`, saved at
  `debug/sentetst-boot/classify.txt`). Recorded in `docs/MAME_KLUDGES.md`.
- MAME's reset sequence takes one more dead cycle than this module's before the first opcode
  fetch. Same class of difference.

No interrupt is exercised: `sentetst`'s first instruction is `ORCC #$50`, which masks IRQ and
FIRQ, and the program does not clear them inside this window — MAME's trace contains no vector
fetch, so the comparison is valid over the whole 400,000 cycles.

CPI on this code, with every memory answer in the same cycle (no stall by construction):
**4.207 bus cycles per opcode fetch**; 22.5% of all cycles are dead ($FFFF). Against 1.25 MHz
that is ~297k opcode fetches per second.

## Status

- [x] Source vendored, byte-identical to upstream fork
- [x] Licence recorded, option selected
- [x] Compiles clean under Verilator 5.050
- [x] Boots `sentetst`, 400k cycles, writes identical to MAME's
- [ ] jtcores differential harness evaluated (would add instruction coverage this boot does not reach)
- [ ] Compiles clean under ModelSim
- [x] Standalone Fmax and area at this project's settings

Criterion 4, from `rtl/cpu/synth_check` (Quartus 17.0.2, 5CSEBA6U23I7, the device
`sys/sys.tcl` selects): **1,472 ALMs (4% of the part)**, 367 registers, no block RAM, no DSP.
Against a 40 MHz `clk_sys` the worst setup slack is **+12.389 ns** and hold **+0.389 ns**, TNS
zero on every corner. Reported **Fmax 79.3 MHz** with the `cen_E` multicycle the design actually
has (the core advances one clock in 32), and **51.78 MHz** with every timing exception removed.
Either way the core closes 40 MHz with room; the pessimistic number still has 29% headroom.
