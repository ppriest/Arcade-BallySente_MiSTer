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
f:close()
print("PROBE done")
m:exit()
