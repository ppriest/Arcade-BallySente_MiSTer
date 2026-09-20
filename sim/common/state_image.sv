// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading a MAME state image (scripts/mame_dump_state.py) into a testbench.
//
// A bench that starts from an image skips the boot it does not care about:
// sim/calib_tb spends about 9 of its 10 million cycles on the 6VB's RAM test
// and ROM checksum before reaching the self-calibration it exists to test.
//
// The image holds RAM, the CPU's registers, and every I/O write that preceded
// it. There is no way to write a vendored CPU core's registers from outside --
// T80 has no state port and rtl/cpu/t80/PROVENANCE.md says to keep it pristine
// -- so the registers go in the only way the CPU itself provides: si_z80_stub()
// returns a short straight-line program that loads them and jumps to PC, which
// the bench serves in place of ROM for its first few dozen fetches.
//
// WHAT THE STUB COSTS, all of it unavoidable and none of it load-bearing here:
//
//   R      every instruction the stub executes after `LD R,A` increments the
//          refresh register, so R lands about twenty counts high. Nothing on
//          this board reads R, and refresh cycles are not in the traces.
//   IFF2   the Z80 can only set IFF1 and IFF2 together, with EI or DI, so an
//          image where they differ (inside an NMI handler) cannot be restored.
//          si_z80_stub() checks and refuses rather than restoring it wrongly.
//   stack  PUSH/POP is how AF is loaded, so the two bytes below SP are
//          overwritten. They are below the stack pointer, which is free space.
//
// The image is taken at an instruction boundary, so nothing mid-instruction --
// an interrupt being taken, a bus cycle in flight -- can be carried. A trace
// comparison therefore starts at the image, not at reset: the manifest's
// io_seq says how many of MAME's accesses came before it.

package state_image_pkg;

    typedef struct {
        logic [15:0] af, bc, de, hl, af2, bc2, de2, hl2, ix, iy, sp, pc;
        logic [7:0]  i, r;
        logic [1:0]  im;
        logic        iff1, iff2, halt;
        int          io_seq;
        string       dir;      // the manifest's directory, for the sibling files
        string       ram_file; // first `ram` line's filename
        int          ram_lo;
        string       iow_file;
        int          iow_n;
    } z80_state_t;

    function automatic string si_dirname(input string path);
        int i;
        for (i = path.len() - 1; i >= 0; i--)
            if (path[i] == "/" || path[i] == "\\")
                return path.substr(0, i);
        return "";
    endfunction

    function automatic z80_state_t si_read_z80(input string path);
        int          fd, nreg;
        string       line, name, fname;
        logic [31:0] val, lo, hi;
        z80_state_t  s;

        s = '{default: '0, dir: si_dirname(path), ram_file: "", iow_file: ""};
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "state image not found: %s", path);

        nreg = 0;
        while (!$feof(fd)) begin
            line = "";
            void'($fgets(line, fd));
            if (line.len() == 0) continue;
            if (line.getc(0) == "#") continue;
            if ($sscanf(line, "reg %s %h", name, val) == 2) begin
                nreg++;
                case (name)
                    "AF":   s.af   = val[15:0];
                    "BC":   s.bc   = val[15:0];
                    "DE":   s.de   = val[15:0];
                    "HL":   s.hl   = val[15:0];
                    "AF2":  s.af2  = val[15:0];
                    "BC2":  s.bc2  = val[15:0];
                    "DE2":  s.de2  = val[15:0];
                    "HL2":  s.hl2  = val[15:0];
                    "IX":   s.ix   = val[15:0];
                    "IY":   s.iy   = val[15:0];
                    "SP":   s.sp   = val[15:0];
                    "PC":   s.pc   = val[15:0];
                    "I":    s.i    = val[7:0];
                    "R":    s.r    = val[7:0];
                    "IM":   s.im   = val[1:0];
                    "IFF1": s.iff1 = val[0];
                    "IFF2": s.iff2 = val[0];
                    "HALT": s.halt = val[0];
                    default: ;
                endcase
            end else if ($sscanf(line, "io_seq %d", val) == 1) begin
                s.io_seq = val;
            end else if ($sscanf(line, "ram %h %h %s", lo, hi, fname) == 3) begin
                if (s.ram_file == "") begin
                    s.ram_lo   = lo;
                    s.ram_file = fname;
                end
            end else if ($sscanf(line, "iow %s %d", fname, val) == 2) begin
                s.iow_file = fname;
                s.iow_n    = val;
            end
        end
        $fclose(fd);
        if (nreg == 0) $fatal(1, "%s has no `reg` lines", path);
        return s;
    endfunction

    // A straight-line program that leaves the Z80 in state `s` and jumps to its
    // PC. Shadow registers are loaded first and swapped in, so the main set is
    // written last and nothing clobbers it; AF goes through the stack because
    // that is the only way to write F.
    function automatic void si_z80_stub(input z80_state_t s, output logic [7:0] q[$]);
        if (s.iff1 !== s.iff2)
            $fatal(1, "state image has IFF1=%0b IFF2=%0b; EI/DI cannot set them apart",
                   s.iff1, s.iff2);
        if (s.halt)
            $fatal(1, "state image was taken with the CPU halted; the stub cannot resume it");
        q = {};
        q = {q, 8'h31, s.sp[7:0], s.sp[15:8]};                    // LD SP,nn
        q = {q, 8'h3E, s.i, 8'hED, 8'h47};                        // LD A,n / LD I,A
        q = {q, 8'h3E, s.r, 8'hED, 8'h4F};                        // LD A,n / LD R,A
        q = {q, 8'h01, s.bc2[7:0], s.bc2[15:8]};                  // LD BC,nn
        q = {q, 8'h11, s.de2[7:0], s.de2[15:8]};                  // LD DE,nn
        q = {q, 8'h21, s.hl2[7:0], s.hl2[15:8]};                  // LD HL,nn
        q = {q, 8'hD9};                                           // EXX
        q = {q, 8'h21, s.af2[7:0], s.af2[15:8], 8'hE5, 8'hF1};    // LD HL,nn/PUSH/POP AF
        q = {q, 8'h08};                                           // EX AF,AF'
        q = {q, 8'h21, s.af[7:0], s.af[15:8], 8'hE5, 8'hF1};
        q = {q, 8'h01, s.bc[7:0], s.bc[15:8]};
        q = {q, 8'h11, s.de[7:0], s.de[15:8]};
        q = {q, 8'h21, s.hl[7:0], s.hl[15:8]};
        q = {q, 8'hDD, 8'h21, s.ix[7:0], s.ix[15:8]};             // LD IX,nn
        q = {q, 8'hFD, 8'h21, s.iy[7:0], s.iy[15:8]};             // LD IY,nn
        q = {q, 8'hED, (s.im == 2'd0) ? 8'h46 : (s.im == 2'd1) ? 8'h56 : 8'h5E};
        q = {q, s.iff1 ? 8'hFB : 8'hF3};                          // EI / DI
        q = {q, 8'hC3, s.pc[7:0], s.pc[15:8]};                    // JP nn
    endfunction

endpackage
