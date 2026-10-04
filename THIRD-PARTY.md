# Third-party code

This core is GPL-3.0-or-later (`LICENSE`; each file's SPDX header). What it contains or is derived
from that is not its own:

## Vendored

| Component | Where | Origin | Licence | Changed here |
|---|---|---|---|---|
| MiSTer framework | `sys/` | MiSTer-devel/Template_MiSTer | per file: GPL-2.0/3.0-or-later where stated | no (never touched since the initial commit; the upstream commit it was taken at is not recorded) |
| mc6809i (main CPU) | `rtl/cpu/mc6809/` | Greg Miller's cavnex/mc6809, in jotego's clock-enable fork from jtcores | BSD-3-Clause (upstream's option taken); jotego's changes GPL-3.0 if jtcores' licence is read as covering them | no; `PROVENANCE.md` |
| T80 (6VB sound CPU) | `rtl/cpu/t80/` | MiSTer-devel/T80 `830fd03`, via the Fuuki and Psikyo cores; Daniel Wallner, MikeJ and the MiSTer-devel maintainers | BSD-3-Clause-style, in each file's header | one line of `T80.vhd` (a std_logic width fix for block I/O), marked in place; `T80_upstream_reference.vhd` is the pristine copy; `PROVENANCE.md` |
| FX68K (Shrike Avenger's 68000) | `rtl/cpu/fx68k/` | Jorge Cwik, ijor/fx68k `0602ee4`; the Verilator revision as in MiSTer-devel/Arcade-IGSPGM_MiSTer | GPL-3.0 | the Verilator revision's two `$readmemb` paths, marked in place; `PROVENANCE.md` |
| Shrike Avenger's 68000 board | `rtl/shrike_board.sv` | adapted from `rtl/shrike_68k_board.sv` in misteraddons' Arcade-BallySenteSAC1_MiSTer (commit `3f015f22`), used under GPL-3.0 with its author's permission | GPL-3.0 | clock enables, reset and RAMs rewritten for this core; the header says so |
| screen_rotate_two | `rtl/video/screen_rotate_two.sv` | Sorgelig, via Arcade-Fuuki_MiSTer and Arcade-SKNS_MiSTer | GPL-2.0-or-later | no; `rtl/video/PROVENANCE.md` |

## Derived from MAME

These modules are written here but transcribe MAME's behaviour, and in places its arithmetic, from
the named source files. Those files are BSD-3-Clause; their notices are reproduced below.

| This core | MAME source | Copyright holders |
|---|---|---|
| `rtl/main_bus.sv`, `rtl/game_board.sv`, `rtl/irq_timer.sv`, `rtl/adc.sv`, `rtl/analog_inputs.sv`, `rtl/video/*` (not `screen_rotate_two.sv`), `scripts/build_mra.py` | `src/mame/bally/balsente.cpp`, `balsente_m.cpp`, `balsente_v.cpp` | Aaron Giles |
| `rtl/sound/sente6vb*.sv`, `rtl/sound/sente6vb_c0timer.sv` | `src/mame/bally/sente6vb.cpp` | Aaron Giles |
| `rtl/sound/cem3394_*.sv`, `rtl/sound/sente6vb_params.sv`, `rtl/sound/sente6vb_audio.sv`, `scripts/cem3394_*.py`, `scripts/sente6vb_audio.py` | `src/devices/sound/cem3394.cpp` | Aaron Giles, m1macrophage |
| `rtl/acia6850.sv` | `src/devices/machine/6850acia.cpp` | smf |
| `rtl/sound/pit8253.sv` | `src/devices/machine/pit8253.cpp` | Wilbert Pol, Nathan Woods |
| the noise source in `rtl/sound/sente6vb_audio.sv` | `src/devices/sound/mm5837.cpp` | Dirk Best |

> Redistribution and use in source and binary forms, with or without modification, are permitted
> provided that the following conditions are met:
>
> 1. Redistributions of source code must retain the above copyright notice, this list of
>    conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice, this list of
>    conditions and the following disclaimer in the documentation and/or other materials provided
>    with the distribution.
> 3. Neither the name of the copyright holder nor the names of its contributors may be used to
>    endorse or promote products derived from this software without specific prior written
>    permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
> IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
> FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
> CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
> CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
> SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
> THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
> OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
> POSSIBILITY OF SUCH DAMAGE.

`rtl/pll/` is Quartus-generated Intel PLL IP.

## Not distributed

No ROM is in this repository or in a release. The `.mra` files name MAME's ROM sets; users supply
them.

## Release checklist

Run for every published `.rbf` (`docs/RELEASE_PROCESS.md`, step 4):

- [ ] Every vendored directory has a current `PROVENANCE.md` (`sys/` is covered by this file).
- [ ] Every vendored file changed here carries a change notice: `rtl/cpu/t80/T80.vhd`.
- [ ] `sys/` is unmodified: `git log -- sys` shows only the initial commit.
- [ ] No open licence question. The mc6809i fork's licence is recorded above; either reading is
      GPL-3.0-compatible.
