-- init.lua
-- Version 0.36
-- Created: 4/22/2024
-- Updated: 5/3/2026
-- Creator: RedFrog
-- Quest: https://special.eqresource.com/owlbearwithmeforamoment.php

--------------------------------------------------------------------
-- To-Do
--[x] add invis handling for lower level / risky paths
--[x] add movement speed handling (selo/run-speed buff/mount checks)
--[x] add robust gate/return logic (AA gate, potion, fallback route)
--[x] add retry loops for groundspawn targeting/click/loot
--[x] add trade verification for GiveWnd and item hand-in success
--[x] add final reward/completion verification (task + Lost Owlbear Pup)
--[x] fix combine function bugs (item.what, container lookup, nil safety)
--[x] fix combine container handling and slot placement reliability
--[x] add task-step checks after each quest stage (do not proceed on failure)
--[x] pause CWTN, RGmerc at start / resume at end
--[x] add OnlyLoot or Looly off at start / restore at end
--[x] use task check for crash recovery (resume from correct stage)
--[x] remove ammo slot usage
--[x] speed buff check + mount keyring slot 1 for travel speed
--[x] proper invis: AA first, potion fallback, warning if neither available
--[x] pre-quest: CanMount/speed/invis capability report, 4 free main slot check (no pouch check - received during quest)
--[x] dismount before Korah Kai interactions, remount after
--[x] ensure_speed() after water-crossing nav legs (mount may drop) - superseded below
--[x] mid-nav remount: moving() now pauses nav, remounts when CanMount true, resumes nav
--[x] handle Owlbear Migration Samples Pouch appearing on cursor after first turn-in
--[x] handle Cold Owlbear Tuft cursor return after saying fungus grove
--[x] removed task-step verification and crash recovery - not needed for this simple quest
--[x] fix pickup_groundspawn() - pass item name to /itemtarget, not generic nearest-item targeting
--[x] fix nav_busy() - overly complex truthy() nested fn; Nav TLOs return booleans, simplify
--[ ] fix secure_pouch_combine() - hardcoded bag slot 9 is fragile; find open slot dynamically
--[x] fix encoding artifacts in comments (corrupted em dashes)
--[x] overhaul ensure_invis: class-based spell table, AA ready check, dynamic memorize, Bard/Rogue paths, lev cleanup
--[x] overhaul ensure_speed: try buff AND mount independently, class spells, Bard skips mount/cast, lev cleanup
--[x] simplify is_invis to Me.Invisible() only
--[ ] verify pause_bots() - confirm /rgmerc pause vs /rgm pauseall for RGMercs on Live
--[x] replace multi-line ASCII owl art with single-line version (font alignment varies by game client)
--[x] fix forward reference in moving(): moved to after mount_if_needed() so is_mounted/mount_if_needed are defined
--[x] add Worn Totem to SPEED_ITEM_NAMES as speed item fallback in ensure_speed()
--[x] fix cast timing: two-phase wait_cast_done() replaces single delay + not-casting wait
--[x] fix constants forward reference: moved all travel/invis/lev constants above helper functions
--[x] fix /nav resume (invalid command): moving() now uses /nav pause as toggle to resume
--[x] add spell_in_book() check in memorize_spell() to skip unscribed spells instantly vs 30s timeout
--------------------------------------------------------------------

local mq = require('mq')

local function owlbear_print(msg)
    print(string.format("\ao[\agOwlBear\ao]\at %s", msg))
end

local GATE_ZONE_ID = 202
local GATE_POTION_NAMES = { "Philter of Major Translocation" }
local GATE_ATTEMPTS = 4
local GATE_ZONE_WAIT_MS = 90000

-- Mount keyring slot to use for travel speed (slot 1 = first mount in keyring)
local MOUNT_KEYRING_SLOT = 1

-- Speed buff keyword scan (buffs or songs containing these = movement speed is up)
local SPEED_BUFF_KEYWORDS = { "selo", "spirit of wolf", "spirit of the shrew",
    "spirit of cheetah", "movement speed", "swift" }

-- Invis AA names (order = preference; Bard uses INVIS_BRD_AA below)
local INVIS_AA_NAMES = {
    "Perfected Invisibility",
    "Improved Invisibility",
    "Invisibility",
    "Cloak of Shadows",
}

-- Bard invis AA — ID used for /alt act, name used for readiness check
local INVIS_BRD_AA_IDS   = { 231 }
local INVIS_BRD_AA_NAMES = { "Shauri's Sonorous Clouding" }

-- Per-class invis spell/song names (order = preference within class)
-- Classes not listed have no native invis spell; fall through to items
local INVIS_CLASS_SPELLS = {
    BRD = { "Shauri's Sonorous Clouding", "Selo's Song of Travel" },
    DRU = { "Invisibility", "Camouflage" },
    ENC = { "Superior Invisibility", "Invisibility" },
    MAG = { "Invisibility" },
    NEC = { "Skin of the Shadow", "Gather Shadows" },
    RNG = { "Camouflage" },
    SHM = { "Invisibility" },
    WIZ = { "Superior Invisibility", "Improved Invisibility", "Invisibility" },
}

-- Invis item names to try if AA/spell not available (order = preference)
local INVIS_ITEM_NAMES = { "Cloudy Potion", "Potion of Shadows", "Shadowed Potion" }

-- Per-class speed spell names (memorized into second-to-last gem slot)
-- Bard handles speed via songs natively; no entry needed
local SPEED_CLASS_SPELLS = {
    BST = { "Spirit of Wolf", "Spirit of the Shrew" },
    DRU = { "Spirit of Wolf", "Spirit of Cheetah" },
    RNG = { "Spirit of Wolf" },
    SHM = { "Spirit of Wolf", "Spirit of Cheetah" },
}

