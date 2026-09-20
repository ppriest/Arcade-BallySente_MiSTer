-- Probe what this MAME build's Lua API actually provides, rather than writing
-- against the online docs (WORKFLOW section 9). Kept because the answer changes
-- with the MAME version: run it first whenever a capture script is written
-- against a device or a binding this project has not used before.
--
--   CORE_OUT=<dir>, CORE_SCRIPT=<this file>, -autoboot_script run.lua
--   -> <dir>/probe.txt
local f = assert(io.open((os.getenv("CORE_OUT") or ".") .. "/probe.txt", "w"))
local m = manager.machine

f:write("time type: " .. type(m.time) .. "\n")
local ok, v = pcall(function() return m.time:as_double() end)
f:write("time:as_double() -> " .. tostring(ok) .. " " .. tostring(v) .. "\n")
ok, v = pcall(function() return m.time.seconds end)
f:write("time.seconds -> " .. tostring(ok) .. " " .. tostring(v) .. "\n")
ok, v = pcall(function() return m.time.attoseconds end)
f:write("time.attoseconds -> " .. tostring(ok) .. " " .. tostring(v) .. "\n")

local d = m.devices[":audio6vb:audiocpu"]
f:write("audio6vb audiocpu: " .. tostring(d) .. "\n")
if d then
    for k, _ in pairs(d.spaces) do f:write("  space: " .. k .. "\n") end
end

for tag, _ in pairs(m.devices) do
    if tag:find("cem") or tag:find("audio") or tag:find("pit") or tag:find("noise")
        or tag:find("6vb") then
        f:write("device: " .. tag .. "\n")
    end
end

-- Screen: what this build exposes for locating a write within a frame.
-- balsente_v.cpp's palette_select_w uses m_screen->vpos(), which the Lua
-- binding does NOT have (luaengine.cpp's screen_dev_type has no vpos or hpos),
-- so the scanline has to be derived. This says from what.
local scr = m.screens[":screen"]
f:write("screen: " .. tostring(scr) .. "\n")
for _, name in ipairs({"width", "height", "refresh", "pixel_period", "scan_period",
                       "frame_period", "xoffset", "yoffset"}) do
    local ok, v = pcall(function() return scr[name] end)
    f:write("  ." .. name .. " -> " .. tostring(ok) .. " " .. tostring(v) .. "\n")
end
for _, name in ipairs({"vpos", "hpos", "frame_number"}) do
    local ok, v = pcall(function() return scr[name](scr) end)
    f:write("  :" .. name .. "() -> " .. tostring(ok) .. " " .. tostring(v) .. "\n")
end
local okv, tv = pcall(function() return scr:time_until_vblank_start() end)
f:write("  :time_until_vblank_start() -> " .. tostring(okv) .. " " .. tostring(tv) .. "\n")
if okv then
    local ok2, d = pcall(function() return tv:as_double() end)
    f:write("      :as_double() -> " .. tostring(ok2) .. " " .. tostring(d) .. "\n")
end
f:close()
print("PROBE done")
m:exit()
