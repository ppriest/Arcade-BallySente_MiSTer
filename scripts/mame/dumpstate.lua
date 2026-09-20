-- A state image: one CPU's registers, its RAM, and every I/O write that
-- preceded the image, so a testbench can start where MAME was instead of
-- booting to get there.
--
--   CORE_OUT, CORE_TAG   output directory and filename prefix
--   CORE_CPU             device tag, e.g. :audio6vb:audiocpu
--   CORE_SPACE           address space to read RAM from (default "program")
--   CORE_RAM             RAM ranges, "lo:hi" hex, comma separated
--   CORE_IOSPACE         space whose accesses are counted and logged ("io", or
--                        empty to skip the I/O log entirely)
--   CORE_IOMASK          the I/O space's global_mask, hex (default ff)
--   CORE_TRIG            when to take the image:
--                          time:<seconds>        emulated seconds
--                          ioany:<n>             the nth I/O access, read or
--                                                write, numbered as the traces
--                                                from scripts/mame_boot_trace.py
--                          iow:<port>:<n>        the nth write to that port
--
-- WHEN THE IMAGE IS TAKEN, and why it is not exactly at the trigger. The
-- trigger only ARMS the dump; the image itself is written from the next machine
-- frame notifier. A tap fires in the middle of a bus cycle, where the CPU's
-- architectural state does not exist -- PC has been incremented past an opcode
-- that has not finished, and MAME's own device state is mid-update. A frame
-- notifier runs from the scheduler between timeslices, where every CPU has
-- completed whole instructions. So the image is up to one frame LATER than the
-- trigger, and `io_seq` in the manifest is the count at the image, not at the
-- trigger. Pick a trigger comfortably before what you want to reproduce.
--
-- WHAT IS NOT IN THE IMAGE: peripheral state. The 8253's counters, the CEM3394
-- control voltages and the 6VB's own registers are private to their devices and
-- Lua cannot read them. The I/O write log is the substitute: a bench replays
-- those writes into its board model before releasing the CPU, which rebuilds
-- every register the program set but NOT anything that depends on the time
-- between the writes -- a counter part way through a count comes back as
-- whatever a fresh write leaves it at. Take the image at a point where the
-- program reprograms what it is about to use, and that loss costs nothing.

local OUT      = os.getenv("CORE_OUT") or "."
local TAG      = os.getenv("CORE_TAG") or "state"
local CPUTAG   = os.getenv("CORE_CPU") or ":maincpu"
local SPACE    = os.getenv("CORE_SPACE") or "program"
local IOSPACE  = os.getenv("CORE_IOSPACE") or ""
local IOMASK   = tonumber(os.getenv("CORE_IOMASK") or "ff", 16)
local RAMSPEC  = os.getenv("CORE_RAM") or ""
local TRIG     = os.getenv("CORE_TRIG") or "time:1"

local mach = manager.machine
local cpu  = mach.devices[CPUTAG]
if not cpu then
    print("DUMPSTATE no " .. CPUTAG .. " -- wrong set?")
    mach:exit()
    return
end

