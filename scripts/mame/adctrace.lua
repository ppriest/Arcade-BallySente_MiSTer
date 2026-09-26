-- The ADC as the main CPU sees it, for sim/adc_tb. Driven by
-- scripts/mame_adc_trace.py:
--
--   CORE_OUT, CORE_TAG, CORE_FRAMES     output dir, filename prefix, frames to log
--   CORE_HOLD                           frames each set of port values is held
--
-- Every CORE_HOLD frames the analog fields of AN0-AN3 are overridden with new
-- values (field:set_value, which bypasses sensitivity and PORT_REVERSE: those
-- are the MiSTer side's job, rtl/analog_inputs.sv). Logged, with MAME's time
-- in seconds:
--
--   v  <t> <an0> <an1> <an2> <an3>   the port values from now on, signed
--   s  <t> <channel>                 a write to 0x9000-0x9007
--   r  <t> <data>                    a read of 0x9400
--
-- The board latches the ports at vblank, so a read in the frame after a "v"
-- line may still see the previous values; the bench skips those.

local OUT    = os.getenv("CORE_OUT") or "."
local TAG    = os.getenv("CORE_TAG") or "trace"
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "600")
local HOLD   = tonumber(os.getenv("CORE_HOLD") or "4")

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]

local fields, ports = {}, {}
for i = 0, 3 do
    local port = mach.ioport.ports[":AN" .. i]
    ports[i] = port
    local fl = nil
    if port then
        for _, fd in pairs(port.fields) do
            if fd.is_analog then fl = fd end
        end
    end
    fields[i] = fl
end

local f = assert(io.open(string.format("%s/%s_adc.trace", OUT, TAG), "w"))
f:write("# v t an0 an1 an2 an3 | s t channel | r t data\n")
local n, done, first_err = 0, false, nil

local function now() return mach.time:as_double() end

local function stop()
    if done then return end
    done = true
    if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
    f:write(string.format("# %d accesses logged\n", n))
    f:close()
    print(string.format("ADCTRACE %d accesses to %s/%s_adc.trace", n, OUT, TAG))
    mach:exit()
end

local function guard(fn)
    return function(offset, data, mask)
        if not done then
            local ok, err = pcall(fn, offset, data)
            if not ok and not first_err then first_err = tostring(err) end
        end
        return data
    end
end

core_subs = {}
core_subs[#core_subs + 1] = prog:install_write_tap(0x9000, 0x9007, "core_adc_sel", guard(
    function(offset, data)
        n = n + 1
        f:write(string.format("s %.9f %d\n", now(), offset & 7))
    end))
core_subs[#core_subs + 1] = prog:install_read_tap(0x9400, 0x9400, "core_adc_rd", guard(
    function(offset, data)
        n = n + 1
        f:write(string.format("r %.9f %d\n", now(), data & 0xff))
    end))

-- A fixed sequence that visits the dead-zone push, both signs, and the clip at
-- every shift: small values, then a sweep across the whole signed byte.
local SMALL = { 0, 1, -1, 2, -2, 5, -5, 31, -32, 63, -64, 64, -65, 127, -128 }
local function value(k, i)
    if k < #SMALL then return SMALL[(k + i) % #SMALL + 1] end
    return ((k * 37 + i * 71) % 256) - 128
end

local frame, k = 0, 0
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    if frame % HOLD == 0 then
        local v = {}
        for i = 0, 3 do
            -- An 8-bit analog field's override is its port value, 0..255.
            -- It is clamped to PORT_MINMAX, which for a signed range such as
            -- Street Football's 0x80-0x7f pins it to 0x80 or 0x7f, so what is
            -- logged is the port's read, not the value asked for.
            if fields[i] then fields[i]:set_value(value(k, i) & 0xff) end
            v[i] = ports[i] and ports[i]:read() & 0xff or 0
            if v[i] >= 0x80 then v[i] = v[i] - 0x100 end
        end
        f:write(string.format("v %.9f %d %d %d %d\n", now(), v[0], v[1], v[2], v[3]))
        k = k + 1
    end
    frame = frame + 1
    if frame >= FRAMES then stop() end
end)