-- Speed AA names to try (order = preference)
local SPEED_AA_NAMES = { "Selo's Sonata", "Spirit of the White Wolf" }

-- Speed item clicky fallback (order = preference)
local SPEED_ITEM_NAMES = { "Worn Totem" }

-- Levitation buff names to strip after invis/speed casts (some spells add lev as a secondary)
local LEV_BUFF_NAMES = { "Shauri's Levitation" }

-- Returns true while nav is actively running OR paused (/nav pause keeps the path but
-- sets Active=false; checking only Active() causes moving() to exit early on pause).
local function nav_busy()
    return mq.TLO.Nav.Active() or mq.TLO.Nav.Paused()
end

local function zoning(z_id)
    while mq.TLO.Zone.ID() ~= z_id do
        mq.delay(1)
    end
end

local function wait_until_ms(max_ms, fn, poll_ms)
    local start = mq.gettime()
    poll_ms = poll_ms or 100
    while mq.gettime() - start < max_ms do
        if fn() then
            return true
        end
        mq.delay(poll_ms)
    end
    return fn()
end

-- Wait for a cast to start (Me.Casting non-nil), then wait for it to finish (nil).
-- Avoids the race where a 300ms flat delay exits before the cast has registered.
local function wait_cast_done(start_wait_ms, finish_wait_ms)
    wait_until_ms(start_wait_ms or 1000, function()
        local ok, c = pcall(function() return mq.TLO.Me.Casting() end)
        return ok and c ~= nil
    end, 50)
    wait_until_ms(finish_wait_ms or 8000, function()
        local ok, c = pcall(function() return mq.TLO.Me.Casting() end)
        return ok and c == nil
    end, 100)
end

local function mq_bool(v)
    if v == true then return true end
    if v == false or v == nil then return false end
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then
        local u = v:upper()
        return u == "TRUE" or u == "ON" or u == "1"
    end
    return false
end

local function has_item(name)
    local ok, found = pcall(function() return mq.TLO.FindItem(name)() end)
    return ok and found ~= nil
end

-- Scan gem slots 1-12 for a memorized spell by name (case-insensitive substring match).
-- Me.Gem[N] returns the spell NAME in slot N; there is no reverse lookup by name in MQ.
-- Returns the slot number (1-12) if found, or nil.
local function find_spell_gem(spell_name)
    local search = spell_name:lower()
    for slot = 1, 12 do
        local ok, gname = pcall(function() return mq.TLO.Me.Gem(slot)() end)
        if ok and gname then
            local n = tostring(gname):lower():gsub("^%s+", ""):gsub("%s+$", "")
            if n == search or n:find(search, 1, true) then
                return slot
            end
        end
    end
    return nil
end

-- Remove any levitation buffs that were applied as a secondary effect of an invis/speed spell
local function remove_lev_buffs()
    for _, buffName in ipairs(LEV_BUFF_NAMES) do
        local ok, bid = pcall(function() return mq.TLO.Me.Buff(buffName).ID() end)
        if ok and tonumber(bid or 0) > 0 then
            mq.cmdf('/removebuff "%s"', buffName)
            mq.delay(200)
        end
    end
end

-- Returns true if spell_name is scribed in the character's spellbook.
-- Prevents memorize_spell from burning a 30-second timeout on unscribed spells.
local function spell_in_book(spell_name)
    local search = spell_name:lower()
    for i = 1, 480 do
        local ok, sname = pcall(function() return mq.TLO.Me.Book(i)() end)
        if ok and sname and sname ~= "NULL" and sname ~= "" then
            if tostring(sname):lower() == search then return true end
        end
    end
    return false
end

-- Memorize spell_name into gem slot if not already memorized anywhere.
-- Returns true when the spell is ready to cast, false if memorization failed.
local function memorize_spell(spell_name, slot)
    if find_spell_gem(spell_name) then return true end
    if not spell_in_book(spell_name) then return false end
    mq.cmdf('/memspell %d "%s"', slot, spell_name)
    if not wait_until_ms(30000, function()
        local ok, g = pcall(function() return mq.TLO.Me.Gem(slot)() end)
        if not ok or not g then return false end
        return tostring(g):lower():find(spell_name:lower(), 1, true) ~= nil
    end, 500) then
        return false
    end
    wait_until_ms(30000, function()
        local ok, ready = pcall(function() return mq.TLO.Me.SpellReady(slot)() end)
        return ok and mq_bool(ready)
    end, 500)
    return find_spell_gem(spell_name) ~= nil
end

local function fail(msg)
    mq.cmd('/beep')
    owlbear_print("FAIL: " .. tostring(msg))
    error(msg)
end

local function item_reuse_ready(name)
    local ok, timer = pcall(function() return mq.TLO.FindItem(name).Timer() end)
    return ok and tonumber(timer or 1) == 0
end

local function is_invis()
    local ok, v = pcall(function() return mq.TLO.Me.Invisible() end)
    return ok and mq_bool(v)
end

local function is_mounted()
    local ok, name = pcall(function() return mq.TLO.Me.Mount.Name() end)
    return ok and name ~= nil and name ~= "" and name ~= "NULL"
end

local function speed_buff_present()
    for i = 1, 40 do
        local ok, bname = pcall(function() return mq.TLO.Me.Buff(i).Name() end)
        if ok and bname and bname ~= "" then
            local bl = bname:lower()
            for _, kw in ipairs(SPEED_BUFF_KEYWORDS) do
                if bl:find(kw, 1, true) then return true end
            end
        end
    end
    -- check songs (bard)
    for i = 1, 20 do
        local ok, sname = pcall(function() return mq.TLO.Me.Song(i).Name() end)
        if ok and sname and sname ~= "" then
            local sl = sname:lower()
            for _, kw in ipairs(SPEED_BUFF_KEYWORDS) do
                if sl:find(kw, 1, true) then return true end
            end
        end
    end
    return false
