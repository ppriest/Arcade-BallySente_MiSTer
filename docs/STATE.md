# BallySente state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame.

Most of this core is not written yet. Rows appear as the RTL does; an empty section means that
subsystem does not exist, not that it has no state.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| Sprite RAM 0x0000-0x07ff | `rtl/game_board.sv` | 8 x 2048 | 2,048 | yes — only the low 256 bytes are scanned, but the CPU uses the rest as RAM |
| Video RAM 0x0800-0x7fff | `rtl/game_board.sv` | 8 x 30720 | 30,720 | yes — the visible bitmap, and the board races the beam over it |
| Palette RAM 0x8000-0x8fff | `rtl/game_board.sv`, four byte planes | 8 x 4096 | 4,096 | yes |
| 6VB sound RAM 0x2000-0x5fff | `rtl/sound/sente6vb.sv` | 8 x 16384 | 16,384 | yes |
| NOVRAM `nv` (both X2212s) | `rtl/game_board.sv` | 4 x 512 | 256 | **no** — it is the battery-backed save, written to the SD card through its own path, not through a savestate |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| Palette bank | `rtl/main_bus.sv` | 2 | yes | `m_palettebank_vis` |
| ROM bank (`0x98a0`), second bank (`0x9f00`) | `rtl/main_bus.sv` | 8 + 8 | yes | bank registers |
| Output latch U9H (`0x9800`) | `rtl/main_bus.sv` | 8 | yes | `m_outlatch` |
| 8253 counters 0-2 | `rtl/sound/pit8253.sv` | 3 x (16 count + 16 value + 2 phase + mode/rw/gate flags) | yes | `pit8253_device` |
| 6VB counter-0 flip-flop, counter control, chip select, DAC, register select | `rtl/sound/sente6vb_io.sv` | 1 + 6 + 6 + 12 + 3 | yes | `m_counter_0_ff`, `m_counter_control`, `m_chip_select`, `m_dac_value`, `m_dac_register` |
| Hardware random source | `rtl/main_bus.sv` | 17 + 4 + 1 | yes — it is a free-running sequence, and restoring mid-sequence is the only way a savestate reproduces the same numbers | `m_rand17` is a table; the state is the index |
| 6VB 6850 ACIA | `rtl/sound/sente6vb.sv` (`u_acia`) | as the main board's | yes | the 6VB's `acia6850_device` |
| 6VB NMI latch, clock dividers | `rtl/sound/sente6vb.sv` | 1 + 4 + 3 + 1 | yes -- the dividers set where the 500 kHz edges fall | `m_uint`, the `uartclock` device |
| Counter-0 timer: control voltages | `rtl/sound/sente6vb_c0timer.sv` | 6 voices x 4 x 12 | yes -- an addressable array by voice, as the CEM3394 row requires | the CEM3394s' CVs |
| Counter-0 timer: NCO | `rtl/sound/sente6vb_c0timer.sv` | 44 acc + 44 step + armed, running, scan | yes | `m_counter_0_timer`, `m_counter_0_timer_active` |
| Voice parameters, staging and active | `rtl/sound/sente6vb_params.sv` | 6 x ~330 bits, twice | yes -- the active copy is what the voices read; the staging copy is re-derivable only from the DAC writes, which are gone | the CEM3394s' CVs |
| Oscillator per-voice state | `rtl/sound/cem3394_vco.sv` (`phase_m`, `*_corr_m`) | 6 x 122 | yes | `va_vco` phase and corrections |
| Filter per-voice state | `rtl/sound/cem3394_lpf4.sv` (`st*_m`) | 6 x 120 | yes | `va_lpf4` state |
| AC high-pass per voice, noise register and its high-pass | `rtl/sound/sente6vb_audio.sv` (`hp`, `lfsr`, `nacc`, `nhp`) | 6 x 64 + 18 + 32 + 64 | yes | `flt_rc`, `mm5837` |
| Main-board 6850 ACIA | `rtl/acia6850.sv` | control, status, TX/RX shift registers and counters, ~70 | yes -- a byte in flight to the 6VB is game state | `acia6850_device` |
| IRQ timer | `rtl/irq_timer.sv` | 9 + 1 | yes — which of the four lines is next, and whether one is live | `m_scanline_timer` |
| Sprite line buffer | `rtl/video/sprite_engine.sv` | 512 x 4, one M10K | **no** — rebuilt every line, and which half is which is the line's parity rather than a saved flip-flop | n/a |
| Video raster counters | `rtl/video/video_timing.sv` | 3 + 9 + 9 | **no** — re-derived from `frame_start` | n/a |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| MC6809E | `rtl/cpu/mc6809/mc6809i.v` | not checked | — | no state port found yet; a wrapper stub is the fallback (`savestates.md`) |
| Z80 (6VB) | `rtl/cpu/t80/` | **yes** | 1 | `T80.vhd` has `REG` out and `DIR`/`DIRSet` in, 212 bits, the whole architectural state. See below |
| CEM3394 voice | `cem3394_vco.sv`, `cem3394_lpf4.sv` | yes today, **must stay so** | 2 | phase accumulator and the four filter states are plain registers. When the six voices are time-shared across two pipelines the per-voice state must become an addressable array indexed by voice, NOT a circulating shift register — the one decision `savestates.md` says cannot be undone cheaply |

### T80 exposes its whole state, but `T80se` does not pass it through

`T80.vhd:124-127` has `REG : out std_logic_vector(211 downto 0)` and `DIR`/`DIRSet` in — IFF2,
IFF1, IM, IY, HL', DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A. Of the wrappers vendored
here only `T80pa` forwards them; `T80se`, which this core instantiates, does not.

That is a wrapper to add, not a fork: a thin local top level can instantiate `T80` directly with
the ports exposed, leaving every vendored file untouched.

It also supersedes how `sim/common/state_image.sv` restores the sound CPU today. That bench builds
a short instruction stub — `LD SP`, `EXX`, `PUSH`/`POP AF`, `JP` — because the state port was
believed not to exist, and pays for it: R lands about twenty counts high, IFF1 and IFF2 cannot be
set apart, and two bytes below SP are clobbered. `DIRSet` has none of those costs.

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| Sprite ROM, program ROM | loaded from the `.mra`, never written |
| The tanh table (`tanh_lut.sv`) | a constant ROM generated by `cem3394_model.py` |
| The sprite line buffer | rebuilt from sprite RAM every line |
| Video timing counters | re-derived from `frame_start` |

## Frame alignment

Restore point is `frame_start`. Nothing in the video path is double-buffered — the board races the
beam and so does the core (`HARDWARE_NOTES.md`, "Raster timing") — so there is no buffer phase to
save with it. If a later scheme adds one, it belongs here before it is written.
