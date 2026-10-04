-- Every main-CPU write to one address, with the frame it happened in; two coins
-- from CORE_COIN (frame; 0 for none), 30 frames apart, and Start 90 frames later.
--   CORE_OUT, CORE_TAG, CORE_FRAMES, CORE_ADDR (hex), CORE_COIN
local OUT    = os.getenv("CORE_OUT") or "."
local TAG    = os.getenv("CORE_TAG") or "tap"
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "1500")
local ADDR   = tonumber(os.getenv("CORE_ADDR") or "9e01", 16)
local COIN   = tonumber(os.getenv("CORE_COIN") or "0")
local mach   = manager.machine
local function field(port, pat)
    for name, f in pairs(mach.ioport.ports[port].fields) do
        if string.find(name, pat) then return f end
    end
end
local coin  = COIN > 0 and field(":IN0", "Coin 1") or nil
local start = COIN > 0 and field(":IN1", "1 Player Start") or nil
local start2 = COIN > 0 and field(":IN1", "2 Players Start") or nil
local f = assert(io.open(string.format("%s/%s_writes.txt", OUT, TAG), "w"))
local frame, done = 0, false
core_subs = {}
core_subs[#core_subs + 1] = mach.devices[":maincpu"].spaces["program"]:install_write_tap(
    ADDR, ADDR, "core_wtap", function(offset, data, mask)
        if not done then f:write(string.format("%d %02X\n", frame, data & 0xff)) end
        return data
    end)
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    frame = frame + 1
    if coin then
        coin:set_value(((frame >= COIN and frame < COIN + 6) or (frame >= COIN + 30 and frame < COIN + 36)) and 1 or 0)
        local s = (frame >= COIN + 90 and frame < COIN + 96) and 1 or 0
        start:set_value(s)
        if start2 then start2:set_value(s) end
    end
    if frame >= FRAMES then done = true; f:close(); mach:exit() end
end)