end

-- Returns the name of the mount in keyring slot MOUNT_KEYRING_SLOT, or nil if none.
local function keyring_mount_name()
    local ok, name = pcall(function()
        local n = mq.parse(string.format("${Mount[%d].Name}", MOUNT_KEYRING_SLOT))
        return tostring(n or ""):gsub("^%s+", ""):gsub("%s+$", "")
    end)
    if ok and name and name ~= "" and name ~= "NULL" then return name end
    return nil
end

local function mount_if_needed()
    if is_mounted() then return true end
    local mname = keyring_mount_name()
    if not mname then return false end  -- nothing in keyring

    -- CanMount() returns explicit Lua false when location forbids mounting (water,
    -- indoors, no-mount zone).  Only block on an explicit false — if the TLO returns
    -- nil or is unavailable, attempt the mount anyway (assume outdoor default).
    local ok_cm, can_mount = pcall(function() return mq.TLO.Me.CanMount() end)
    if ok_cm and can_mount == false then
        return false
    end

    mq.cmdf('/useitem ${Mount[%d]}', MOUNT_KEYRING_SLOT)
    wait_cast_done(1000, 5000)
    wait_until_ms(4000, is_mounted, 100)
    return is_mounted()
end

local function moving()
    while nav_busy() do
        if not is_mounted() and not speed_buff_present() then
            local ok_cm, can_mount = pcall(function() return mq.TLO.Me.CanMount() end)
            if ok_cm and can_mount ~= false then
                local ok_p, paused = pcall(function() return mq.TLO.Nav.Paused() end)
                local nav_was_active = not (ok_p and mq_bool(paused))
                if nav_was_active then mq.cmd('/nav pause') end
                mq.cmdf('/useitem ${Mount[%d]}', MOUNT_KEYRING_SLOT)
                wait_cast_done(500, 3000)
                if nav_was_active then mq.cmd('/nav pause') end
            end
        end
        mq.delay(100)
    end
    -- After nav: wait for CanMount (handles water-exit timing), then cast directly
    if not is_mounted() and keyring_mount_name() then
        wait_until_ms(3000, function()
            local ok, can = pcall(function() return mq.TLO.Me.CanMount() end)
            return ok and can ~= false
        end, 200)
        mq.cmdf('/useitem ${Mount[%d]}', MOUNT_KEYRING_SLOT)
        wait_cast_done(1000, 5000)
        wait_until_ms(4000, is_mounted, 100)
    end
end

local function ensure_speed()
    local ok_c, class = pcall(function() return mq.TLO.Me.Class.ShortName() end)
    class = ok_c and class or ""

    -- Bard: Selo songs handle speed natively — no mount, no spell cast
    if class == "BRD" then
        if not speed_buff_present() then
            owlbear_print("NOTE: Bard speed song not active. Resume or twist Selo manually.")
        end
        return
    end

    -- Try speed buff if not already present (independent of mount)
    if not speed_buff_present() then
        -- AA first
        for _, aa_name in ipairs(SPEED_AA_NAMES) do
            local ok_id, aa_id = pcall(function() return mq.TLO.Me.AltAbility(aa_name).ID() end)
            if ok_id and tonumber(aa_id or 0) > 0 then
                local ok_r, ready = pcall(function() return mq.TLO.Me.AltAbilityReady(aa_name)() end)
                if ok_r and mq_bool(ready) then
                    mq.cmdf('/alt act %d', aa_id)
                    wait_until_ms(5000, speed_buff_present, 200)
                    if speed_buff_present() then remove_lev_buffs() break end
                end
            end
        end
        -- Class spell — memorize into second-to-last gem if AA didn't work
        if not speed_buff_present() then
            local ok_ng, numGems = pcall(function() return mq.TLO.Me.NumGems() end)
            numGems = (ok_ng and tonumber(numGems)) or 8
            local speedSlot = math.max(numGems - 1, 1)
            for _, spell in ipairs(SPEED_CLASS_SPELLS[class] or {}) do
                if memorize_spell(spell, speedSlot) then
                    mq.cmd('/target myself')
                    mq.delay(300)
                    mq.cmdf('/cast "%s"', spell)
                    wait_cast_done(1000, 8000)
                    if speed_buff_present() then remove_lev_buffs() break end
                end
            end
        end
        -- Item clicky fallback (e.g. Worn Totem) if AA and spell both failed
        if not speed_buff_present() then
            for _, item in ipairs(SPEED_ITEM_NAMES) do
                if has_item(item) and item_reuse_ready(item) then
                    mq.cmdf('/useitem "%s"', item)
                    wait_until_ms(5000, speed_buff_present, 200)
                    if speed_buff_present() then remove_lev_buffs() break end
                end
            end
        end
        if not speed_buff_present() then
            local item_on_timer = nil
            for _, item in ipairs(SPEED_ITEM_NAMES) do
                if has_item(item) and not item_reuse_ready(item) then
                    item_on_timer = item
                    break
                end
            end
            if item_on_timer then
                owlbear_print("NOTE: Speed item '" .. item_on_timer .. "' timer not ready. Using mount for now.")
            else
                owlbear_print("NOTE: No speed buff available for this class. Using mount for now.")
            end
        end
    end

    -- Try mount independently — even if speed buff is up, we want both
    if not mount_if_needed() then
        local mname = keyring_mount_name()
        if mname then
            owlbear_print("NOTE: Cannot mount here (indoors / water / no-mount zone). Will remount when location allows.")
        else
            owlbear_print("WARNING: No mount in keyring slot " .. MOUNT_KEYRING_SLOT .. ".")
        end
    end
