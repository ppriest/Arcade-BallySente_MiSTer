-- The main CPU's reads of one input register while the inputs follow a fixed
-- schedule, for sim/board_tb's +insched (the same schedule on the RTL side).
-- Driven by scripts/mame_input_trace.py:
--
--   CORE_OUT, CORE_TAG, CORE_FRAMES     output dir, filename prefix, frames
--   CORE_MODE                           grudge | gun | teamht | stompin
--   CORE_ADDR                           the register, hex (9400, 9902, 9404)
--   CORE_HOLD                           frames each step of the schedule lasts
--
-- Step k of the schedule (k = frame // HOLD):
--   grudge   AN0-AN2 dial positions (k*23 + i*57) & 0xff, i the wheel
--   gun      FAKEX (k*37) & 0xff, FAKEY (k*53 + 17) & 0xff
--   teamht   player p's four directions: bit d of (k*5 + p*3) & 0xf, d in
--            UP, DOWN, RIGHT, LEFT order
--   stompin  pad n (the eight in port order) pressed when n == k % 9
-- Logged: "r <frame> <data>" per read, "k <frame> <step>" per step.

local OUT    = os.getenv("CORE_OUT") or "."
local TAG    = os.getenv("CORE_TAG") or "trace"
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "600")
local MODE   = os.getenv("CORE_MODE") or "grudge"
local ADDR   = tonumber(os.getenv("CORE_ADDR") or "9400", 16)
local HOLD   = tonumber(os.getenv("CORE_HOLD") or "8")

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]

local function field(port, pattern)
    local p = mach.ioport.ports[port]
    if not p then return nil end
    for name, f in pairs(p.fields) do
        if string.find(name, pattern) then return f end
    end
    return nil
end

local fields = {}
if MODE == "grudge" then
    for i = 0, 2 do
        local p = mach.ioport.ports[":AN" .. i]
        for _, f in pairs(p.fields) do if f.is_analog then fields[i] = f end end
    end
elseif MODE == "gun" then
    for _, f in pairs(mach.ioport.ports[":FAKEX"].fields) do fields.x = f end
    for _, f in pairs(mach.ioport.ports[":FAKEY"].fields) do fields.y = f end
elseif MODE == "teamht" then
    local dirs = { "Up", "Down", "Right", "Left" }
    for p = 0, 3 do
        for d = 1, 4 do
            fields[p * 4 + d] = field(":EX" .. p, dirs[d])
        end
    end
elseif MODE == "stompin" then
    local order = { {":AN0", "Top%-Right"}, {":AN0", "^Top$"}, {":AN0", "Top%-Left"},
                    {":AN1", "^Right$"}, {":AN1", "^Left$"},
                    {":AN2", "Bot%-Right"}, {":AN2", "^Bottom$"}, {":AN2", "Bot%-Left"} }
    for n, o in ipairs(order) do fields[n] = field(o[1], o[2]) end
end

local f = assert(io.open(string.format("%s/%s_input.trace", OUT, TAG), "w"))
f:write(string.format("# mode %s, reads of %04X, hold %d\n", MODE, ADDR, HOLD))
local frame, n, done, missing = 0, 0, false, {}

for k, v in pairs(fields) do if v == nil then missing[#missing + 1] = tostring(k) end end

local function apply(k)
    if MODE == "grudge" then
        for i = 0, 2 do fields[i]:set_value((k * 23 + i * 57) & 0xff) end
    elseif MODE == "gun" then
        fields.x:set_value((k * 37) & 0xff)
        fields.y:set_value((k * 53 + 17) & 0xff)
    elseif MODE == "teamht" then
        for p = 0, 3 do
            local bits = (k * 5 + p * 3) & 0xf
            for d = 1, 4 do
                local fd = fields[p * 4 + d]
                if fd then fd:set_value((bits >> (d - 1)) & 1) end
            end
        end
    elseif MODE == "stompin" then
        for m = 1, 8 do
            if fields[m] then fields[m]:set_value(((k % 9) == m) and 1 or 0) end
        end
    end
end

core_subs = {}
core_subs[#core_subs + 1] = prog:install_read_tap(ADDR, ADDR, "core_in_r",
    function(offset, data, mask)
        if not done then
            n = n + 1
            f:write(string.format("r %d %02X\n", frame, data & 0xff))
        end
        return data
    end)

core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    if frame % HOLD == 0 then
        apply(frame // HOLD)
        f:write(string.format("k %d %d\n", frame, frame // HOLD))
    end
    frame = frame + 1
    if frame >= FRAMES then
        done = true
        if #missing > 0 then f:write("# MISSING fields: " .. table.concat(missing, " ") .. "\n") end
        f:write(string.format("# %d reads logged\n", n))
        f:close()
        print(string.format("INPUTTRACE %d reads", n))
        mach:exit()
    end
end)
