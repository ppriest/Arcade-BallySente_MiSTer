# T80 provenance

**In this repository:** copied from the Fuuki core's `rtl/cpu/t80/`, unchanged and
byte-identical. Bally/Sente's sound CPU is the Z80 on the 6VB audio board at 4 MHz
(`sente6vb.cpp:107`), driven through `T80se` with a clock enable from `clk_sys`/10.
Fuuki took it from Psikyo unchanged; the notes below are Psikyo's, and the Fuuki status
block at the end is Fuuki's evidence, not this core's.

Vendored from https://github.com/MiSTer-devel/T80, commit `830fd0315f0af5cdbcb0e703f1cea3ce4e91f538`
(2021-03-31), for use as the sound-CPU core (Z80 on SH201B/KA302C; LZ8420M on SH403/SH404 is
expected to be T80-compatible, per docs/ROADMAP.md's component reuse map -- not yet confirmed,
Phase 2 concern).

License: 3-clause BSD-style (stated in each file's header, no separate LICENSE file upstream).
Original core copyright (c) 2001-2002 Daniel Wallner <jesus@opencores.org>; maintained since by
MikeJ (fpgaarcade.com) and the MiSTer-devel community (Sorgelig, TobiFlex, Bruno Duarte Gouveia).
Permissive, no copyleft obligation -- redistribution/synthesis permitted with attribution.

`T80se.vhd` is the top-level this project will instantiate: the standard synchronous wrapper
exposing the classic Z80 bus (`M1_n`/`MREQ_n`/`IORQ_n`/`RD_n`/`WR_n`/`RFSH_n`/`HALT_n`, 16-bit
`A`, 8-bit `DI`/`DO`), same interface convention nearly every MiSTer arcade core built around a
Z80 sound CPU uses. `Mode` generic: `0` = Z80 (what this project needs), `1` = Fast Z80, `2` =
8080, `3` = Game Boy.

Files kept as vendored (`T80.qip` lists the full compile set): `GBse.vhd`, `T80.vhd`, `T80a.vhd`,
`T80as.vhd`, `T80pa.vhd`, `T80s.vhd`, `T80se.vhd`, `T80sed.vhd`, `T8080se.vhd`, `T80_ALU.vhd`,
`T80_MCode.vhd`, `T80_Pack.vhd`, `T80_Reg.vhd`. Only `T80se.vhd` (plus its dependencies:
`T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Pack.vhd`, `T80_Reg.vhd`) is actually needed for
this project; the other top-levels (`GBse`, `T8080se`, `T80a`, `T80as`, `T80pa`, `T80s`,
`T80sed`) are kept vendored anyway rather than pruned, matching `T80.qip`'s own file set --
avoids having to re-derive which files are truly load-bearing if a later phase needs a different
top-level variant.

Much lower risk than TG68K.C (`rtl/cpu/tg68k/PROVENANCE.md`): T80 is the de facto standard Z80
core across the MiSTer-devel arcade ecosystem (embedded directly in dozens of cores per
docs/ROADMAP.md's survey), unlike TG68K.C being the *only* viable open 68020 option. Still
worth an independent boot spike before trusting it, same discipline as Phase 0.

## Status

- [x] Source vendored
- [x] Compiles under ModelSim-Altera 10.5b (`sim/t80_spike/`), clean 0 errors (one pre-existing
      upstream width-mismatch warning in `T80.vhd` line 685, an `and` of a 9-bit and a 4-bit
      operand -- not introduced by this project, not investigated further given T80's low prior
      risk, see below)
- [x] Boots and executes a small test program in simulation (`sim/t80_spike/tb_t80_boot.vhd`):
      fetches from address 0 (Z80 has no reset vector, unlike 68k), executes `LD A,0x42`,
      `LD (0x8000),A` (memory write), `OUT (0x00),A` (I/O write), `HALT` -- all four checked
      against expected values, PASS. Exercises opcode fetch, immediate fetch, a memory write
      cycle, and an I/O write cycle -- the classic bus protocol paths this project's actual
      memory-map wiring will depend on.
- [ ] Synthesizes/fits on the real Cyclone V (likely unnecessary as a standalone check given
      how widely this core is already proven on this exact FPGA family across other MiSTer
      cores -- revisit once the full sound subsystem is integrated instead)

**Simulation quirk, not a design issue**: `vsim -c -do "run -all; quit -f"` ran the simulation
to completion and printed PASS at 2040ns, but `quit -f` did not cleanly terminate the VHDL-only
session afterward -- the process sat idle (0% CPU) rather than exiting, needing a manual kill.
Every other testbench in this project (Verilog/SystemVerilog DUTs) has exited cleanly with the
same invocation; this may be specific to a VHDL top-level ending its process with a bare `wait;`.
Not investigated further since the actual simulation result is what matters and was captured
before the hang -- worth remembering if a future VHDL-only testbench run appears to hang: check
whether it already printed PASS/FAIL before assuming something is actually stuck.

## Status in this core

Nothing below has been run here yet. Fuuki's and Psikyo's evidence above is why this module is
low risk, not proof that this core's integration of it works.

- [x] Source vendored, byte-identical to Fuuki's copy
- [x] Compiles clean under ModelSim in this repository (`sim/vhdl.files`; one
      pre-existing upstream warning, vcom-1275 at `T80.vhd:685`, an overloaded
      `and` with mismatched lengths -- same warning Fuuki records)
- [x] **6VB sound Z80 boots the audio board's own ROM against a MAME bus trace**

Upstream ships no testbench either, so the roadmap's criterion 1 cannot be met literally for this
module any more than for `mc6809i`. The substitute is the same, and it is now **done**:

`sim/sound_cpu_tb` runs T80se against the 6VB's own 8 KB ROM, with the board's memory map and a
replay of any read outside ROM and RAM, and diffs every bus access against MAME's trace of
`:audio6vb:audiocpu` (`scripts/mame_boot_trace.py cshift 60000 --cpu :audio6vb:audiocpu
--addr-hi 0xffff --tag sente6vb`).

> **60,000 bus accesses, 0 differences. Byte-identical to MAME, reads included.**
> All 2,049 writes match in address, data and order.

That is a stronger result than `mc6809i`'s, which differs on 3% of cycles in what a dead cycle
drives. The Z80 has no equivalent: every cycle it runs is a real access.

The boot window needs no replayed reads at all -- the 6VB never touches its ACIA in the first
60,000 accesses -- so the comparison rests entirely on the CPU and the ROM.