end

local function ensure_invis()
    if is_invis() then return end

    local ok_c, class = pcall(function() return mq.TLO.Me.Class.ShortName() end)
    class = ok_c and class or ""
    local ok_ng, numGems = pcall(function() return mq.TLO.Me.NumGems() end)
    numGems = (ok_ng and tonumber(numGems)) or 8

    -- Bard: AA first (ID-based), then song memorize — no standard invis AAs apply
    if class == "BRD" then
        for i, aa_id in ipairs(INVIS_BRD_AA_IDS) do
            local aa_name = INVIS_BRD_AA_NAMES[i] or ""
            local ok_r, ready = pcall(function() return mq.TLO.Me.AltAbilityReady(aa_name)() end)
            if ok_r and mq_bool(ready) then
                mq.cmdf('/alt act %d', aa_id)
                wait_until_ms(5000, is_invis, 200)
                if is_invis() then remove_lev_buffs() return end
            end
        end
        for _, spell in ipairs(INVIS_CLASS_SPELLS["BRD"] or {}) do
            if memorize_spell(spell, numGems) then
                mq.cmd('/target myself')
                mq.delay(300)
                mq.cmdf('/cast "%s"', spell)
                wait_cast_done(1000, 8000)
                wait_until_ms(2000, is_invis, 200)
                if is_invis() then remove_lev_buffs() return end
            end
        end

    -- Rogue: Sneak then Hide — check ready and current state before acting
    elseif class == "ROG" then
        local ok_h, hidden = pcall(function() return mq.TLO.Me.Hidden() end)
        if ok_h and mq_bool(hidden) then return end
        local ok_sn, sneaking = pcall(function() return mq.TLO.Me.Sneaking() end)
        local ok_sr, snk_ready = pcall(function() return mq.TLO.Me.AbilityReady("Sneak")() end)
        if not (ok_sn and mq_bool(sneaking)) and ok_sr and mq_bool(snk_ready) then
            mq.cmd('/doability Sneak')
            mq.delay(800)
        end
        local ok_sn2, sneaking2 = pcall(function() return mq.TLO.Me.Sneaking() end)
        if ok_sn2 and mq_bool(sneaking2) then
            mq.cmd('/doability Hide')
            wait_until_ms(4000, is_invis, 200)
        end
        if is_invis() then return end

    else
        -- AA ladder — skip if AA not ready (avoids 5s timeout on cooldown)
        for _, aa_name in ipairs(INVIS_AA_NAMES) do
            local ok_id, aa_id = pcall(function() return mq.TLO.Me.AltAbility(aa_name).ID() end)
            if ok_id and tonumber(aa_id or 0) > 0 then
                local ok_r, ready = pcall(function() return mq.TLO.Me.AltAbilityReady(aa_name)() end)
                if ok_r and mq_bool(ready) then
                    mq.cmdf('/alt act %d', aa_id)
                    wait_until_ms(5000, is_invis, 200)
                    if is_invis() then remove_lev_buffs() return end
                end
            end
        end
        -- Class spell — memorize into last gem if not already there
        for _, spell in ipairs(INVIS_CLASS_SPELLS[class] or {}) do
            if memorize_spell(spell, numGems) then
                mq.cmd('/target myself')
                mq.delay(300)
                mq.cmdf('/cast "%s"', spell)
                wait_cast_done(1000, 8000)
                wait_until_ms(2000, is_invis, 200)
                if is_invis() then remove_lev_buffs() return end
            end
        end
    end

    -- All classes: item / potion fallback
    for _, item in ipairs(INVIS_ITEM_NAMES) do
        if has_item(item) and item_reuse_ready(item) then
            mq.cmdf('/useitem "%s"', item)
            wait_until_ms(5000, is_invis, 200)
            if is_invis() then return end
        end
    end

end

local function dismount_if_mounted()
    if not is_mounted() then return end
    mq.cmd('/dismount')
    wait_until_ms(3000, function() return not is_mounted() end, 100)
end

local function ensure_travel_buffs()
    ensure_speed()
    ensure_invis()
end

-- Pick up whatever is on cursor and place in inventory safely
local function pickup_cursor_to_inv(label)
    if mq.TLO.Cursor() == nil then return end
    mq.cmd('/autoinv')
    if not wait_until_ms(4000, function() return mq.TLO.Cursor() == nil end, 100) then
        owlbear_print("WARNING: Item still on cursor after autoinv (" .. (label or "") .. "). Trying again.")
        mq.cmd('/autoinv')
        mq.delay(1000)
    end
end

-- Count total free slots available inside all equipped bags (and empty main slots)
local function count_free_bag_slots()
    local free = 0
    for bag = 23, 32 do
        local inv = mq.TLO.Me.Inventory(bag)
        if inv and inv() then
            local container_size = inv.Container()
            if container_size and tonumber(container_size) > 0 then
                for slot = 1, tonumber(container_size) do
                    local it = inv.Item(slot)
                    if it == nil or it() == nil then
                        free = free + 1
                    end
                end
            end
        else
            free = free + 1
        end
    end
    return free
end

