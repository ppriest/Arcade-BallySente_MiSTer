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
