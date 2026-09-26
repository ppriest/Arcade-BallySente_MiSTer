#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# VHDL the Verilator benches need, converted to Verilog with GHDL's synthesis.
# Called by scripts/run_verilator.sh with the bench name; RUN FROM THE
# REPOSITORY ROOT. Does nothing unless the bench lists a converted file, and
# nothing if that file is newer than its VHDL.
#
#   obj_verilator/t80_ghdl/T80se.v    rtl/cpu/t80, the 6VB sound CPU
#
# The generics are fixed at conversion to the values rtl/sound/sente6vb.sv
# uses (Mode 0, T2Write 0, IOWait 1). The output declares them as parameters
# again only so the instance compiles unchanged, and stops the simulation if
# an instance asks for other values. Method from the KonamiGX core's
# tg68k_verilog.sh.
#
# TOOLS: GHDL (MSYS2 MinGW64, mingw-w64-x86_64-ghdl-mcode).
set -euo pipefail

TB="${1:?usage: scripts/verilator_prep.sh <bench>}"
T80V=obj_verilator/t80_ghdl/T80se.v
SRC=rtl/cpu/t80

grep -q "$T80V" "sim/$TB/verilator.files" 2>/dev/null || exit 0
[ -f "$T80V" ] && [ -z "$(find $SRC scripts/verilator_prep.sh -newer "$T80V")" ] && exit 0

if ! command -v ghdl >/dev/null 2>&1; then
	MSYS="${MSYS2_ROOT:-/e/msys64}"
	[ -x "$MSYS/usr/bin/bash.exe" ] || { echo "MSYS2 not found. Set MSYS2_ROOT."; exit 1; }
	exec env MSYSTEM=MINGW64 CHERE_INVOKING=1 "$MSYS/usr/bin/bash.exe" -lc \
		'cd "$1" && shift && exec scripts/verilator_prep.sh "$@"' _ "$(pwd -W 2>/dev/null || pwd)" "$TB"
fi

GEN="Mode=0 T2Write=0 IOWait=1"
OUT=obj_verilator/t80_ghdl
mkdir -p "$OUT"
( cd "$OUT"
  rm -f work-obj08.cf
  ghdl -a --std=08 -fsynopsys ../../$SRC/T80_Pack.vhd ../../$SRC/T80_ALU.vhd \
	../../$SRC/T80_Reg.vhd ../../$SRC/T80_MCode.vhd ../../$SRC/T80.vhd ../../$SRC/T80se.vhd
  ghdl --synth --std=08 -fsynopsys --latches --out=verilog \
	$(for g in $GEN; do printf -- '-g%s ' "$g"; done) T80se \
	> T80se.raw.v 2> synth.log || { cat synth.log; exit 1; } )

PARAMS=$(for g in $GEN; do printf 'parameter integer %s, ' "${g/=/ = }"; done)
CHECK=$(for g in $GEN; do printf '(%s != %s) || ' "${g%=*}" "${g#*=}"; done)
awk -v p="${PARAMS%, }" -v c="${CHECK% || }" '
	/^module t80se$/ || /^module T80se$/ { print "module T80se #(" p ")"; hold = 1; next }
	hold && /\);$/ { print; print "  initial if (" c ") $fatal(1, \"T80se: converted with other generics (scripts/verilator_prep.sh)\");"; hold = 0; next }
	{ print }' "$OUT/T80se.raw.v" > "$T80V"
rm "$OUT/T80se.raw.v"
echo "$T80V: $(wc -l < "$T80V") lines"