-- Pre-quest capability report and inventory check.
-- Pouch is received DURING quest from Korah Kai - do NOT check for it here.
-- Returns false if a hard blocker is found (not enough space); caller should stop gracefully.
local function preflight_inventory_check()
    owlbear_print("--- Owlbear Quest Preflight ---")

    -- Mount / speed report
    -- Check keyring first — independent of CanMount so illusions don't hide the mount name.
    local mname = keyring_mount_name()
    local ok_can, can_mount = pcall(function() return mq.TLO.Me.CanMount() end)
    if mname then
        owlbear_print("Speed: Mount keyring slot " .. MOUNT_KEYRING_SLOT .. " = " .. mname)
        if ok_can and not mq_bool(can_mount) then
            -- CanMount false = currently indoors, underwater, or in a no-mount zone.
            owlbear_print("NOTE: CanMount is false (indoors / water / no-mount zone). " ..
                "Script will mount automatically when location allows.")
        end
    elseif speed_buff_present() then
        owlbear_print("Speed: movement buff already active.")
    else
        owlbear_print("WARNING: No mount found in keyring slot " .. MOUNT_KEYRING_SLOT ..
            " and no speed buff active. Travel will be slow.")
    end

    -- Invis ladder report: mirrors ensure_invis() priority for this class
    local ok_pc, pclass = pcall(function() return mq.TLO.Me.Class.ShortName() end)
    pclass = ok_pc and pclass or ""
    local invis_report = nil
    if pclass == "BRD" then
        for i, aa_id in ipairs(INVIS_BRD_AA_IDS) do
            local aa_name = INVIS_BRD_AA_NAMES[i] or ""
            local ok_aa, aid = pcall(function() return mq.TLO.Me.AltAbility(aa_name).ID() end)
            if ok_aa and tonumber(aid or 0) > 0 then
                invis_report = "BRD AA: " .. aa_name break
            end
        end
        if not invis_report then
            local spells = INVIS_CLASS_SPELLS["BRD"] or {}
            if #spells > 0 then invis_report = "BRD song (will memorize): " .. spells[1] end
        end
    elseif pclass == "ROG" then
        invis_report = "Rogue Sneak/Hide"
    else
        for _, aa_name in ipairs(INVIS_AA_NAMES) do
            local ok_aa, aa_id = pcall(function() return mq.TLO.Me.AltAbility(aa_name).ID() end)
            if ok_aa and tonumber(aa_id or 0) > 0 then
                invis_report = "AA: " .. aa_name break
            end
        end
        if not invis_report then
            local spells = INVIS_CLASS_SPELLS[pclass] or {}
            for _, spell in ipairs(spells) do
                if find_spell_gem(spell) then
                    invis_report = "memorized spell: " .. spell break
                end
            end
            if not invis_report and #spells > 0 then
                invis_report = "spell (will memorize): " .. spells[1]
            end
        end
    end
    if not invis_report then
        for _, item in ipairs(INVIS_ITEM_NAMES) do
            if has_item(item) then invis_report = "item: " .. item break end
        end
    end
    if invis_report then
        owlbear_print("Invis: will use " .. invis_report)
    else
        owlbear_print("WARNING: No invis method found. Will travel without invis.")
    end

    -- Free bag slot check (need 4: Cold Tuft, Pinions, Droppings, Moist Down)
    local free = count_free_bag_slots()
    if free < 4 then
        mq.cmd('/beep')
        owlbear_print(string.format("WARNING: Only %d free bag slots found. Need at least 4 for quest items.", free))
        owlbear_print("         Please free at least 1 bag slot and re-run.")
        owlbear_print("--- Preflight BLOCKED. Fix inventory and re-run. ---")
        return false
    else
        owlbear_print(string.format("Inventory: %d free bag slots available. OK.", free))
    end

    owlbear_print("--- Preflight complete. Starting quest. ---")
    return true
end

local function gate_alt_ready()
    local ok, r = pcall(function() return mq.TLO.Me.AltAbilityReady("Gate")() end)
    return ok and r
end

local function wait_for_zone_or_false(zone_id, timeout_ms)
    return wait_until_ms(timeout_ms or 60000, function()
        return mq.TLO.Zone.ID() == zone_id
    end, 100)
end

local function wait_cast_clear_or_zoned(zone_id, timeout_ms)
    local start = mq.gettime()
    timeout_ms = timeout_ms or 60000
    while mq.gettime() - start < timeout_ms do
        if mq.TLO.Zone.ID() == zone_id then
            return true
        end
        local ok, casting = pcall(function() return mq.TLO.Me.Casting() end)
        if ok and not casting then
            return false
        end
        mq.delay(100)
    end
    return mq.TLO.Zone.ID() == zone_id
end

local function try_gate_aa_to_pok()
    if mq.TLO.Zone.ID() == GATE_ZONE_ID then return true end
    if mq.TLO.Me.ZoneBound.ID() ~= GATE_ZONE_ID then return false end
    if not gate_alt_ready() then return false end

    owlbear_print("Using Gate AA to return to PoK.")
    for attempt = 1, GATE_ATTEMPTS do
        if mq.TLO.Zone.ID() == GATE_ZONE_ID then return true end
        if not gate_alt_ready() then break end
        mq.cmd('/alt act 1217')
        mq.delay(600)
        if wait_cast_clear_or_zoned(GATE_ZONE_ID, 60000) then return true end
        if wait_for_zone_or_false(GATE_ZONE_ID, GATE_ZONE_WAIT_MS) then return true end
        mq.delay(1200)
        if attempt < GATE_ATTEMPTS then
            owlbear_print("Gate AA fizzled or collapsed - waiting for Gate AA to refresh.")
            wait_until_ms(240000, gate_alt_ready, 250)
        end
    end
    return mq.TLO.Zone.ID() == GATE_ZONE_ID
end

