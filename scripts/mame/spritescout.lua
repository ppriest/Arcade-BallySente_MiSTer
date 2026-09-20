-- Which frames are worth capturing, per frame, in one MAME run.
--
-- A capture is only evidence for the paths it runs, and most frames of most
-- Bally/Sente games run very few: attract mode points all 40 sprite entries at
-- image 0, which is blank. Rather than capture frames at random and inspect
-- them afterwards, this walks the sprite list every frame and says what each
-- one would exercise, so `scripts/mame_capture.py` can be pointed at the frames
-- that matter.
--
--   CORE_OUT     output directory
--   CORE_FRAMES  frames to scan (default 5400, 90 seconds)
--   CORE_COIN    frame at which to insert a coin; Start follows 90 later
--   CORE_IN_COIN, CORE_IN_START   input field names (regions.json "inputs")
--
-- Writes <out>/sprites.tsv:  frame, live entries, OR of flags, distinct images,
-- min/max X, min/max Y. "Live" means the image number is non-zero; image 0 is
-- the blank tile every idle entry points at.

local OUT    = os.getenv("CORE_OUT") or "."
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "5400")
local COIN   = tonumber(os.getenv("CORE_COIN") or "0")

local m   = manager.machine
local cpu = m.devices[":maincpu"]
if not cpu then
    print("SCOUT no :maincpu")
    m:exit()
    return
end
local sp = cpu.spaces["program"]

local f = assert(io.open(OUT .. "/sprites.tsv", "w"))
f:write("# frame\tlive\tflags_or\timages\tminx\tmaxx\tminy\tmaxy\n")

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        local fl = port.fields[name]
        if fl then return fl end
    end
    return nil
end

local f_coin  = COIN > 0 and field(os.getenv("CORE_IN_COIN") or "Coin 1") or nil
local f_start = COIN > 0 and field(os.getenv("CORE_IN_START") or "1 Player Start") or nil

-- Global: a notifier held only by a local is collected and stops firing
-- silently (WORKFLOW section 9).
core_subs = {}
local done = false

core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(function()
    if done then return end
    local ok, err = pcall(function()
        local scr = m.screens[":screen"]
        local n = scr:frame_number()
        if f_coin and f_start then
            f_coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
            f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
        end
        if n > FRAMES then
            done = true
            f:close()
            print("SCOUT done " .. OUT .. "/sprites.tsv")
            m:exit()
            return
        end

        local live, orflags = 0, 0
        local images, nimg = {}, 0
        local minx, maxx, miny, maxy = 999, -1, 999, -1
        for i = 0, 39 do
            local p = (0xe0 + i * 4) & 0xff
            local b0 = sp:read_u8(p)
            local b1 = sp:read_u8(p + 1)
            local b2 = sp:read_u8(p + 2)
            local b3 = sp:read_u8(p + 3)
            local image = b1 | ((b0 & 7) << 8)
            if image ~= 0 then
                live = live + 1
                orflags = orflags | b0
                if not images[image] then images[image] = true; nimg = nimg + 1 end
                if b3 < minx then minx = b3 end
                if b3 > maxx then maxx = b3 end
                if b2 < miny then miny = b2 end
                if b2 > maxy then maxy = b2 end
            end
        end
        if live > 0 then
            f:write(string.format("%d\t%d\t%02X\t%d\t%d\t%d\t%d\t%d\n",
                                  n, live, orflags, nimg, minx, maxx, miny, maxy))
        end
    end)
    if not ok then
        local e = io.open(OUT .. "/ERROR.txt", "a")
        if e then e:write("scout: " .. tostring(err) .. "\n"); e:close() end
        print("SCOUT_ERROR " .. tostring(err))
        done = true
        m:exit()
    end
end)
