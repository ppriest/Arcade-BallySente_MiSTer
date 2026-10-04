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

## Video

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| A mid-frame palette-bank switch lands 16 lines too low | `balsente_v.cpp` `palette_select_w()` calls `m_screen->update_partial(m_screen->vpos() - 1 + BALSENTE_VBEND)`. `screen_device::vpos()` already returns an ABSOLUTE raster line — `(m_visarea.max_y + 1 + delta / m_scantime) % m_height` — so adding `BALSENTE_VBEND` again moves the boundary 16 lines down the screen. Measured on `cshift` frame 2285: the write happens at raster line 61, which is visible row 45, and MAME changes the bank at visible row **61**; forcing the model to any other row costs 195 pixels or more, and to row 45 costs 3,346. Shrike Avenger's sprite-bank select (`shrike_sprite_select_w()`) has the same call. | copies, both: `rtl/video/video.sv` delays the palette bank and `rtl/balsente_core.sv` Shrike's sprite bank, whole lines, so a write in raster line v shows from v + 16. Until the palette bank's delay was added this entry said "copies" while the RTL applied the bank at the beam, 16 rows earlier; a synthetic switch in `sim/video_tb` (0 then 3 at row 45) now lands on row 45 exactly | A photograph or a capture of the real board on a frame that switches. The hardware has no reason to delay — the bank feeds the palette lookup directly, so it should change within a line of the write. |

## Main board

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| An undriven address reads back 0x00 | MAME returns its unmapped value, 0x00, for an address with no handler, and the X2212 NOVRAMs return `(nibble) \| (space.unmap() & 0xf0)` -- so the top half of every NOVRAM byte is 0 too | **differs, deliberately.** `rtl/main_bus.sv` floats: an undriven read returns the last value the data bus carried, and a NOVRAM read returns that in the top half with the chip's nibble in the bottom. That is what a TTL board does, and `cshift` does read the write-only LS259 at 0x980c and 0x9810 | A probe on the real board, or a schematic showing a pull-up or bus holder. The instruction that reads those addresses is a `CLR`, which discards what it read, so nothing yet depends on the value | 
| The hardware random source runs 156x too fast | `balsente_m.cpp` `random_num_r()` indexes a 17-bit polynomial table by `total_cycles * 12.5`, computed as `(cc<<3)+(cc<<2)+(cc>>1)`. Its own comment says "CPU runs at 1.25MHz, noise source at 100kHz --> multiply by 12.5" -- but 1.25 MHz / 100 kHz = 12.5 means the noise source advances once every 12.5 CPU cycles, so the index should be DIVIDED. Multiplying advances the sequence 12.5 steps a cycle instead of 0.08, which is 156 times too fast. | copies, in `rtl/main_bus.sv`: 12 steps on an even CPU cycle and 13 on an odd one | A probe on the real board's noise source. It cannot matter to a game -- both are random -- but a different value desynchronises a bus-trace comparison on the first read, which is why the core follows MAME rather than the arithmetic. |
| Shrike Avenger's sprite bank is data bit 0, not bit 7 | `balsente_v.cpp` `shrike_sprite_select_w()` picks the bank with `(data & 0x80 >> 7) ^ 1`. `>>` binds tighter than `&`, so that is `(data & 1) ^ 1`: bit 0 clear selects the upper 64 KB. The bit 7 the expression spells is probably what was meant; the game writes 0x00, 0x80 and 0xFF there (misteraddons' Lua tap), so the two readings differ on 0x80. | copies, in `rtl/shrike_board.sv` | A schematic or the real board. The game looking right in MAME with bit 0 is the evidence for it. |
| Shrike Avenger's 68000 reports its motors OK | `balsente_m.cpp` `shrike_shared_6809_r()` returns 0 for offset 6, "return OK for 68k status register until motors hooked up"; the 68000's own writes there are not seen by the 6809 | copies, in `rtl/shrike_board.sv` (0x9E06 reads 0) | The motion base, which neither MAME nor the core models |

