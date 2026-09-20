-- How often does racing the beam differ from MAME's frame-at-a-time render?
--
-- MAME draws the whole frame at vblank start from the RAM as it stands then;
-- the board draws line 100 from the RAM as it stood at line 100
-- (docs/HARDWARE_NOTES.md, "Raster timing"). The two disagree exactly when a
-- write CHANGES a byte and the beam has already passed the pixels that byte
-- feeds. This counts those, over as many frames as asked, in one run.
--
--   CORE_OUT      output directory
--   CORE_FRAMES   frames to scan after CORE_SKIP
--   CORE_SKIP     frames to let the game settle first
--   CORE_COIN     frame at which to insert a coin; Start follows 90 later
--   CORE_IN_COIN, CORE_IN_START   input field names
--
-- Writes <out>/beamdiff.tsv, one row per frame that has any late write:
--   frame, late_vram_bytes, late_sram_bytes, worst_rows_late
--
-- "Late" means: the byte changed value, and the scanline it feeds had already
-- been drawn when the write landed. Only changed bytes count -- these games
-- rewrite their display lists with identical values constantly, 1,898 times a
-- frame in hattrick, and a rewrite that changes nothing cannot change a pixel.

local OUT    = os.getenv("CORE_OUT") or "."
local FRAMES = tonumber(os.getenv("CORE_FRAMES") or "1800")
local SKIP   = tonumber(os.getenv("CORE_SKIP") or "600")
local COIN   = tonumber(os.getenv("CORE_COIN") or "0")

-- balsente.h
local VBEND, VBSTART, VTOTAL = 0x10, 0x100, 0x108
local VRAM_LO, VRAM_HI = 0x0800, 0x7fff
local SRAM_LO, SRAM_HI = 0x0000, 0x00ff

local m = manager.machine
local cpu = m.devices[":maincpu"]
if not cpu then print("BEAMSCOUT no :maincpu"); m:exit(); return end
local sp = cpu.spaces["program"]

local f = assert(io.open(OUT .. "/beamdiff.tsv", "w"))
f:write("# frame\tlate_vram\tlate_sram\tworst_rows_late\n")

local function cur_line()
    local scr = m.screens[":screen"]
    local ltv = scr:time_until_vblank_start():as_double() / scr.scan_period
    return (VBSTART + VTOTAL - ltv) % VTOTAL
end

-- A write only counts if the beam is in the VISIBLE area. Lines 0-15 are the
-- top of vblank, before any visible line, so nothing can be late there; lines
-- 256-263 are the bottom of vblank, after every visible line of this frame, so
-- a write there lands before the NEXT frame is drawn and is not late either.
-- Counting vblank made a first run report 22.6% of cshift frames as differing
-- from MAME when the rendered frames differed on no pixels at all.
local function in_visible(now)
    return now >= VBEND and now < VBSTART
end

local late_v, late_s, worst = 0, 0, 0
local counting = false

-- Global: a tap or notifier held only by a local is collected and stops firing
-- silently (WORKFLOW section 9).
core_subs = {}

core_subs[#core_subs + 1] = sp:install_write_tap(VRAM_LO, VRAM_HI, "bs_vram",
    function(offset, data, mask)
        if counting then
            local ok = pcall(function()
                if sp:read_u8(offset) == (data & 0xff) then return end
                -- this byte holds two pixels of one row
                local row = (offset - VRAM_LO) // 128          -- visible row
                local drawn_at = row + VBEND                   -- absolute scanline
                local now = cur_line()
                if in_visible(now) and now > drawn_at then
                    late_v = late_v + 1
                    local d = now - drawn_at
                    if d > worst then worst = d end
                end
            end)
            if not ok then counting = false end
        end
        return data
    end)

core_subs[#core_subs + 1] = sp:install_write_tap(SRAM_LO, SRAM_HI, "bs_sram",
    function(offset, data, mask)
        if counting then
            local ok = pcall(function()
                if sp:read_u8(offset) == (data & 0xff) then return end
                -- only the 40 entries the scanout walks matter
                local ent = offset & 0xfc
                local scanned = (ent >= 0xe0) or (ent < 0xa0)
                if not scanned then return end
                local ypos = (sp:read_u8(ent + 2) + 17 + VBEND)
                local now = cur_line()
                if not in_visible(now) then return end
                -- the sprite occupies 16 lines from ypos, wrapping at 256
                local passed = true
                for k = 0, 15 do
                    local yy = (ypos + k)
                    if k > 0 then yy = (ypos + k) % 256 end
                    if yy >= (16 + VBEND) and yy <= (VBSTART - 1) and now <= yy then
                        passed = false
                        break
                    end
                end
                if passed then
                    late_s = late_s + 1
                end
            end)
            if not ok then counting = false end
        end
        return data
    end)

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        local fl = port.fields[name]
        if fl then return fl end
    end
    return nil
end

local f_coin  = COIN > 0 and field(os.getenv("CORE_IN_COIN") or "Coin 1") or nil
local f_start = COIN > 0 and field(os.getenv("CORE_IN_START") or "1 Player Start") or nil

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
        if counting and (late_v > 0 or late_s > 0) then
            f:write(string.format("%d\t%d\t%d\t%.1f\n", n - 1, late_v, late_s, worst))
        end
        late_v, late_s, worst = 0, 0, 0
        counting = n >= SKIP and n < SKIP + FRAMES
        if n > SKIP + FRAMES then
            done = true
            f:close()
            print("BEAMSCOUT done " .. OUT .. "/beamdiff.tsv")
            m:exit()
        end
    end)
    if not ok then
        local e = io.open(OUT .. "/ERROR.txt", "a")
        if e then e:write("beamscout: " .. tostring(err) .. "\n"); e:close() end
        print("BEAMSCOUT_ERROR " .. tostring(err))
        done = true
        m:exit()
    end
end)
