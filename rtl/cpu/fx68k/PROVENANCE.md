# FX68K provenance

Shrike Avenger's second board is a 68000 (MAME `shrike68k_map`). This is Jorge Cwik's FX68K,
cycle-exact 68000 in SystemVerilog, GPL-3.0 (`LICENSE`, upstream's, verbatim).

| Files | Source | Changes |
|---|---|---|
| `fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, `microrom.mem`, `nanorom.mem`, `LICENSE`, `README.md`, `fx68k.txt` | <https://github.com/ijor/fx68k>, commit `0602ee4627b10f301298f2673d826cdd6baa9327` | none; the Quartus build uses these |
| `verilator/fx68k.sv`, `verilator/fx68kAlu.sv`, `verilator/uaddrPla.sv` | Jorge Cwik's later revision (copyright 2018, 2021), byte-identical to MiSTer-devel/Arcade-IGSPGM_MiSTer `rtl/fx68k/hdl/verilator/` at commit `502e61d497aa` | the two `$readmemb` paths in `verilator/fx68k.sv` point at `rtl/cpu/fx68k/`, marked in place, since the benches run from the repository root; only `sim/` benches compile these, since Verilator rejects parts of the older files |

Both revisions read `microrom.mem` and `nanorom.mem` from this directory.

The Arcade-BallySenteSAC1_MiSTer core (misteraddons) uses the same two revisions for its
Shrike Avenger; its `rtl/fx68k/hdl/*.sv` equal upstream apart from whitespace.
