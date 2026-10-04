-- Capture video/machine state from MAME at a chosen frame. Driven by
-- scripts/mame_capture.py, which passes scripts/mame/regions.json as:
--
--   CORE_OUT     output directory
--   CORE_FRAME   frame to capture at
--   CORE_CPU     device tag, e.g. :maincpu
--   CORE_SPACE   address space, e.g. program
--   CORE_BYTES   bus width in bytes (1, 2, 4, 8)
--   CORE_BIG     1 if the bus is big-endian
--   CORE_READ    "name:hexlo:hexhi,..."  RAM readable through the CPU's view
--   CORE_WTAP    "name:hexlo:hexhi,..."  write-only registers, rebuilt from writes
--
-- Readable RAM is read through the CPU's address space: that is what the CPU
-- would read, handlers and umask included, which is what the RTL must match.
-- Write-only registers cannot be read back; MAME keeps them inside the device.
-- They are rebuilt from a write tap installed before the machine runs: the last
-- byte written to each address is the register state at the captured frame.
--
-- Banked memory (a window whose page is set by a register) needs the bank
-- tracked per write. Add that per core below the generic taps; see the
-- KonamiGX core's scripts/mame/capture.lua for a worked example.

local OUT   = os.getenv("CORE_OUT") or "capture"
local FRAME = tonumber(os.getenv("CORE_FRAME") or "1200")
local BYTES = tonumber(os.getenv("CORE_BYTES") or "2")
local BIG   = os.getenv("CORE_BIG") ~= "0"
local m     = manager.machine

local function mkdir(p) os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') end
mkdir(OUT)

