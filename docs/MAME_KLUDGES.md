# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `src/mame/bally/balsente.cpp` unless named. MAME commit: `5ae594ba`.

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

Every in-scope set is `MACHINE_SUPPORTS_SAVE` with no accuracy flag; the driver's own "Known
bugs" list is the accuracy statement instead (CEM3394 emulation imperfect, Shrike Avenger not
working, two Maibesa sets on unemulated hardware).

## Sound

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| What clocks the counter-0 flip-flop | `sente6vb.cpp` `update_counter_0_timer()`: a **periodic timer**, not an oscillator, running at the **highest** frequency among voices whose `final_gain() > 0.1`, using `filt_freq()` instead of `vco_freq()` when `filt_res() > 3`, and **no timer at all** when no voice is audible. Each firing passes the control register's D bit through the flip-flop (`clock_counter_0_ff`), so a constant D gives no clock edges at all. It is armed when counter 0's gate rises and only if it was not already running, restarted from zero by **every** `chip_select_w()` while it runs, and cancelled when the gate falls. The driver does not say what the board actually does; this is a model chosen to make the self-calibration converge. | copies, in `sim/calib_tb` and in the core's eventual voice mux | The 6VB schematic, or a probe on the real board's flip-flop clock pin. This decides which voice the calibration is actually measuring, so it is worth settling before the sound is called accurate. |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| `T80` (MiSTer-devel, `830fd0315f0a`) | MAME's `z80` runs `EX (SP),IX` as read (SP), read (SP+1), write (SP+1), write (SP) | reads (SP), writes (SP), reads (SP+1), writes (SP+1) | The accesses, their addresses and their data are identical; only the order within the one instruction differs, and nothing else on this board is on the bus during it | A logic-analyser capture of a real Z80 executing `EX (SP),HL`. Zilog's timing diagram shows both reads before both writes, which is MAME's order, so T80 is probably the one that is wrong -- but it cannot affect this core |
| `mc6809i.v` (Greg Miller, jotego fork) | MAME's `m6809` drives a program address on many non-VMA cycles, and prefetches the byte after a `JSR` operand (`E04C` in `sentetst`) | drives `$FFFF` on those cycles, and prefetches the subroutine's first byte instead | The 6809E floats `$FFFF` on non-VMA cycles by design; the module is cycle-accurate and silicon-derived, MAME's dead-cycle addresses are an emulation artefact with no functional effect | A logic-analyser capture of a real 68B09E's address bus during dead cycles. Nothing on this board reads the bus during them, so it cannot affect the core |

Evidence for the T80 row: `scripts/mame_boot_trace.py cshift 1200000 --cpu :audio6vb:audiocpu
--space program --addr-hi 0xffff --tag sente6vb` against `sim/calib_tb`'s program trace --
1,200,000 accesses, every read identical, every write identical in address and data, and the only
ordering differences the 27,436 halves of `EX (SP),IX` from access 752,818 on.

Evidence for the mc6809i row: `scripts/classify_trace_diff.py sentetst` over 400,000 bus cycles —
12,171 differences (3.04%), **all** of them a non-VMA or prefetch address choice, **zero**
functional differences, and all 52,232 writes identical in address, data and order
(`scripts/compare_boot_trace.py compare sentetst`). Saved at `debug/sentetst-boot/classify.txt`.
