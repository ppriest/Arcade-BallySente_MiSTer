-- Where Night Stocker puts a shot for a given gun position: coin up, start,
-- then for each (X, Y) in CORE_AIMS aim, fire, and snapshot the frames around
-- the shot. Driven by scripts/mame_gunshot.py, which finds the shot.
--
--   CORE_AIMS   "x,y;x,y;..." in the gun's units (hex)
--   CORE_START  first frame to aim at (after the game has started)

local AIMS = {}
for x, y in string.gmatch(os.getenv("CORE_AIMS") or "80,80", "(%x+),(%x+)") do
    AIMS[#AIMS + 1] = { tonumber(x, 16), tonumber(y, 16) }
end
local START = tonumber(os.getenv("CORE_START") or "1500")
local STEP  = 180
local mach  = manager.machine

local function field(port, pat)
    for name, f in pairs(mach.ioport.ports[port].fields) do
        if string.find(name, pat) then return f end
    end
end
local fx, fy = nil, nil
for _, f in pairs(mach.ioport.ports[":FAKEX"].fields) do fx = f end
for _, f in pairs(mach.ioport.ports[":FAKEY"].fields) do fy = f end
local coin  = field(":IN0", "Coin 1")
local start = field(":IN1", "1 Player Start")
local fire  = field(":IN1", "Button 1")

local frame = 0
core_subs = {}
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    coin:set_value((frame >= 300 and frame < 306) and 1 or 0)
    start:set_value((frame >= 390 and frame < 396) and 1 or 0)
    local i = (frame - START) // STEP + 1
    local t = (frame - START) % STEP
    if frame >= START and i <= #AIMS then
        fx:set_value(AIMS[i][1]); fy:set_value(AIMS[i][2])
        fire:set_value((t >= 60 and t < 64) and 1 or 0)
        if t >= 58 and t < 76 then mach.video:snapshot() end
    end
    if frame >= START + #AIMS * STEP then mach:exit() end
end)