-- An error inside a Lua callback is silent: MAME keeps running and exits 0
-- having produced nothing. Every callback goes through guard(), which writes
-- the failure where the Python side reads it back.
local function guard(what, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            local f = io.open(OUT .. "/ERROR.txt", "a")
            if f then f:write(what, ": ", tostring(err), "\n"); f:close() end
            print("CORE_CAPTURE_ERROR " .. what .. ": " .. tostring(err))
            error(err)
        end
        return ok
    end
end

local function wr(name, bytes)
    local f = assert(io.open(OUT .. "/" .. name, "wb"))
    f:write(bytes)
    f:close()
end

local function ranges(s)
    local out = {}
    for spec in string.gmatch(s or "", "([^,]+)") do
        local name, lo, hi = spec:match("^([^:]+):(%x+):(%x+)$")
        assert(name, "bad range spec: " .. spec)
        out[#out + 1] = { name = name, lo = tonumber(lo, 16), hi = tonumber(hi, 16) }
    end
    return out
end

-- Global on purpose: an autoboot chunk's locals are collected once the chunk
-- returns, and taps and notifiers held only by a local stop firing silently.
core_subs = {}

local sp = m.devices[os.getenv("CORE_CPU") or ":maincpu"].spaces[os.getenv("CORE_SPACE") or "program"]

-- Split a tap's data by the mask actually driven, not by an assumed width.
local function note(tbl, base, addr, data, mask)
    for b = 0, BYTES - 1 do
        local sh = BIG and (BYTES - 1 - b) * 8 or b * 8
        if (mask >> sh) & 0xff ~= 0 then
            tbl[(addr - base) + b] = (data >> sh) & 0xff
        end
    end
end

-- WHEN a register changed, not just what it ended up as. palette_select_w calls
-- update_partial(), so the bank applies from part way down the screen and a
-- frame can be drawn with more than one of them. The wtap below keeps only the
-- last value written, which is the wrong thing for any frame that switches.
--
-- The Lua binding has no screen:vpos() -- luaengine.cpp's screen_dev_type binds
-- width, height, the periods and time_until_vblank_start, and nothing that
-- gives a raster position directly. So this logs LINES UNTIL VBLANK STARTS,
-- which is exact, and leaves turning that into a scanline to the caller, which
-- knows the board's VBSTART and VTOTAL:
--
--   vpos = (VBSTART + VTOTAL - lines_to_vblank) mod VTOTAL
--
-- CORE_SCANREG   "name:hexlo:hexhi,..."  registers to log with their position
local scanlog = {}
local SCANREG = ranges(os.getenv("CORE_SCANREG"))

local regs = {}
local WTAP = ranges(os.getenv("CORE_WTAP"))
for _, r in ipairs(WTAP) do
    regs[r.name] = {}
    core_subs[#core_subs + 1] = sp:install_write_tap(r.lo, r.hi, "core_" .. r.name,
        guard("tap_" .. r.name, function(offset, data, mask)
            note(regs[r.name], r.lo, offset, data, mask)
        end))
end

for _, r in ipairs(SCANREG) do
    scanlog[r.name] = {}
    core_subs[#core_subs + 1] = sp:install_write_tap(r.lo, r.hi, "scan_" .. r.name,
        guard("scan_" .. r.name, function(offset, data, mask)
            local scr = m.screens[":screen"]
            local t = scanlog[r.name]
            t[#t + 1] = string.format("%d\t%.6f\t%d",
                                      scr:frame_number(),
                                      scr:time_until_vblank_start():as_double()
                                          / scr.scan_period,
                                      data & 0xff)
        end))
end

-- BEAM CAPTURE. The board races the beam: every set writes sprite RAM and video
-- RAM during active display (docs/HARDWARE_NOTES.md, "Raster timing"), so a
-- single RAM snapshot cannot describe what the screen showed. This records the
-- RAM as it stood at the START of the captured frame, plus every write during
-- that frame with the raster line it landed on, which together say what each
-- scanline saw.
--
--   CORE_BEAM   "name:hexlo:hexhi,..."  regions to log for one frame
--
-- Only the captured frame is logged. Logging from boot would accumulate
-- millions of entries; hattrick alone writes its sprite list 1,698 times a
-- frame. The RAM dumped at the end is the existing one, so replaying the log
-- onto the start RAM must reproduce it exactly -- which is the check that says
-- the log is complete, and render_model.py makes it.
local BEAM = ranges(os.getenv("CORE_BEAM"))
local beamlog = {}
local beam_on = false

for _, r in ipairs(BEAM) do
    beamlog[r.name] = {}
    core_subs[#core_subs + 1] = sp:install_write_tap(r.lo, r.hi, "beam_" .. r.name,
        guard("beam_" .. r.name, function(offset, data, mask)
            if beam_on then
                local scr = m.screens[":screen"]
                local t = beamlog[r.name]
                t[#t + 1] = string.format("%.6f\t%X\t%02X",
                                          scr:time_until_vblank_start():as_double()
                                              / scr.scan_period,
                                          offset, data & 0xff)
            end
        end))
end

local function read_block(lo, hi)
    local t = {}
    for a = lo, hi do t[#t + 1] = string.char(sp:read_u8(a)) end
    return table.concat(t)
end

local function dump_sparse(name, tbl, size)
    local t = {}
    for i = 0, size - 1 do t[i + 1] = string.char(tbl[i] or 0) end
    wr(name, table.concat(t))
end

-- Coin and start, so a capture can be of the GAME rather than of attract mode.
-- CORE_COIN is the frame at which to insert a coin; Start follows 90 frames
-- later. Each is held six frames, because one is below a game's own debounce.
-- CORE_COINS coins go in, 30 frames apart; CORE_IN_START2, if set, is pressed
-- with Start (Shrike Avenger's second seat button).
local COIN = tonumber(os.getenv("CORE_COIN") or "0")
local COINS = tonumber(os.getenv("CORE_COINS") or "1")

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end

local f_coin  = COIN > 0 and field(os.getenv("CORE_IN_COIN") or "Coin 1") or nil
local f_start = COIN > 0 and field(os.getenv("CORE_IN_START") or "1 Player Start") or nil
local s2 = os.getenv("CORE_IN_START2")
local f_start2 = (COIN > 0 and s2 and s2 ~= "") and field(s2) or nil
if COIN > 0 and not (f_coin and f_start) then
    local f = io.open(OUT .. "/ERROR.txt", "a")
    if f then f:write("coin or start field not found\n"); f:close() end
end

local done = false
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(guard("frame", function()
    if done then return end
    local scr = m.screens[":screen"]
    if f_coin and f_start then
        local n = scr:frame_number()
        local c = 0
        for k = 0, COINS - 1 do
            if n >= COIN + 30 * k and n < COIN + 30 * k + 6 then c = 1 end
        end
        f_coin:set_value(c)
        local s = (n >= COIN + 90 and n < COIN + 96) and 1 or 0
        f_start:set_value(s)
        if f_start2 then f_start2:set_value(s) end
    end
    -- One frame early: dump the RAM the captured frame starts from, and open
    -- the write log. The notifier fires once per frame, so everything logged
    -- between here and the next one belongs to the captured frame.
    if #BEAM > 0 and not beam_on and scr:frame_number() >= FRAME - 1 then
        for _, r in ipairs(BEAM) do
            wr("start_" .. r.name .. ".bin", read_block(r.lo, r.hi))
        end
        beam_on = true
    end
    if scr:frame_number() < FRAME then return end
    done = true
    beam_on = false

    for _, r in ipairs(ranges(os.getenv("CORE_READ"))) do
        wr(r.name .. ".bin", read_block(r.lo, r.hi))
    end
    for _, r in ipairs(WTAP) do
        dump_sparse("reg_" .. r.name .. ".bin", regs[r.name], r.hi - r.lo + 1)
    end

    for _, r in ipairs(BEAM) do
        local bf = assert(io.open(OUT .. "/beam_" .. r.name .. ".txt", "w"))
        bf:write("# lines_to_vblank\taddr\tdata\n")
        for _, line in ipairs(beamlog[r.name]) do bf:write(line, "\n") end
        bf:close()
    end

    for _, r in ipairs(SCANREG) do
        local f = assert(io.open(OUT .. "/scan_" .. r.name .. ".txt", "w"))
        f:write("# frame\tlines_to_vblank\tdata\n")
        for _, line in ipairs(scanlog[r.name]) do f:write(line, "\n") end
        f:close()
    end

    -- Two references, deliberately.
    --
    -- reference.bin is scr:pixels(): the SCREEN's own bitmap, one 32-bit RGB
    -- value per pixel, and the thing the RTL has to reproduce. reference.png is
    -- MAME's composited snapshot, which is the screen PLUS anything the render
    -- pipeline draws over it. Those are not the same picture: stocker has an
    -- analog wheel, so MAME blends a crosshair into the bottom right corner and
    -- a pixel comparison against the .png failed on 416 pixels that the
    -- hardware never draws. The .png is kept because it is what a human should
    -- look at; the .bin is what a diff should use.
    local px, pw, ph = scr:pixels()
    local pf = assert(io.open(OUT .. "/reference.bin", "wb"))
    pf:write(px)
    pf:close()

    scr:snapshot(OUT .. "/reference.png")

    local f = assert(io.open(OUT .. "/manifest.txt", "w"))
    f:write("set ", m.system.name, "\n")
    f:write("mame ", emu.app_version(), "\n")
    f:write("frame ", tostring(scr:frame_number()), "\n")
    f:write("screen ", tostring(scr.width), "x", tostring(scr.height), "\n")
    f:write("pixels ", tostring(pw), "x", tostring(ph), "\n")
    f:close()

    print("CORE_CAPTURE_OK " .. OUT)
    m:exit()
end))