local function try_gate_potions_to_pok()
    if mq.TLO.Zone.ID() == GATE_ZONE_ID then return true end
    if mq.TLO.Me.ZoneBound.ID() ~= GATE_ZONE_ID then return false end

    for _, potion in ipairs(GATE_POTION_NAMES) do
        if has_item(potion) then
            owlbear_print("Using " .. potion .. " to return to PoK.")
            for attempt = 1, GATE_ATTEMPTS do
                if mq.TLO.Zone.ID() == GATE_ZONE_ID then return true end
                if not has_item(potion) then break end
                if not item_reuse_ready(potion) then
                    if not wait_until_ms(240000, function() return item_reuse_ready(potion) end, 250) then
                        break
                    end
                end
                mq.cmd('/casting "' .. potion .. '" Item')
                mq.delay(600)
                if wait_cast_clear_or_zoned(GATE_ZONE_ID, 60000) then return true end
                if wait_for_zone_or_false(GATE_ZONE_ID, GATE_ZONE_WAIT_MS) then return true end
                mq.delay(1200)
                if attempt < GATE_ATTEMPTS then
                    owlbear_print("Gate fizzled or collapsed - waiting for " .. potion .. " to refresh.")
                    wait_until_ms(240000, function() return item_reuse_ready(potion) end, 250)
                end
            end
        end
    end
    return mq.TLO.Zone.ID() == GATE_ZONE_ID
end

local function gate_to_pok()
    if mq.TLO.Zone.ID() == GATE_ZONE_ID then return true end
    if try_gate_aa_to_pok() then return true end
    if try_gate_potions_to_pok() then return true end
    mq.cmd('/squelch /travelto poknowledge')
    zoning(GATE_ZONE_ID)
    return mq.TLO.Zone.ID() == GATE_ZONE_ID
end

local function require_item(item_name, context)
    if not has_item(item_name) then
        fail(string.format("%s missing required item: %s", context, item_name))
    end
end

-- Pause CWTN and RGMerc bots if running
local function pause_bots()
    mq.cmd('/squelch /cwtn pause')
    mq.cmd('/squelch /rgmerc pause')
    mq.delay(500)
end

-- Resume CWTN and RGMerc bots
local function resume_bots()
    mq.cmd('/squelch /cwtn resume')
    mq.cmd('/squelch /rgmerc resume')
    mq.delay(500)
end

-- Pause auto-loot tools so the script controls all item pickup during the quest.
-- Covers Lootly and LootnScoot — both squelched so no error if a tool isn't loaded.
local function loot_off()
    mq.cmd('/squelch /lootly off')
    mq.cmd('/squelch /lns pause')
    mq.delay(300)
    owlbear_print("Loot: Lootly / LootnScoot disabled.")
end

local function loot_on()
    mq.cmd('/squelch /lootly on')
    mq.cmd('/squelch /lns resume')
    mq.delay(300)
    owlbear_print("Loot: Lootly / LootnScoot enabled.")
end

local function pickup_groundspawn(required_item, label)
    for attempt = 1, 5 do
        mq.cmd('/squelch /itemtarget')
        mq.delay(300)
        local ok_gn, gname = pcall(function() return mq.TLO.Ground.Name() end)
        local ok_gd, gdist = pcall(function() return mq.TLO.Ground.Distance() end)
        if attempt == 1 and not (ok_gn and gname and gname ~= "NULL") then
            owlbear_print("No ground item visible near this location.")
        end
        mq.cmd("/squelch /click left item")
        mq.delay(1000)
        mq.cmd('/autoinv')
        mq.delay(400)
        mq.cmd('/autoinv')
        mq.delay(400)
        if has_item(required_item) then
            return true
        end
        mq.delay(500)
    end
    -- Final diagnostic before crashing
    local ok_gn, gname = pcall(function() return mq.TLO.Ground.Name() end)
    local ok_gd, gdist = pcall(function() return mq.TLO.Ground.Distance() end)
    if ok_gn and gname and gname ~= "NULL" then
        owlbear_print(string.format("Still seeing: '%s' at %.1f units (item name mismatch or click not working).", tostring(gname), tonumber(gdist or 0)))
    else
        owlbear_print("Ground spawn gone or never found. May have already been taken or wrong coordinates.")
    end
    fail("Could not loot " .. label .. ": " .. required_item)
    return false
end

local function give_item_to_target(item_name, target_name)
    require_item(item_name, "turn-in")

    for attempt = 1, 3 do
        mq.cmd('/tar ' .. target_name)
        mq.delay(600)
        mq.cmd('/face fast')
        mq.delay(300)

        -- Pick up item to cursor
        mq.cmdf('/squelch /nomodkey /itemnotify "%s" leftmouseup', item_name)
        mq.delay(600)

        if not wait_until_ms(3000, function() return mq.TLO.Cursor() ~= nil end, 100) then
            owlbear_print("WARNING: Could not pick up " .. item_name .. " to cursor (attempt " .. attempt .. ").")
            mq.delay(500)
        else
            -- Open give window via left-click (item on cursor triggers GiveWnd)
            mq.TLO.Target.LeftClick()
            mq.delay(800)

            -- Wait for GiveWnd to be open
            local give_open = wait_until_ms(3000, function()
                local ok, open = pcall(function() return mq.TLO.Window("GiveWnd").Open() end)
                return ok and mq_bool(open)
            end, 100)

            if give_open then
                mq.cmd("/notify GiveWnd GVW_Give_Button leftmouseup")
                mq.delay(1500)
                -- Clear any cursor remainder
                if mq.TLO.Cursor() ~= nil then
                    mq.cmd('/autoinv')
                    mq.delay(400)
                end
                mq.cmd('/keypress esc')
                mq.delay(300)
                if not has_item(item_name) then
                    return  -- success
                end
                owlbear_print("WARNING: Item still in bags after give attempt " .. attempt .. ". Retrying.")
            else
                owlbear_print("WARNING: GiveWnd did not open (attempt " .. attempt .. "). Retrying.")
                mq.cmd('/keypress esc')
                mq.delay(300)
                if mq.TLO.Cursor() ~= nil then
                    mq.cmd('/autoinv')
                    mq.delay(400)
                end
            end
        end
        mq.delay(1000)
    end

    -- After retries, warn but do not crash - let quest flow continue
    owlbear_print("WARNING: Could not confirm turn-in of " .. item_name .. " to " .. target_name .. ". Check manually.")
