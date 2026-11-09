-- Shar'Drahn: dodging storms, the MA's hold while Storm Calls are up (slow mode), and
-- running into the Storm Call circles.
local mq = require("mq")
local Core = require((...):match('^(.*)%.[^.]+$'))   -- the core: this module's parent

local M = {}
M.TASK  = "Shar'Drahn"
M.giver = 'Gwork'

local def, flags, State = Core.def, Core.flags, Core.state
local announce, announce_g, debug_local = Core.announce, Core.announce_g, Core.debug_local
local cwtn, nav_to_loc = Core.cwtn, Core.nav_to_loc

Core.kill_order[M.TASK] = {"Elder_Monolith","constituent","Shar`Drahn"}
Core.BURN.boss[M.TASK]    = 'Shar`Drahn'   -- the spawn is spelled with a backtick; the task with a '
Core.BURN.trigger[M.TASK] = {'Storm Call'}
Core.BURN.emote[M.TASK]   = '#*#Drahn places a call to the storm for assistance#*#'

-- Shar'Drahn storms. A spawn named '..._storm<nn>' within STORM.DANGER of us: move to the
-- nearest STORM.ring spot with no storm within STORM.DANGER of it. Paused for the move so
-- CWTN does not drag us back through it. Storm Calls (Storm_Call) do not match, nor does
-- zone trash like a_storming_scrykin, and whoever is standing in a call circle
-- (DOING_CIRCLE) is left alone.
-- The ring is static: 5 points at 225 around Shar`Drahn's start (Y 925, X 560), first
-- point due north. Z is the floor -- he is tall and reads ~229. All five checked for a nav
-- path in the mission (2026-10-27).
local STORM = {}
STORM.DANGER = 75
STORM.ring = {
    {1150.0, 560.0, 195},
    { 994.5, 774.0, 195},
    { 743.0, 692.3, 195},
    { 743.0, 427.7, 195},
    { 994.5, 346.0, 195},
}

local function storms()
    return mq.getFilteredSpawns(function(s)
        local n = s.Name()
        return n ~= nil and n:lower():find('_storm%d*$') ~= nil
    end)
end

local function storm_near(list, y, x, radius)
    radius = radius or STORM.DANGER
    for _, s in ipairs(list) do
        local sy, sx = s.Y(), s.X()
        if sy and sx and math.sqrt((sy - y)^2 + (sx - x)^2) < radius then return true end
    end
    return false
end

-- The MA drags Shar`Drahn, who only follows until we are in his (very long) melee reach,
-- so he -- and the melee on him -- stop up to that far short of our spot, back toward the
-- storm. The MA's spot has to be clear by his reach on top of STORM.DANGER, and a storm
-- on him counts as one on the MA.
local function storm_boss()
    if not flags.MA_MODE then return nil end
    local boss = Core.burn_boss_spawn()
    if boss and boss.Y() and boss.X() then return boss end
end

local function storm_clearance()
    local boss = storm_boss()
    return STORM.DANGER + (boss and (boss.MaxRange() or 0) or 0)
end

