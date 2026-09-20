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

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| `mc6809i.v` (Greg Miller, jotego fork) | MAME's `m6809` drives a program address on many non-VMA cycles, and prefetches the byte after a `JSR` operand (`E04C` in `sentetst`) | drives `$FFFF` on those cycles, and prefetches the subroutine's first byte instead | The 6809E floats `$FFFF` on non-VMA cycles by design; the module is cycle-accurate and silicon-derived, MAME's dead-cycle addresses are an emulation artefact with no functional effect | A logic-analyser capture of a real 68B09E's address bus during dead cycles. Nothing on this board reads the bus during them, so it cannot affect the core |

Evidence for the row above: `scripts/classify_trace_diff.py sentetst` over 400,000 bus cycles —
12,171 differences (3.04%), **all** of them a non-VMA or prefetch address choice, **zero**
functional differences, and all 52,232 writes identical in address, data and order
(`scripts/compare_boot_trace.py compare sentetst`). Saved at `debug/sentetst-boot/classify.txt`.