-- ------------------------------------------------------------------ trigger
local trig_kind, trig_a, trig_b
do
    local parts = {}
    for p in TRIG:gmatch("[^:]+") do parts[#parts + 1] = p end
    trig_kind = parts[1]
    if trig_kind == "time" then
        trig_a = tonumber(parts[2])
    elseif trig_kind == "ioany" then
        trig_a = tonumber(parts[2])
    elseif trig_kind == "iow" then
        trig_a = tonumber(parts[2], 16)
        trig_b = tonumber(parts[3] or "1")
    else
        print("DUMPSTATE unknown CORE_TRIG: " .. TRIG)
        mach:exit()
        return
    end
end

-- --------------------------------------------------------- the I/O write log
local iow_path = string.format("%s/%s_iow.txt", OUT, TAG)
local iow_f    = nil
local io_seq   = 0        -- every I/O access, matching the trace numbering
local iow_n    = 0        -- writes only, which is what the log holds
local port_w   = {}       -- per-port write counts, for the iow: trigger
local armed    = false
local done     = false

if IOSPACE ~= "" then
    iow_f = assert(io.open(iow_path, "w"))
    iow_f:write("# I/O writes before the state image, in order.\n")
    iow_f:write("# port\tdata\n")
end

local function note_write(port, data)
    iow_n = iow_n + 1
    iow_f:write(string.format("%02X\t%02X\n", port, data))
    port_w[port] = (port_w[port] or 0) + 1
    if trig_kind == "iow" and port == trig_a and port_w[port] >= trig_b then armed = true end
end

if IOSPACE ~= "" then
    local ios = cpu.spaces[IOSPACE]
    if not ios then
        print("DUMPSTATE no " .. IOSPACE .. " space on " .. CPUTAG)
        mach:exit()
        return
    end
    -- Global: a subscription that is not kept alive is collected and the
    -- callback silently stops firing (WORKFLOW section 9). The tap range must
    -- lie inside the space's global mask.
    core_subs = {}
    core_subs[#core_subs + 1] = ios:install_write_tap(0, IOMASK, "core_dump_w",
        function(offset, data, mask)
            if not done then
                io_seq = io_seq + 1
                pcall(note_write, offset & IOMASK, data & 0xff)
                if trig_kind == "ioany" and io_seq >= trig_a then armed = true end
            end
            return data
        end)
    core_subs[#core_subs + 1] = ios:install_read_tap(0, IOMASK, "core_dump_r",
        function(offset, data, mask)
            if not done then
                io_seq = io_seq + 1
                if trig_kind == "ioany" and io_seq >= trig_a then armed = true end
            end
            return data
        end)
else
    core_subs = {}
end

-- ----------------------------------------------------------------- the image
local function dump()
    local space = cpu.spaces[SPACE]
    local man = assert(io.open(string.format("%s/%s_state.txt", OUT, TAG), "w"))
    man:write("# MAME state image. One `key<TAB>value...` per line.\n")
    man:write(string.format("set\t%s\n", emu.romname()))
    man:write(string.format("cpu\t%s\n", CPUTAG))
    man:write(string.format("time_s\t%.9f\n", mach.time:as_double()))
    man:write(string.format("io_seq\t%d\n", io_seq))
    man:write(string.format("trigger\t%s\n", TRIG))

    -- Every state entry the CPU publishes, so this works for the 6809 too
    -- without a second table to keep in step. The key is the entry's SYMBOL;
    -- device_state_entry has no `name` in the Lua binding, and reading one
    -- returns nil rather than raising, so an image would come out with no
    -- registers at all and look merely empty. Hence the count check below.
    local nreg = 0
    for sym, e in pairs(cpu.state) do
        if sym and sym ~= "" and sym ~= "GENFLAGS" and not e.is_float then
            man:write(string.format("reg\t%s\t%X\n", sym, e.value & 0xffffffff))
            nreg = nreg + 1
        end
    end
    if nreg == 0 then error("no register entries read from " .. CPUTAG .. ".state") end

    for r in RAMSPEC:gmatch("[^,]+") do
        local lo, hi = r:match("([^:]+):([^:]+)")
        lo, hi = tonumber(lo, 16), tonumber(hi, 16)
        local name = string.format("%s_ram_%04x.hex", TAG, lo)
        local rf = assert(io.open(OUT .. "/" .. name, "w"))
        local line = {}
        for a = lo, hi do
            line[#line + 1] = string.format("%02x", space:read_u8(a))
            if #line == 16 then
                rf:write(table.concat(line, " "), "\n")
                line = {}
            end
        end
        if #line > 0 then rf:write(table.concat(line, " "), "\n") end
        rf:close()
        man:write(string.format("ram\t%04X\t%04X\t%s\n", lo, hi, name))
    end

    if iow_f then
        iow_f:write(string.format("# %d writes logged\n", iow_n))
        iow_f:close()
        iow_f = nil
        man:write(string.format("iow\t%s_iow.txt\t%d\n", TAG, iow_n))
    end

    man:close()
    print(string.format("DUMPSTATE %s at t=%.6f io_seq=%d, %d I/O writes",
                        TAG, mach.time:as_double(), io_seq, iow_n))
end

core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    if trig_kind == "time" and mach.time:as_double() >= trig_a then armed = true end
    if not armed then return end
    done = true
    local ok, err = pcall(dump)
    if not ok then
        local f = io.open(OUT .. "/lua_error.txt", "w")
        if f then f:write("runtime: " .. tostring(err) .. "\n"); f:close() end
        print("LUAFAIL runtime: " .. tostring(err))
    end
    mach:exit()
end)
