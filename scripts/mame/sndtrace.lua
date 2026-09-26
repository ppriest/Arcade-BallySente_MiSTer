-- Every write the 6VB sound Z80 makes to its CEM3394 control ports, with a
-- timestamp, as the stimulus for scripts/cem3394_replay.py.
--
--   CORE_OUT, CORE_TAG      output directory and filename prefix
--   CORE_SECONDS            emulated seconds to log
--   CORE_COIN               second at which to insert a coin and then press
--                           Start; 0 leaves the machine in attract. Without
--                           this every cartridge sounds the SAME: the 6VB's
--                           boot and self-calibration routine lives in the audio
--                           board's own ROM, so the first seconds of control
--                           writes are byte-identical across games, and MAME's
--                           audio for four different games agreed to -112 dB.
--   CORE_IN_COIN, CORE_IN_START   input field names (regions.json "inputs")
--
-- Ports logged (sente6vb.cpp io_map, global mask 0xff):
--   08-09  counter control; bit 0 is the audio enable
--   0a     DAC data, upper 6 bits      0b  DAC data, lower 6 bits
--   0c-0d  CEM3394 register select     0e-0f  CEM3394 chip enable
--
-- The DAC/register/chip-select ports are all the model needs: chip_select_w()
-- latches the current DAC value into the register named by 0x0c, for every chip
-- whose enable bit goes high. Ports 00-03 (the 8253) are left out; they drive
-- the sound CPU's own timing, which is already reflected in when these writes
-- happen.

local OUT     = os.getenv("CORE_OUT") or "."
local TAG     = os.getenv("CORE_TAG") or "snd"
local SECONDS = tonumber(os.getenv("CORE_SECONDS") or "10")

local mach = manager.machine
local cpu  = mach.devices[":audio6vb:audiocpu"]
if not cpu then
    print("SNDTRACE no :audio6vb:audiocpu -- wrong set?")
    mach:exit()
    return
end
local io_space = cpu.spaces["io"]

local f = assert(io.open(string.format("%s/%s_snd.trace", OUT, TAG), "w"))
f:write("# 6VB sound CPU writes to the CEM3394 control ports\n")
f:write("# time_s\tport\tdata\n")

local n, done, first_err = 0, false, nil

local function stop()
    if done then return end
    done = true
    if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
    f:write(string.format("# %d writes logged\n", n))
    f:close()
    core_fa:close()
    core_fr:close()
    core_fi:close()
    if core_fm then core_fm:close() end
    print(string.format("SNDTRACE %d writes to %s/%s_snd.trace", n, OUT, TAG))
    mach:exit()
end

local function log(offset, data)
    local port = offset & 0xff
    if port < 0x08 or port > 0x0f then return end
    n = n + 1
    f:write(string.format("%.9f\t%02X\t%02X\n", mach.time:as_double(), port, data))
end

-- Global: a subscription that is not kept alive is collected and the callback
-- silently stops firing (WORKFLOW section 9).
core_subs = {}
-- The range must lie inside the space's global address mask, which io_map sets
-- to 0xff here: install_write_tap(0, 0xffff) is rejected outright.
core_subs[#core_subs + 1] = io_space:install_write_tap(0x00, 0xff, "core_snd_w",
    function(offset, data, mask)
        if not done then
            local ok, err = pcall(log, offset, data)
            if not ok and not first_err then first_err = tostring(err) end
        end
        return data
    end)

-- The main CPU's writes to its 6850 (0x9a04 control, 0x9a05 data): the
-- commands the sound board is sent, in <tag>_acia.trace.
core_fa = assert(io.open(string.format("%s/%s_acia.trace", OUT, TAG), "w"))
core_fa:write("# main CPU writes to its 6850\n# time_s\taddr\tdata\n")
core_subs[#core_subs + 1] = mach.devices[":maincpu"].spaces["program"]:install_write_tap(
    0x9a04, 0x9a05, "core_acia_w",
    function(offset, data, mask)
        if not done then
            core_fa:write(string.format("%.9f\t%04X\t%02X\n", mach.time:as_double(), offset, data & 0xff))
        end
        return data
    end)

-- Every I/O access of the sound CPU, reads included, in sim/board_tb's +iolog
-- format with a time column added: <tag>_io.trace.
core_fi = assert(io.open(string.format("%s/%s_io.trace", OUT, TAG), "w"))
local io_n = 0
local function io_log(rw)
    return function(offset, data, mask)
        if not done then
            io_n = io_n + 1
            core_fi:write(string.format("%d\t%s\t%02X\tFF\t%02X\t%.9f\n", io_n, rw,
                                        offset & 0xff, data & 0xff, mach.time:as_double()))
        end
        return data
    end
end
core_subs[#core_subs + 1] = io_space:install_read_tap(0x00, 0xff, "core_io_r", io_log("r"))
core_subs[#core_subs + 1] = io_space:install_write_tap(0x00, 0xff, "core_io_w", io_log("w"))

-- With CORE_RAM_FROM/CORE_RAM_TO (seconds): the sound CPU's RAM writes
-- (0x2000-0x5fff) in that window, in <tag>_ram.trace.
local RAM_FROM = tonumber(os.getenv("CORE_RAM_FROM") or "-1")
local RAM_TO   = tonumber(os.getenv("CORE_RAM_TO") or "-1")
if RAM_TO > RAM_FROM then
    core_fm = assert(io.open(string.format("%s/%s_ram.trace", OUT, TAG), "w"))
    core_fm:write("# sound CPU RAM writes\n# time_s\taddr\tdata\n")
    core_subs[#core_subs + 1] = cpu.spaces["program"]:install_write_tap(
        0x2000, 0x5fff, "core_ram_w",
        function(offset, data, mask)
            local t = mach.time:as_double()
            if not done and t >= RAM_FROM and t <= RAM_TO then
                core_fm:write(string.format("%.9f\t%04X\t%02X\n", t, offset, data & 0xff))
            end
            return data
        end)
end

-- The sound CPU's reads of its 6850 (0xe000 status "S", 0xe001 data "D",
-- mirrored to 0xffff), in <tag>_rx.trace.
core_fr = assert(io.open(string.format("%s/%s_rx.trace", OUT, TAG), "w"))
core_fr:write("# sound CPU reads of its 6850\n# time_s\treg\tdata\n")
core_subs[#core_subs + 1] = cpu.spaces["program"]:install_read_tap(
    0xe000, 0xffff, "core_rx_r",
    function(offset, data, mask)
        if not done then
            core_fr:write(string.format("%.9f\t%s\t%02X\n", mach.time:as_double(),
                                        (offset & 1) == 1 and "D" or "S", data & 0xff))
        end
        return data
    end)

-- Coin and start, driven off the frame counter the way wtiming.lua does it.
local COIN = tonumber(os.getenv("CORE_COIN") or "0")

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end

local f_coin  = COIN > 0 and field(os.getenv("CORE_IN_COIN") or "Coin 1") or nil
local f_start = COIN > 0 and field(os.getenv("CORE_IN_START") or "1 Player Start") or nil
if COIN > 0 and not (f_coin and f_start) then
    f:write("# WARNING: coin or start field not found; running attract only\n")
end

local frame = 0
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    frame = frame + 1
    if f_coin and f_start then
        -- Held for six frames each: one frame is below the game's own debounce.
        local c = math.floor(COIN * 60)
        f_coin:set_value((frame >= c and frame < c + 6) and 1 or 0)
        f_start:set_value((frame >= c + 90 and frame < c + 96) and 1 or 0)
    end
    if mach.time:as_double() >= SECONDS then stop() end
end)