## Sound

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| The 6VB's audio enable | `sente6vb.cpp` `counter_control_w()` applies bit 0 as each CEM3394's output gain only when the bit CHANGES, and the gain starts at 1. The program holds bit 0 low through its boot calibration and sets it at 9.47 s (cshift, snakepit, gimeabrk, nametune traces), so MAME plays the calibration sweep that the program asked to be muted | does NOT copy: the core's gain is bit 0 from reset, so the first ~9.5 s after boot are silent. `scripts/sente6vb_audio.py` reproduces MAME's behaviour by default so its recordings can still be compared | A recording of a real board powering up. The bit's name in MAME's own comment, "enables/disables audio", is the argument for following it |
| What clocks the counter-0 flip-flop | `sente6vb.cpp` `update_counter_0_timer()`: a **periodic timer**, not an oscillator, running at the **highest** frequency among voices whose `final_gain() > 0.1`, using `filt_freq()` instead of `vco_freq()` when `filt_res() > 3`, and **no timer at all** when no voice is audible. Each firing passes the control register's D bit through the flip-flop (`clock_counter_0_ff`), so a constant D gives no clock edges at all. It is armed when counter 0's gate rises and only if it was not already running, restarted from zero by **every** `chip_select_w()` while it runs, and cancelled when the gate falls. The driver does not say what the board actually does; this is a model chosen to make the self-calibration converge. | copies, in `sim/calib_tb` and in the core's eventual voice mux | The 6VB schematic, or a probe on the real board's flip-flop clock pin. This decides which voice the calibration is actually measuring, so it is worth settling before the sound is called accurate. |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| `T80` (MiSTer-devel, `830fd0315f0a`) | MAME's `z80` runs `EX (SP),IX` as read (SP), read (SP+1), write (SP+1), write (SP) | reads (SP), writes (SP), reads (SP+1), writes (SP+1) | The accesses, their addresses and their data are identical; only the order within the one instruction differs, and nothing else on this board is on the bus during it | A logic-analyser capture of a real Z80 executing `EX (SP),HL`. Zilog's timing diagram shows both reads before both writes, which is MAME's order, so T80 is probably the one that is wrong -- but it cannot affect this core |
| `mc6809i.v` (Greg Miller, jotego fork) | MAME's `m6809` tests an interrupt flag at instruction boundaries, the flag being set by a timer at an exact time | samples `nIRQ` on **Q**, in the last cycle of an instruction, which is what the 6809 does | The sampling point is silicon behaviour; MAME's is an emulation convenience. The effect is that an interrupt arriving inside a cycle is taken one instruction later | A logic-analyser capture of a real 68B09E taking an interrupt whose line rises mid-cycle. It cannot affect a game: the instruction completes and the handler runs either way |
| `mc6809i.v` (Greg Miller, jotego fork) | MAME's `m6809` drives a program address on many non-VMA cycles, and prefetches the byte after a `JSR` operand (`E04C` in `sentetst`) | drives `$FFFF` on those cycles, and prefetches the subroutine's first byte instead | The 6809E floats `$FFFF` on non-VMA cycles by design; the module is cycle-accurate and silicon-derived, MAME's dead-cycle addresses are an emulation artefact with no functional effect | A logic-analyser capture of a real 68B09E's address bus during dead cycles. Nothing on this board reads the bus during them, so it cannot affect the core |

Evidence for the T80 row: `scripts/mame_boot_trace.py cshift 1200000 --cpu :audio6vb:audiocpu
--space program --addr-hi 0xffff --tag sente6vb` against `sim/calib_tb`'s program trace --
1,200,000 accesses, every read identical, every write identical in address and data, and the only
ordering differences the 27,436 halves of `EX (SP),IX` from access 752,818 on.

Evidence for the interrupt-sampling row: `sim/mainbus_tb` against `cshift`, 400,000 cycles.
The RTL's interrupt timer asserts at CPU cycle 79,361 and MAME begins its stack pushes at
79,363, so the timer agrees; the RTL begins its own at 79,369 and pushes a PC two bytes
higher, one instruction later. **The streams resynchronise between interrupts**: 70 clusters
of difference over 400,000 cycles, spaced one IRQ period apart, mean 80 cycles long, 49 of
them containing a stack write. 1,304 functional differences in total, 0.326%.

Evidence for the dead-cycle row: `scripts/classify_trace_diff.py sentetst` over 400,000 bus cycles —
12,171 differences (3.04%), **all** of them a non-VMA or prefetch address choice, **zero**
functional differences, and all 52,232 writes identical in address, data and order
(`scripts/compare_boot_trace.py compare sentetst`). Saved at `debug/sentetst-boot/classify.txt`.
