-- Every write the 6VB sound Z80 makes to its CEM3394 control ports, with a
-- timestamp, as the stimulus for scripts/cem3394_replay.py.
--
--   CORE_OUT, CORE_TAG      output directory and filename prefix
--   CORE_SECONDS            emulated seconds to log
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

core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    if mach.time:as_double() >= SECONDS then stop() end
end)