end

local function move_combine_container(slot, pouch_name)
    local pouch = mq.TLO.FindItem("=" .. pouch_name)
    if pouch() == nil then
        fail("Container not found: " .. pouch_name)
    end

    local itemslot = pouch.ItemSlot() - 22
    local itemslot2 = pouch.ItemSlot2() + 1
    mq.cmdf("/nomodkey /shiftkey /itemnotify in pack%s %s leftmouseup", itemslot, itemslot2)

    if not wait_until_ms(3000, function()
        local c = mq.TLO.Cursor.Name()
        return c ~= nil and string.lower(c) == string.lower(pouch_name)
    end, 100) then
        fail("Could not pick up combine container: " .. pouch_name)
    end

    mq.cmdf("/squelch /nomodkey /shiftkey /itemnotify %s leftmouseup", slot + 22)
    wait_until_ms(4000, function() return mq.TLO.Cursor() == nil end, 100)
    mq.delay(250)
    mq.cmdf("/squelch /nomodkey /ctrl /itemnotify %s rightmouseup", slot + 22)
    mq.delay(250)
end

local function combine_item(item_name, slot)
    local item = mq.TLO.FindItem("=" .. item_name)
    if item() == nil then
        fail("Combine item not found: " .. item_name)
    end

    local itemslot = item.ItemSlot() - 22
    local itemslot2 = item.ItemSlot2() + 1
    mq.cmdf("/squelch /nomodkey /ctrl /itemnotify in pack%s %s leftmouseup", itemslot, itemslot2)

    if not wait_until_ms(3000, function() return mq.TLO.Cursor() ~= nil end, 100) then
        fail("Could not pick up combine item: " .. item_name)
    end

    mq.cmd("/keypress OPEN_INV_BAGS")
    local slot2 = 0
    if mq.TLO.Me.Inventory('pack' .. slot).Container() ~= nil then
        for j = mq.TLO.Me.Inventory('pack' .. slot).Container(), 1, -1 do
            if mq.TLO.Me.Inventory('pack' .. slot).Item(j)() == nil then
                slot2 = j
            end
        end
    end
    mq.cmdf("/squelch /nomodkey /shiftkey /itemnotify in pack%s %s leftmouseup", slot, slot2)
    wait_until_ms(3000, function() return mq.TLO.Cursor() == nil end, 100)
end

local function combine_do(slot)
    for _ = 1, 10 do
        mq.cmdf("/squelch /combine pack%s", slot)
        mq.delay(200)
        if mq.TLO.Cursor() ~= nil then
            break
        end
    end
    if mq.TLO.Cursor() == nil then
        fail("Combine did not place result on cursor.")
    end
    mq.cmd("/squelch /autoinv")
    wait_until_ms(3000, function() return mq.TLO.Cursor() == nil end, 100)
end

local function secure_pouch_combine()
    local items = {
        "Fresh Owlbear Pinions",
        "Warm Owlbear Droppings",
        "Moist Owlbear Down",
        "Cold Owlbear Tuft"
    }

    local pouch_name = "Owlbear Migration Samples Pouch"
    require_item(pouch_name, "combine")
    for _, item in ipairs(items) do
        require_item(item, "combine")
    end

    move_combine_container(9, pouch_name)
    for _, item in ipairs(items) do
        combine_item(item, 9)
    end
    combine_do(9)
    require_item("Secured Migration Samples Pouch", "combine result")
end

-- Start
mq.cmd('/beep')
owlbear_print("  ,___, ")
owlbear_print(" ( O,O )")
owlbear_print("Owlbear with Me for a Moment  v0.36")
owlbear_print("Creator: RedFrog")
mq.delay(500)
mq.cmd('/popup Lets start our Quest for an OwlBear Pup !')
local start_time = os.time()

-- Pre-quest capability report and inventory check
if not preflight_inventory_check() then
    return
end

-- Pause bots and disable auto-loot for clean run
pause_bots()
loot_off()
mq.cmd('/removelev')

-- Step 1: Hollowshade — say 'balance' to Korah Kai to start quest.
if mq.TLO.Zone.ID() ~= 166 then
    ensure_speed()
    mq.cmd('/squelch /travelto hollowshade')
    zoning(166)
end
ensure_travel_buffs()   -- always run here: mount + invis before first nav
mq.cmd('/squelch /nav locyxz 1005.7 1954.6 29.1')
moving()
mq.delay(300)
dismount_if_mounted()
mq.cmd('/tar Korah Kai')
mq.delay(500)
mq.cmd('/face fast')
mq.cmd('/say balance')
mq.delay(2000)
mq.cmd('/keypress esc')
mq.delay(300)
owlbear_print("Step 1: Quest started with Korah Kai.")

