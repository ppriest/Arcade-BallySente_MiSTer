-- Snake Pit: does the joystick (the whip) move the player, and what does
-- Button 1 do? Coin up, start, then hold only the joystick's Right, then only
-- Button 1, snapshotting before, during and after each. No trackball input.
local mach = manager.machine
local function field(port, pat)
    for name, f in pairs(mach.ioport.ports[port].fields) do
        if string.find(name, pat) then return f end
    end
end
local coin  = field(":IN0", "Coin 1")
local right = field(":IN0", "Right")
local start = field(":IN1", "1 Player Start")
local b1    = field(":IN1", "Button 1")
for _, port in ipairs({ ":IN0", ":IN1" }) do
    for name in pairs(mach.ioport.ports[port].fields) do print("FIELD " .. port .. " " .. name) end
end
local T = tonumber(os.getenv("CORE_T") or "1500")     -- the joystick test starts here
local SNAP = { [T - 1] = 1, [T + 30] = 1, [T + 60] = 1, [T + 119] = 1, [T + 200] = 1,
               [T + 299] = 1, [T + 303] = 1, [T + 310] = 1, [T + 330] = 1 }
local frame = 0
core_subs = {}
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    coin:set_value((frame >= 300 and frame < 306) and 1 or 0)
    start:set_value((frame >= 600 and frame < 630) and 1 or 0)
    right:set_value((frame >= T and frame < T + 120) and 1 or 0)
    b1:set_value((frame >= T + 300 and frame < T + 306) and 1 or 0)
    if SNAP[frame] then mach.video:snapshot() end
    if frame >= T + 340 then mach:exit() end
end)