local function do_dodge_storm(list)
    local clear = storm_clearance()
    local function clear_spots(radius)
        local spots = {}
        for _, p in ipairs(STORM.ring) do
            if not storm_near(list, p[1], p[2], radius) then
                spots[#spots + 1] = { y = p[1], x = p[2], z = p[3], d = Core.dist2d(p[1], p[2]) }
            end
        end
        table.sort(spots, function(a, b) return a.d < b.d end)
        return spots
    end
    local spots = clear_spots(clear)
    -- nowhere on the ring clears his reach too: settle for clearing ourselves
    if #spots == 0 and clear > STORM.DANGER then
        announce_g('Storm: no ring spot %.0f clear of storms, settling for %d', clear, STORM.DANGER)
        clear = STORM.DANGER
        spots = clear_spots(clear)
    end
    for _, p in ipairs(spots) do
        -- distance=: a repeat dodge to the same ring spot would otherwise re-walk to the
        -- exact point and turn us around (seen: two "moving to (743, 692)" in a row)
        if nav_to_loc(p.y, p.x, p.z, Core.tow_nav_opts() .. ' distance=5') then   -- false: no path, try the next spot
            announce('Storm within %d: moving to (%.0f, %.0f), %.0f clear', STORM.DANGER, p.y, p.x, clear)
            Core.wait_nav()
            return
        end
    end
    announce_g('Storm within %d and no clear ring spot -- move by hand', STORM.DANGER)
end

local function check_storms(list)
    if State.current_task ~= M.TASK or not flags.DODGE_STORMS then return end
    if not Core.in_instance_zone() then return end
    if flags.DOING_CIRCLE or flags.DODGING then return end
    if #list == 0 then return end
    local my, mx = mq.TLO.Me.Y(), mq.TLO.Me.X()
    if not (my and mx) then return end
    local boss = storm_boss()
    if not storm_near(list, my, mx) and not (boss and storm_near(list, boss.Y(), boss.X())) then return end
    flags.DODGING = true
    Core.pause()
    local ok, err = pcall(do_dodge_storm, list)
    if not ok then announce_g('dodge_storm error: %s', tostring(err)) end
    Core.resume()
    flags.DODGING = false
end

-- Shar'Drahn without burn mode (slow mode): Storm Calls are tied to Shar'Drahn's HP, and
-- the mission boss can be pushed through several checkpoints before the first call has
-- even spawned its add. So while ANY call is up the MA stops -- Manual (so CWTN cannot
-- pick a target of its own), attack off, self-targeted. A call finishes when it spawns
-- its Elder Monolith or constituent. Once the last one is gone, the hold lasts until an
-- add aggros (or STORM.ADD_WAIT passes), so the MA can't tag the boss in the gap. Then
-- back to its mode, and pick_target kills the adds before the boss (kill order). True
-- while holding.
local storm_st = {}
storm_st.holding   = false
storm_st.hold_mode = nil
storm_st.clear_at  = nil   -- when the last Storm Call went, while still holding
storm_st.calls_up  = 0
STORM.ADD_WAIT  = 5000  -- ms after the last call before giving up on seeing its add
STORM.done_adds = { 'elder monolith', 'constituent' }
M.st = storm_st

local function storm_call_ids()
    local ids = {}
    for _, s in ipairs(mq.getFilteredSpawns(function(s)
        return (s.CleanName() or ''):find('Storm Call', 1, true) ~= nil
    end)) do ids[#ids + 1] = s.ID() end
    return ids
end

local function storm_add_aggroed()
    for i = 1, 20 do
        local n = (mq.TLO.Me.XTarget(i).CleanName() or ''):lower()
        for _, a in ipairs(STORM.done_adds) do
            if n:find(a, 1, true) then return true end
        end
    end
    return false
end

local function storm_release(why)
    storm_st.holding = false
    storm_st.clear_at = nil
    storm_st.calls_up = 0
    announce('Storm Calls finished (%s): MA back on, adds first', why)
    Core.rgmercs_backoff(false)
    Core.set_mode(storm_st.hold_mode)
    storm_st.hold_mode = nil
end

local function storm_hold()
    if State.current_task ~= M.TASK or flags.BURN_MODE then
        if storm_st.holding then storm_release('burn mode') end
        return false
    end
    local calls = #storm_call_ids()
    if calls > 0 then
        storm_st.clear_at = nil
        if not storm_st.holding then
            storm_st.holding = true
            local m = Core.get_cwtn_mode()
            storm_st.hold_mode = (m ~= 'Manual' and m ~= 'none') and m or nil
            cwtn("mode 0")
            Core.rgmercs_backoff(true)   -- Boxr Manual only stops movement; RGMercs would re-engage
            if Core.rgmercs_lua() then mq.cmd("/rgl forcetargetclear") end
            Core.reset_engage()
        end
        if calls ~= storm_st.calls_up then
            announce('%d Storm Call(s) up: MA holding until they have all spawned', calls)
            storm_st.calls_up = calls
        end
    elseif not storm_st.holding then
        return false
    else
        storm_st.clear_at = storm_st.clear_at or mq.gettime()
        if storm_add_aggroed() then
            storm_release('add aggroed')
            return false
        elseif mq.gettime() - storm_st.clear_at > STORM.ADD_WAIT then
            storm_release('no add seen')   -- fallback: never saw the add
            return false
        end
    end
    if mq.TLO.Me.Combat() then mq.cmd("/attack off") end
    if mq.TLO.Target.ID() ~= mq.TLO.Me.ID() then mq.cmd("/target myself") end
    return true
end

-- Storm Call circles (from relic-2), slow mode only: with burn mode on, the boss is burned
-- straight through the calls instead. Whoever is assigned (storm_call.assigned >= 1: UI toggle,
-- /sorm storm_call.assigned, or /sorm assign_circle <name> from anyone in the group) runs into the
-- nearest call on the shar_storm emote, stands in it until it is gone, then backs to the banner.
local storm_call = {}
storm_call.assigned = 0
storm_call.count = 0   -- Storm Calls up
storm_call.storms = 0  -- '_storm' spawns up, counted per pulse for the UI

local function circles_wanted()
    return State.current_task == M.TASK and not flags.BURN_MODE and storm_call.assigned >= 1
end

local function go_to_circle()
    local spawn = mq.TLO.NearestSpawn('Storm Call')
    if not spawn() then
        announce_g('No aura spawns found')
        return
    end
    local sid = spawn.ID()
    flags.DOING_CIRCLE = true
    Core.pause()

    announce('Navigating to aura: %s (id %s)', spawn.Name(), tostring(sid))
    mq.cmd("/dism")
    mq.cmdf("/nav id %s distance=5",sid)
    mq.delay(500)
    debug_local('Navigating to circle(init)')
    while mq.TLO.Navigation.Active() do mq.delay(500) end
    while (spawn() ~= nil) do
        -- Arrived: nav finished and we're close enough
        if not mq.TLO.Navigation.Active() and (spawn.Distance() or 999) < 10 then
            debug_local('Arrived at aura')
        end
        -- Re-issue nav if it dropped but we're still far
        if not mq.TLO.Navigation.Active() or ((spawn.Distance() or 0) > 20) then
            debug_local('Navigating to circle(distance)')
            mq.cmdf("/nav id %s facing=backwards distance=5 log=off",sid)
        end
        debug_local('While loop tail end')
        mq.delay(def.pulse)
    end
    -- Storm Call is gone: head back to the banner (campfire if no banner) before handing
    -- control back.
    local safe = (mq.TLO.Spawn("banner")() and 'banner') or (mq.TLO.Spawn("campfire")() and 'campfire')
    if safe then
        announce('Storm Call gone, returning to %s', safe)
        -- Mounted: back up, or we overrun the banner and fall off
        mq.cmdf("/nav spawn %s%s", safe, mq.TLO.Me.Mount() and ' facing=backwards' or '')
        local started = mq.gettime()
        mq.delay(500)
        while mq.TLO.Navigation.Active() and (mq.gettime() - started) < 30000 do mq.delay(250) end
    end
    Core.resume()
    flags.DOING_CIRCLE = false
end

local function do_assigned_circle()
    if storm_call.assigned < 1 then return end
    if flags.DOING_CIRCLE then return end
    local ok, err = pcall(go_to_circle)
    if not ok then
        announce_g('go_to_circle error: %s', tostring(err))
        Core.resume()
        flags.DOING_CIRCLE = false
    end
end

-- shar_storm: "Shar'Drahn places a call to the storm for assistance". The call spawns a beat after
-- the emote, so wait up to 5s for it, then run in. Main's poll is the fallback if it's late.
local function shardrahn_storm()
    if not circles_wanted() or flags.DOING_CIRCLE then return end
    announce('Storm Call emote: heading for the circle')
    local started = mq.gettime()
    while (mq.TLO.SpawnCount("Storm Call")() or 0) < 1 and (mq.gettime() - started) < 5000 do
        mq.delay(100)
    end
    do_assigned_circle()
end

-- ============================================================
-- Mission hooks (see init.lua)
-- ============================================================

function M.events()
    mq.event('shar_storm', '#*#Drahn places a call to the storm for assistance#*#', shardrahn_storm)
end

-- MA: true while the Storm Call hold has the MA standing down (no pick_target)
M.hold = storm_hold

function M.pulse()
    local list = storms()
    storm_call.storms = #list
    check_storms(list)
    -- Storm Call circles: the emote is the trigger, this poll the fallback
    storm_call.count = mq.TLO.SpawnCount("Storm Call")() or 0
    -- Clear stuck DOING_CIRCLE flag if no circles remain
    if flags.DOING_CIRCLE and storm_call.count < 1 then
        debug_local('No circles up, clearing stuck DOING_CIRCLE flag')
        flags.DOING_CIRCLE = false
    end
    if circles_wanted() and (storm_call.count >= 1) and not flags.DOING_CIRCLE then
        do_assigned_circle()
    end
end

function M.reset()
    storm_st.holding, storm_st.hold_mode, storm_st.clear_at, storm_st.calls_up = false, nil, nil, 0
end

function M.start()
    mq.cmd("/nav spawn gwark")
    mq.delay(500)
    while mq.TLO.Navigation.Active() do mq.delay(250) end
    local gwark = mq.TLO.Spawn("npc gwark")
    if not (gwark() and Core.safe_target(gwark.ID())) then
        announce_g('Start: Gwark not in reach -- start it by hand')
        return
    end
    mq.delay(500)
    mq.cmd("/say insist")
    announce("Start: Shar'Drahn started")
    -- walk to her first: Gwark is too far from Shar'Drahn to target her from there
    local shar = mq.TLO.Spawn("npc Shar`Drahn")   -- backtick in the spawn name
    if shar() then
        mq.cmdf("/nav id %d distance=15 log=off", shar.ID())
        mq.delay(500)
        mq.delay(30000, function() return not mq.TLO.Navigation.Active() or Core.can_target(shar.ID()) end)
        Core.safe_target(shar.ID())
    end
    mq.cmd("/attack on")
end

M.commands = {
    circle = function(value)
        if value == 'now' then
            storm_call.assigned = math.max(storm_call.assigned, 1)   -- run the nearest Storm Call now
            do_assigned_circle()
        else
            storm_call.assigned = Core.bool_arg(value, storm_call.assigned >= 1) and 1 or 0
            printf('Storm Call circles: %s', storm_call.assigned >= 1 and 'on' or 'off')
        end
    end,
    -- relic-2 assigns by raid group#; a mission is one group, so assign by name
    assign_circle = function(value)
        Core.bcg("%s set_circle %s %s", def.cmd, value or def.name, 1)
    end,
    unassign_circle = function(value)
        Core.bcg("%s set_circle %s %s", def.cmd, value or def.name, 0)
    end,
    set_circle = function(value, args)
        if value and value:lower() == def.name:lower() then
            storm_call.assigned = tonumber(args[3]) or 0
            announce('%s Storm Call circles %s', def.name, storm_call.assigned >= 1 and 'assigned' or 'cleared')
        end
    end,
}

function M.usage(c)
    print('  Shar\'Drahn:')
    printf('  %s circle [on|off|now]      --> this toon runs into Storm Calls (slow mode only: burn off)', c)
    printf('  %s assign_circle|unassign_circle [name] --> assign a toon (default: me) group-wide', c)
end

function M.ui()
    local COLOR = Core.COLOR
    Core.burn_row('1st Storm Call', storm_st.holding)
    if not flags.BURN_MODE then
        ImGui.TextColored(COLOR.RED, 'WARNING:  Slow mode can result in being thrown off the\n platform by Wing Surge.')
        --ImGui.TextColored(COLOR.RED, 'WARNING:  You may need to set group to manual to pull\n this off with high power groups')
    end
    Core.status_flag('Dodge Storms:', flags.DODGE_STORMS)
    ImGui.SameLine()
    flags.DODGE_STORMS = Core.toggle_button('dodge', flags.DODGE_STORMS)
    ImGui.SameLine()
    ImGui.TextDisabled(string.format('(%d up)', storm_call.storms))
    Core.status_flag('Storm Call circles:', storm_call.assigned >= 1)
    ImGui.SameLine()
    local on = Core.toggle_button('circle', storm_call.assigned >= 1)
    if on ~= (storm_call.assigned >= 1) then storm_call.assigned = on and 1 or 0 end
    ImGui.SameLine()
    if flags.DOING_CIRCLE then ImGui.TextColored(COLOR.AMBER, 'in circle')
    elseif flags.BURN_MODE and storm_call.assigned >= 1 then ImGui.TextDisabled('(slow mode only)')
    else ImGui.TextDisabled(string.format('(%d up)', storm_call.count)) end
end

return M