-- Step 2: Hollowshade ground spawn — pick up Cold Owlbear Tuft.
mount_if_needed()
ensure_invis()
mq.cmd('/nav locyxz 2654.1 -2524.5 246.4')
moving()
ensure_travel_buffs()
mq.delay(300)
pickup_groundspawn("Cold Owlbear Tuft", "Hollowshade")
mq.cmd('/keypress esc')
owlbear_print("Step 2: Cold Owlbear Tuft picked up.")

-- Step 3: Return to Korah Kai, give Cold Owlbear Tuft.
-- She hands back Owlbear Migration Samples Pouch on cursor — pick it up.
ensure_invis()
mq.cmd('/squelch /nav locyxz 1005.7 1954.6 29.1')
moving()
mq.delay(300)
dismount_if_mounted()
give_item_to_target("Cold Owlbear Tuft", "Korah Kai")
mq.delay(1500)
pickup_cursor_to_inv("Owlbear Migration Samples Pouch")
if has_item("Owlbear Migration Samples Pouch") then
    owlbear_print("Step 3: Received Owlbear Migration Samples Pouch.")
else
    owlbear_print("WARNING Step 3: Owlbear Migration Samples Pouch not found. Check inventory.")
end
mq.cmd('/keypress esc')

-- Step 4: Grimling Forest — pick up Fresh Owlbear Pinions.
ensure_speed()
mq.cmd('/squelch /travelto grimling')
zoning(167)
ensure_travel_buffs()
mq.cmd('/nav locyxz 1258.7 -936.9 38.2')
moving()
ensure_travel_buffs()
mq.delay(300)
pickup_groundspawn("Fresh Owlbear Pinions", "Grimling Forest")
mq.cmd('/keypress esc')
owlbear_print("Step 4: Fresh Owlbear Pinions picked up.")

-- Step 5: Tenebrous Mountains — auto-update near Katta Castellum entrance.
ensure_speed()
mq.cmd('/squelch /travelto tenebrous')
zoning(172)
ensure_travel_buffs()
mq.cmd('/nav locyxz 40.0 1515.0 -50.0')
moving()
ensure_travel_buffs()
mq.delay(300)
owlbear_print("Step 5: Tenebrous Mountains auto-update.")

-- Step 6: Twilight Sea — pick up Warm Owlbear Droppings.
ensure_speed()
mq.cmd('/squelch /travelto twilight')
zoning(170)
ensure_travel_buffs()
mq.cmd('/nav locyxz -1033.4 261.8 -26.0')
moving()
ensure_travel_buffs()
mq.delay(300)
pickup_groundspawn("Warm Owlbear Droppings", "Twilight Sea")
mq.cmd('/keypress esc')
owlbear_print("Step 6: Warm Owlbear Droppings picked up.")

-- Step 7: Fungus Grove — pick up Moist Owlbear Down.
ensure_speed()
mq.cmd('/squelch /travelto fungusgrove')
zoning(157)
ensure_travel_buffs()
mq.cmd('/nav locyxz 1974.2 1729.0 -127.5')
moving()
ensure_travel_buffs()
mq.delay(300)
pickup_groundspawn("Moist Owlbear Down", "Fungus Grove")
mq.cmd('/keypress esc')
owlbear_print("Step 7: Moist Owlbear Down picked up.")

-- Step 8: Return to Hollowshade, say 'fungus grove' to Korah Kai.
-- She gives back Cold Owlbear Tuft on cursor — pick it up.
if mq.TLO.Zone.ID() ~= 166 then
    gate_to_pok()
    ensure_speed()
    mq.cmd('/squelch /travelto hollowshade')
    zoning(166)
    ensure_travel_buffs()
end
ensure_invis()
mq.cmd('/squelch /nav locyxz 1005.7 1954.6 29.1')
moving()
mq.delay(300)
dismount_if_mounted()
mq.cmd('/tar Korah Kai')
mq.delay(500)
mq.cmd('/face fast')
mq.cmd('/say fungus grove')
mq.delay(2000)
pickup_cursor_to_inv("Cold Owlbear Tuft return")
if has_item("Cold Owlbear Tuft") then
    owlbear_print("Step 8: Cold Owlbear Tuft received back.")
else
    owlbear_print("WARNING Step 8: Cold Owlbear Tuft not found after fungus grove say.")
end
mq.cmd('/keypress esc')

-- Step 9: Combine all 4 items in Owlbear Migration Samples Pouch.
owlbear_print("Step 9: Combining items in pouch...")
secure_pouch_combine()
owlbear_print("Step 9: Secured Migration Samples Pouch created.")

-- Step 10: Give Secured Migration Samples Pouch to Korah Kai for reward.
give_item_to_target("Secured Migration Samples Pouch", "Korah Kai")
owlbear_print("Step 10: Final turn-in complete.")

-- Restore bots and loot
loot_on()
resume_bots()

mq.cmd('/keypress CLOSE_INV_BAGS')
mq.delay(300)

if has_item("Lost Owlbear Pup") then
    print(string.format("\ao[\agOwlBear\ao]\at Reward confirmed: \amLost Owlbear Pup\ax"))
else
    owlbear_print("Reward not found in inventory yet. Verify task completion/reward manually.")
end

mq.cmd('/beep')
mq.cmd('/beep')
owlbear_print("You now have completed the first of three Rathe Day quests, congratulations !")
local end_time = os.time()
local elapsed = end_time - start_time
local mins    = math.floor(elapsed / 60)
local secs    = elapsed % 60
local time_str
if mins > 0 then
    time_str = string.format("%d min %d %s", mins, secs, secs == 1 and "second" or "seconds")
else
    time_str = string.format("%d %s", secs, secs == 1 and "second" or "seconds")
end
owlbear_print("Quest Run Time... \ay" .. time_str .. "\ax")
