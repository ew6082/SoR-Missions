-- Echo of Hate chambers. Each time the Echo sends its power into the labyrinth the group
-- clears the next mini room in ECHO.order: click the inner switch in the middle to port
-- into the room, kill its mini, click the room's switch to port back, then go Chase and
-- fight the Echo until the next emote. Porting down to phase 2 also switches to Chase. Every move is made in Manual --
-- adds are usually left up, so nothing may chase or walk to a mini; the switches are the
-- only allowed way in and out. (hopefully)
-- Sections: rooms and ports, the illusion, phase 2, and giving plat to the greedlings.
local mq = require("mq")
local Core = require((...):match('^(.*)%.[^.]+$'))   -- the core: this module's parent

local E = {}
E.TASK  = "Echo of Hate"
E.giver = 'Kerina'
-- The illusion's "You have defeated Echo of Hate." event says it (event_echo_defeated)
E.own_kill_announce = true

local ECHO = {}
local echo_st = {}
E.ECHO, E.st = ECHO, echo_st

local def, flags, State = Core.def, Core.flags, Core.state
local announce, announce_g, debug_local = Core.announce, Core.announce_g, Core.debug_local
local safe_target, dist2d, is_healer = Core.safe_target, Core.dist2d, Core.is_healer
local cwtn, get_cwtn_mode, nav_to_loc = Core.cwtn, Core.get_cwtn_mode, Core.nav_to_loc

Core.kill_order[E.TASK] = {"a_rageling","a_spiteling","a_greedling","a_grudgeling","an_echo"}

ECHO.order = {'north', 'east', 'south', 'west'}
echo_st.next = 1   -- index into ECHO.order of the room the next emote sends us to
ECHO.center = {8, 3, -23}
ECHO.inner_switch = {
    south = {-111, 3, -23},
    west  = {8, 123, -23},
    north = {128, 3, -23},
    east  = {8, -118, -23},
}
ECHO.room_switch = {
    south = {-521, 3, -23},
    west  = {8, 532, -23},
    north = {540, 2, -23},
    east  = {8, -524, -23},
}
ECHO.mini = {
    north = 'Dark Flagellant',
    east  = 'Dark Oppressor',
    south = 'Dark Stranger',
    west  = 'Dark Maniac',
}
-- Mode to fight the mini in, from the mode we came in with. Anything with a home point
-- would walk back to it in the middle, so those swap to their no-home equivalent.
-- Names as CWTN.Mode reports them (see MODE_NUM in init.lua).
ECHO.room_mode = { Assist=3, Camp=3, Chase=2, ChaseAssist=2, Vorpal=3, VorpalAssist=3, Tank=7, PullerTank=7, PullerAssist=3, SicTank=7, HunterTank=7 }
ECHO.MINI_WAIT = 60    -- s for a room's mini to show before giving up on that room
ECHO.MINI_MAX  = 600   -- s cap on any one room
ECHO.MINI_NAV_MAX = 250 -- max nav path to the mini from inside its room
echo_st.pending = false
echo_st.abort = false
echo_st.saved_mode = nil

-- The Echo is 'an echo' (#an_echo00) in both phases, never "Echo of Hate" (the old
-- lookup by that name found nothing). No '=': the '#' prefix defeats an exact match.
local function echo_boss()
    local s = mq.TLO.Spawn("npc an echo")
    if s() then return s end
end

-- With KILL_GREEDLING off the MA never picks a greedling: someone is handing it coin,
-- which makes it leave. Echo's add wait still counts it, so nobody moves on until it has.
local function ignored_greedling(name)
    return not flags.KILL_GREEDLING and name ~= nil and name:lower():find('greedling', 1, true) ~= nil
end

-- Off an ignored greedling: onto the Echo if it is up, else self-target with attack off.
-- Not a bare target clear -- the group Chases the MA's target, so give it somewhere to go.
-- SicTank picks its own target and would swap off the self-target, so that waits in
-- Manual; engage() puts SicTank back (State.self_held).
local function leave_greedling()
    -- RGMercs would auto-target it straight back: ignore it for the session there
    if Core.rgmercs_lua() and mq.TLO.Target.ID() then mq.cmdf("/rgl ignoretarget %d", mq.TLO.Target.ID()) end
    local echo = echo_boss()
    if echo then
        debug_local('leaving the greedling alone, swapping to the Echo')
        Core.ma_target(echo.ID())
    else
        debug_local('leaving the greedling alone, self-targeting')
        if (get_cwtn_mode() or ''):find('Sic') then
            cwtn("mode 0")
            State.self_held = true
        end
        mq.cmd("/attack off")
        mq.cmd("/target myself")
    end
end

local function echo_nearest_room()
    local best, best_d = nil, math.huge
    for dir, l in pairs(ECHO.room_switch) do
        local d = dist2d(l[1], l[2])
        if d < best_d then best, best_d = dir, d end
    end
    return best
end

-- Where we are, by position alone: 'center', a room direction, or 'between' (out in the
-- labyrinth). Only far out is unambiguously a room -- a toon chasing an add past the
-- middle used to read as being in the nearest room, so it skipped the click and walked
-- to the mini. echo_port trusts a detected teleport over this wherever it can.
ECHO.CENTER_MAX = 175
ECHO.ROOM_MIN   = 400   -- room switches sit ~530 out
local function echo_where()
    local dc = dist2d(ECHO.center[1], ECHO.center[2])
    if dc < ECHO.CENTER_MAX then return 'center' end
    if dc > ECHO.ROOM_MIN then return echo_nearest_room() end
    return 'between'
end

-- Manual and attack off, and wait for CWTN to actually be in Manual before moving.
-- Remembers the first non-Manual mode seen so it can be put back at the end.
local function echo_manual()
    local m = get_cwtn_mode()
    if not echo_st.saved_mode and m ~= 'Manual' and m ~= 'none' then echo_st.saved_mode = m end
    cwtn("mode 0")
    mq.cmd("/attack off")
    -- Manual does not stop a nav CWTN already started (a Chase after an MA who just ported).
    -- Only when one is running: an idle /nav stop prints "No navigation path currently active".
    if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
    mq.delay(1500, function() local c = get_cwtn_mode() return c == 'Manual' or c == 'none' end)
end

-- Nav to a switch and click it. True only if we then TELEPORTED: a jump of 150+ units
-- within 3s of the click, while standing still in Manual. Walking can never pass this,
-- unlike a "which region am I in now" test.
-- Longest nav we will make to a switch. From inside a room or the middle the switch is a
-- short walk; anything longer runs through the labyrinth and drags its mobs back with us.
ECHO.SWITCH_NAV_MAX = 250
ECHO.SWITCH_REACH   = 12    -- how close to the switch spot counts as on it
-- The first click on a middle switch makes the switches vanish ("The device triggers and
-- the others disappear"), stranding anyone not yet through -- seen live 2026-11-01, the MA
-- (last off the ling) left alone in the middle for west. So on a middle switch everyone
-- but the MA stands on it until the MA has ported, then clicks. Capped, so a dead or stuck
-- MA cannot cost the room.
ECHO.MA_PORT_WAIT = 30   -- s
local function echo_wait_ma_port(label)
    if flags.MA_MODE then return end
    local ma = mq.TLO.Group.MainAssist()
    if not ma or ma == def.name then return end
    local function ma_gone()
        local s = mq.TLO.Spawn("pc ="..ma)
        if not s() then return true end   -- not in zone (or dead): nothing to wait for
        local y, x = s.Y(), s.X()
        return y and x and math.sqrt((y - ECHO.center[1])^2 + (x - ECHO.center[2])^2) > ECHO.CENTER_MAX or false
    end
    if ma_gone() then return end
    announce('Echo: on the %s switch, waiting for %s to port first', label, ma)
    local t0 = mq.gettime()
    while not ma_gone() and not echo_st.abort do
        if (mq.gettime() - t0) > ECHO.MA_PORT_WAIT * 1000 then
            announce_g('Echo: %s has not ported after %ds -- clicking the %s switch anyway', ma, ECHO.MA_PORT_WAIT, label)
            return
        end
        mq.delay(100)
    end
end

-- Returns ok, why. why = 'far' (refused, too long a walk), 'summoned', 'nopath', 'miss'
-- (never clicked: off the spot, wrong or no switch -- free to retry) or 'noport' (clicked,
-- no port: the click may still have been spent, so echo_port rations these).
-- ma_first: a middle switch -- hold for the MA's port before clicking (echo_wait_ma_port).
ECHO.PORT_WAIT = 10   -- s after a click for the port to land before calling it a miss
-- wait_nav, but stops the nav and returns true if we are teleported mid-way. The
-- Echo summons to the middle: a nav to a room switch would carry on from there, out
-- through the labyrinth with the Echo leashing behind (seen live 2026-11-01, the MA
-- summoned on its way to the switch back from a room -- adds and a wipe).
local function echo_wait_nav_or_summon()
    local function pos() return mq.TLO.Me.Y(), mq.TLO.Me.X() end
    local y0, x0 = pos()
    local function jumped()
        local y, x = pos()
        if not (y and x and y0 and x0) then return false end
        local d = math.sqrt((y - y0)^2 + (x - x0)^2)
        y0, x0 = y, x
        return d > 60   -- in 100ms; run speed covers a few units
    end
    local t = mq.gettime()
    while not mq.TLO.Navigation.Active() and (mq.gettime() - t) < 1000 do
        if jumped() then
            if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
            return true
        end
        mq.delay(100)
    end
    t = mq.gettime()
    while mq.TLO.Navigation.Active() and (mq.gettime() - t) < 30000 do
        if jumped() then
            if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
            return true
        end
        mq.delay(100)
    end
    return false
end

local function echo_click_switch(loc, label, ma_first)
    local function too_far()
        local len = mq.TLO.Navigation.PathLength(string.format('locyxz %.1f %.1f %.1f', loc[1], loc[2], loc[3]))() or -1
        if len > ECHO.SWITCH_NAV_MAX then
            announce_g('Echo: the %s switch is %.0f away by nav -- not walking the labyrinth, move me by hand', label, len)
            return true
        end
    end
    if too_far() then return false, 'far' end
    -- Selo's (a bard in the group) runs us past the nav's stop point, so approach, let the
    -- slide finish, and re-approach while we are off the spot. Each leg is short: we only
    -- get here with the switch within ECHO.SWITCH_NAV_MAX -- re-checked every leg, since a
    -- summon between legs puts it the labyrinth's width away.
    for leg = 1, 3 do
        if leg > 1 and too_far() then return false, 'far' end
        Core.remove_selos()
        if not nav_to_loc(loc[1], loc[2], loc[3]) then
            announce_g('Echo: no nav path to the %s switch', label)
            return false, 'nopath'
        end
        if echo_wait_nav_or_summon() then
            announce_g('Echo: %s teleported on the way to the %s switch -- not walking back to it', def.name, label)
            return false, 'summoned'
        end
        mq.delay(1000, function() return not mq.TLO.Me.Moving() end)
        if dist2d(loc[1], loc[2]) <= ECHO.SWITCH_REACH then break end
        debug_local('Echo: %.0f off the %s switch after nav (leg %d)', dist2d(loc[1], loc[2]), label, leg)
    end
    if dist2d(loc[1], loc[2]) > 20 then
        announce_g('Echo: could not stop on the %s switch (%.0f off)', label, dist2d(loc[1], loc[2]))
        return false, 'miss'
    end
    if ma_first then echo_wait_ma_port(label) end
    local y0, x0 = mq.TLO.Me.Y(), mq.TLO.Me.X()
    local function jumped()
        local y, x = mq.TLO.Me.Y(), mq.TLO.Me.X()
        return (y and x and y0 and x0) and math.sqrt((y - y0)^2 + (x - x0)^2) > 150 or false
    end
    -- By name: a bare /doortarget took the nearest door, once an OBJ_DOORXL we had slid
    -- up to. There are more magic switches out in the labyrinth, so also check this one
    -- sits where the switch we want does.
    mq.cmd("/doortarget OBJ_MAGICSWITCH")
    mq.delay(200)
    local d = mq.TLO.DoorTarget
    local off = math.sqrt(((d.Y() or 1e6) - loc[1])^2 + ((d.X() or 1e6) - loc[2])^2)
    if off > 15 then
        debug_local('Echo: nearest switch (%s) is %.0f from the %s switch spot', tostring(d.ID()), off, label)
        return false, 'miss'
    end
    if (d.Distance() or 999) > 20 then
        announce_g('Echo: the %s switch is out of reach (%.0f)', label, d.Distance() or 999)
        return false, 'miss'
    end
    -- a click made mid-cast is refused, and would read as a port that never came
    if def.class ~= 'BRD' then mq.delay(5000, function() return not mq.TLO.Me.Casting() end) end
    mq.cmd("/click left door")
    -- One long wait, not a quick re-click: a port under raid lag can take several seconds,
    -- and a second click while it is still coming spends another of the switch's uses.
    mq.delay(ECHO.PORT_WAIT * 1000, jumped)
    if jumped() then return true end
    announce_g('Echo: clicked the %s switch, no port after %ds', label, ECHO.PORT_WAIT)
    return false, 'noport'
end

-- Get to `want` ('center' or a room direction) by switch clicks only -- never by walking
-- toward a room. Tracks where we are from detected teleports rather than position: a
-- port out of the middle lands us in a room (the nearest one, by position), a port out
-- of a room lands us in the middle. Each try re-navs to the switch and re-clicks it; a
-- port into the wrong room is undone through that room's own switch.
-- Budgeted by time and by clicks actually sent, not by tries: a try that never clicked
-- (a Selo's slide off the spot, the switch not found yet) costs nothing and is retried
-- for the whole budget, where 5 counted tries used to burn out in a few seconds.
ECHO.PORT_MAX  = 90   -- s for one echo_port (an MA_PORT_WAIT hold counts against it)
ECHO.CLICK_MAX = 3    -- clicks with no port before giving up on one switch
local function echo_port(want)
    local here = echo_where()
    local t0, clicks, attempt = mq.gettime(), {}, 0
    while (mq.gettime() - t0) < ECHO.PORT_MAX * 1000 do
        attempt = attempt + 1
        if here == want then return true end
        if echo_st.abort then return false end
        -- Out in the labyrinth, neither in a room nor the middle: never walk out of it,
        -- that pulls its mobs. Stop and leave it to the driver.
        if here == 'between' then
            announce_g('Echo: out in the labyrinth (not in a room or the middle) -- move me by hand')
            return false
        end
        -- in the middle: the wanted room's inner switch.
        -- in a room: that room's own switch, back to the middle.
        local in_room = (here ~= 'center')
        local label = in_room and here or want
        local loc = in_room and ECHO.room_switch[here] or ECHO.inner_switch[want]
        local key = in_room and ('room ' .. here) or ('inner ' .. want)
        if (clicks[key] or 0) >= ECHO.CLICK_MAX then
            announce_g('Echo: clicked the %s switch %d times with no port -- giving up on it', label, clicks[key])
            break
        end
        local ok, why = echo_click_switch(loc, label, not in_room)
        if ok then
            here = in_room and 'center' or echo_nearest_room()
        elseif why == 'far' then
            return echo_where() == want   -- a summon can do the trip for us
        else
            if why == 'noport' then clicks[key] = (clicks[key] or 0) + 1
            else mq.delay(1000) end   -- never clicked: settle, then try again
            -- no port seen: trust our position over the last known place, so a port that
            -- did happen (or a walk) is never followed by a nav back to the old switch
            here = echo_where()
        end
        debug_local('Echo: wanted %s, now in %s (try %d, %s)', want, tostring(here), attempt, tostring(why or 'ported'))
        announce('Echo: Used %s crystal, now in %s', want, tostring(here))
    end
    if here == want then return true end
    announce_g('Echo: could not get to %s -- move me by hand', want)
    return false
end

-- North: put the Flagellant on xtarget and have the healers heal it. Everyone stays in
-- Manual; healers close to xtarget range inside the room if they landed too far off.
local function echo_heal_flagellant(mob)
    if not is_healer() then return end
    if (mob.Distance() or 999) > 100 then
        mq.cmdf("/nav id %d distance=50 log=off", mob.ID())
        Core.wait_nav()
    end
    mq.cmdf("/xtarget set 20 %s", mob.Name())
    mq.delay(200)   -- let the xtarget slot populate first
    -- nosave: a saved healnpc outlives the run and heals him next time, with HEAL_NORTH off
    cwtn("xtargethealnpc on nosave")
    cwtn("usextargethealing on nosave")
    cwtn("healnpc 99 nosave")
    announce('Echo: healing %s', mob.Name())
end

-- HEAL_NORTH off (achievement): he has to die, so healers must not touch him. CWTN only
-- heals an NPC on xtarget, and he can get there without us: a slot 20 pin left from a
-- heal-on run, or a slot the player set to the MA's target. So unpin him and switch NPC
-- healing off, which covers any slot. echo_room puts the setting back once he is gone.
-- CWTN.XTargetHealNPC (exact case; healer classes only) is saved in flags.XTHN_SAVED as
-- {value} -- a table, so a FALSE setting still reads as "saved".
local function echo_ignore_flagellant(mob)
    if not is_healer() then return end
    if mq.TLO.Me.XTarget(20).ID() == mob.ID() then mq.cmd("/xtarget set 20 autohater") end
    if not flags.XTHN_SAVED then
        local ok, v = pcall(function() return mq.TLO.CWTN.XTargetHealNPC() end)
        flags.XTHN_SAVED = {}
        if ok then flags.XTHN_SAVED[1] = v end
    end
    cwtn("xtargethealnpc off nosave")
    announce('Echo: Heal North off, not healing the Flagellant (xtargethealnpc was %s)',
        tostring(flags.XTHN_SAVED[1]))
end

local function echo_restore_xtargethealnpc()
    if not flags.XTHN_SAVED then return false end
    local v = flags.XTHN_SAVED[1]
    flags.XTHN_SAVED = nil
    if v == nil then
        announce_g('Echo: could not read xtargethealnpc earlier -- left it off')
    else
        cwtn(string.format("xtargethealnpc %s nosave", v and 'on' or 'off'))
        debug_local('Echo: Flagellant gone, xtargethealnpc back %s', v and 'on' or 'off')
    end
    return true
end

-- In the room: target the mini once it shows, fight it, and return when it has come and
-- gone. Stays in Manual until the group MA is in the room too, so the fight mode cannot
-- chase someone still in the middle. North (the Flagellant) is never attacked: it is
-- healed while HEAL_NORTH is on, and just waited out when it is off (achievement).
-- The room's mini by exact clean name. Not Spawn("npc "..name): that is a substring match,
-- and when the Flagellant dies he "ascends" into an Ascended Dark Flagellant, which kept the
-- north room "occupied" while the Echo sat idle and called in the wipe.
local function echo_mini_spawn(name)
    local hits = mq.getFilteredSpawns(function(s)
        return s.Type() == 'NPC' and s.CleanName() == name
    end)
    local s = hits[1]
    if s and s() then return s end
end

-- Adds: anything on our xtarget hate list that is not part of the encounter (the Echo,
-- a cycle ling, a mini) -- labyrinth mobs that wandered or were dragged in. A port with
-- those on aggro brings them along, so they die first: in a room before the mini, in the
-- middle before anyone leaves for a room.
ECHO.ling_names = { "grudgeling", "greedling", "spiteling", "rageling" }
local function echo_is_encounter(name)
    name = (name or ''):lower()
    if name:find('echo', 1, true) then return true end
    for _, n in ipairs(ECHO.ling_names) do
        if name:find(n, 1, true) then return true end
    end
    for _, n in pairs(ECHO.mini) do
        if name:find(n:lower(), 1, true) then return true end
    end
    return false
end

local function echo_adds()
    local out = {}
    for i = 1, 20 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = xt.ID() or 0
        if id ~= 0 and xt.TargetType() == 'Auto Hater' and xt.Type() == 'NPC' and xt.Master() == nil
                and not echo_is_encounter(xt.CleanName()) then
            out[#out + 1] = mq.TLO.Spawn(id)
        end
    end
    return out
end

-- MA: onto the nearest add unless already on one. True if there were adds.
ECHO.ADD_ENGAGE_MAX = 150
local function echo_ma_engage_add(adds)
    if #adds == 0 then return false end
    if not flags.MA_MODE then return true end
    local tid = mq.TLO.Target.ID()
    for _, s in ipairs(adds) do if s.ID() == tid then return true end end
    table.sort(adds, function(a, b) return (a.Distance() or 999) < (b.Distance() or 999) end)
    -- Only what is here with us: an add a summon left behind in a room is the room's to
    -- kill -- engaging it would send CWTN running out through the labyrinth after it.
    if (adds[1].Distance() or 999) > ECHO.ADD_ENGAGE_MAX then return true end
    Core.engage(adds[1].ID(), 0)
    return true
end

ECHO.SUMMON_JUMP = 100   -- units in one pulse (def.pulse); a Selo's run covers ~20
echo_st.summoned = false
local function echo_room(dir)
    local name = ECHO.mini[dir]
    local seen, fighting, held, t0 = false, false, false, mq.gettime()
    local adds_said = false
    local py, px = mq.TLO.Me.Y(), mq.TLO.Me.X()
    while not echo_st.abort do
        local mob = echo_mini_spawn(name)
        local adds = echo_adds()
        -- A summon is a jump no run can make in one pulse. Caught by the jump, not just by
        -- landing in the middle, so do_echo_room knows not to go back for the switch.
        local cy, cx = mq.TLO.Me.Y(), mq.TLO.Me.X()
        if cy and cx and py and px and math.sqrt((cy - py)^2 + (cx - px)^2) > ECHO.SUMMON_JUMP
           and not echo_st.summoned then
            echo_st.summoned = true
            announce_g('Echo: %s summoned out of the %s room', def.name, dir)
        end
        py, px = cy, cx
        -- The Echo can summon someone to the middle mid-room. In a Chase fight mode that
        -- toon then walks back through the labyrinth after the MA, pulling trash -- and if
        -- the MA is the one summoned, the whole room chases it out. Either way: Manual and
        -- stay put (attack is left alone, so the room keeps fighting its mini).
        if not held then
            local ma = mq.TLO.Group.MainAssist()
            local ma_spawn = ma and ma ~= def.name and mq.TLO.Spawn("pc ="..ma)
            local me_out = echo_st.summoned or dist2d(ECHO.center[1], ECHO.center[2]) < ECHO.CENTER_MAX
            local ma_out = fighting and ma_spawn and ma_spawn()
                and (ma_spawn.Distance() or 0) > ECHO.ROOM_MIN
            if me_out or ma_out then
                held = true
                if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
                cwtn("mode 0")
                if me_out then mq.cmd("/attack off") end
                announce_g('Echo: %s pulled to the middle during the %s room -- %s holding in Manual',
                    me_out and def.name or ma, dir, def.name)
            end
        end
        if mob then
            if not seen then
                seen = true
                -- The port can land well short of the mini (west especially). Close in
                -- inside the room -- melee range, or heal range for the Flagellant --
                -- but only once we are provably in this room and the mini is a short
                -- path away. Anything else would be a run across the zone to it.
                if (mob.Distance() or 0) > 20 then
                    local path = mq.TLO.Navigation.PathLength('id '..mob.ID())() or -1
                    if dist2d(ECHO.center[1], ECHO.center[2]) < ECHO.CENTER_MAX
                       or echo_nearest_room() ~= dir then
                        announce_g('Echo: not in the %s room -- not running to %s', dir, name)
                    elseif path < 0 or path > ECHO.MINI_NAV_MAX then
                        announce_g('Echo: %s is %s away by nav -- too far to be in this room, not running to it',
                            name, path < 0 and 'unreachable' or string.format('%.0f', path))
                    else
                        mq.cmdf("/nav id %d distance=%d log=off", mob.ID(), dir == 'north' and 50 or 15)
                        Core.wait_nav()
                    end
                end
                safe_target(mob.ID())   -- after the walk in: from the port it can be out of range
                mq.delay(200)
                mq.cmd("/face fast")
                if dir ~= 'north' then
                    mq.cmd("/attack on")
                elseif flags.HEAL_NORTH then
                    echo_heal_flagellant(mob)
                else
                    echo_ignore_flagellant(mob)
                end
                announce('Echo: %s room, on %s', dir, name)
            end
            -- North is normally a no-fight room; adds on aggro make it one
            if not fighting and not held and (dir ~= 'north' or #adds > 0) then
                local ma = mq.TLO.Group.MainAssist()
                local ma_spawn = ma and mq.TLO.Spawn("pc ="..ma)
                if ma == def.name or (ma_spawn and ma_spawn() and (ma_spawn.Distance() or 999) < 150) then
                    fighting = true
                    local key = echo_st.saved_mode and (echo_st.saved_mode:gsub(' ', ''))
                    local m = key and ECHO.room_mode[key]
                    -- The MA opens the fight: from the second room on its saved mode is the
                    -- Chase we put it in back in the middle, and in an assist mode nobody --
                    -- the MA included -- engages until the mini is under AutoAssistAt (seen
                    -- live 2026-11-01: Dark Stranger at 100% on a merc, the group idle).
                    if ma == def.name then m = 7 end
                    if m then cwtn(string.format("mode %d", m)) end
                    -- the mode change can drop the /attack on sent when the mini showed
                    if ma == def.name and dir ~= 'north' then
                        mq.delay(250)
                        mq.cmd("/attack on")
                    end
                end
            end
            -- Adds die before the mini: once it falls we port straight back (the Echo
            -- cannot be left idle), and anything still on aggro would come with us.
            if not held then
                if echo_ma_engage_add(adds) then
                    if not adds_said then
                        adds_said = true
                        debug_local('Echo: %d add(s) on aggro in the %s room -- killing them before %s',
                            #adds, dir, name)
                    end
                elseif adds_said then
                    adds_said = false
                    debug_local('Echo: adds clear, back on %s', name)
                    if flags.MA_MODE and dir ~= 'north' then Core.engage(mob.ID(), 0) end
                end
            end
        elseif seen then
            announce('Echo: %s room done', dir)
            break
        elseif (mq.gettime() - t0) > ECHO.MINI_WAIT * 1000 then
            announce_g('Echo: %s never showed in the %s room, moving on', name, dir)
            break
        end
        if (mq.gettime() - t0) > ECHO.MINI_MAX * 1000 then
            announce_g('Echo: %s room timed out, moving on', dir)
            break
        end
        mq.delay(def.pulse)
    end
    -- Flagellant gone: put back what Heal North off saved, or undo the heal-on setup
    if dir == 'north' and is_healer() and not echo_restore_xtargethealnpc() then
        cwtn("xtargethealnpc off nosave")
    end
end

-- The cycle's ling (grudgeling, greedling, spiteling, rageling), by name. Looked for as a
-- spawn rather than on xtarget: it pops with
-- the emote or just after and is not on anyone's xtarget until it aggros. Only counted
-- near the middle, so the same names left up elsewhere do not hold the room.
ECHO.LING_RADIUS = 250
local function echo_lings()
    return mq.getFilteredSpawns(function(s)
        if s.Type() ~= 'NPC' or s.Dead() then return false end
        local name = (s.CleanName() or ''):lower()
        -- a fresh corpse can still read Type NPC (seen: "MA engaging a spiteling's corpse")
        if name:find('corpse', 1, true) then return false end
        local found = false
        for _, n in ipairs(ECHO.ling_names) do
            if name:find(n, 1, true) then found = true break end
        end
        if not found then return false end
        local y, x = s.Y(), s.X()
        return y and x and math.sqrt((y - ECHO.center[1])^2 + (x - ECHO.center[2])^2) < ECHO.LING_RADIUS or false
    end)
end
local function echo_ling_count() return #echo_lings() end

-- MA only: the wait below holds Main, so pick_target never runs and the MA would sit on
-- the Echo while the ling lives. Put the MA on the nearest ling directly -- by spawn, not
-- xtarget, since the ling may not have aggroed yet. Everyone else Chases the MA onto it.
local function echo_ma_engage_ling()
    if not flags.MA_MODE then return end
    local lings = echo_lings()
    if #lings == 0 then return end
    for i = #lings, 1, -1 do
        if ignored_greedling(lings[i].CleanName()) then table.remove(lings, i) end
    end
    if ignored_greedling(mq.TLO.Target.Name()) then leave_greedling() end
    if #lings == 0 then return end   -- only a greedling left: wait for it to take its coin
    local tid = mq.TLO.Target.ID()
    for _, s in ipairs(lings) do
        if s.ID() == tid then return end   -- already on one
    end
    table.sort(lings, function(a, b) return (a.Distance() or 999) < (b.Distance() or 999) end)
    local ling = lings[1]
    debug_local('Echo: MA engaging %s', tostring(ling.CleanName()))
    Core.engage(ling.ID(), 0)
end

-- Each cycle brings one ling that has to die before anyone leaves for a mini. Stay in the
-- fight (current mode) until none is left near the middle. A grace first, since the ling
-- can pop a beat after the emote; capped so a stuck ling cannot cost the room.
ECHO.ADD_GRACE = 10    -- s to let the cycle's ling spawn
ECHO.ADD_MAX   = 120   -- s cap on waiting for a ling (also the phase 2 rageling)
local function echo_wait_lings()
    mq.delay(ECHO.ADD_GRACE * 1000, function() return echo_ling_count() > 0 end)
    if echo_ling_count() == 0 then return end
    debug_local('Echo: finishing %d ling(s) before the room', echo_ling_count())
    local t0 = mq.gettime()
    while echo_ling_count() > 0 and not echo_st.abort do
        if (mq.gettime() - t0) > ECHO.ADD_MAX * 1000 then
            announce_g('Echo: ling still up after %ds, going to the room anyway', ECHO.ADD_MAX)
            return
        end
        echo_ma_engage_ling()
        -- This wait holds Main, so its doevents never runs: let the greedling's
        -- hand-out emote through, or the coin-giver sits here until the cap.
        mq.doevents('greedling')
        mq.delay(def.pulse)
    end
end

-- Stay in the fight (whatever mode we are in now, never Manual) until no add is on
-- aggro. No cap: adds die before any port, and '/sorm echo stop' ends the hold. The MA
-- goes for the nearest; everyone else assists as usual. Used in the middle before leaving
-- for a room, and in a room before the switch back. A long hold in a room can leave the
-- Echo idle and fail the event; that is accepted -- porting with adds is worse.
ECHO.ADD_NAG = 60   -- s between reminders while held

-- We are in a room and the group MA is not: it has ported (or been summoned) back to the
-- middle. A dead or zoned MA does not count -- there is nothing to chase.
local function echo_ma_left_room()
    if flags.MA_MODE or echo_where() == 'center' then return false end
    local ma = mq.TLO.Group.MainAssist()
    if not ma or ma == def.name then return false end
    local s = mq.TLO.Spawn("pc ="..ma)
    if not s() then return false end
    local y, x = s.Y(), s.X()
    return y and x and math.sqrt((y - ECHO.center[1])^2 + (x - ECHO.center[2])^2) < ECHO.CENTER_MAX or false
end

local function echo_clear_adds(before)
    local adds = echo_adds()
    if #adds == 0 then return true end
    debug_local('Echo: %d labyrinth mob(s) on aggro -- killing them before %s', #adds, before)
    local nag = mq.gettime()
    local stranded = false
    while #adds > 0 do
        if echo_st.abort then return false end
        -- In a room, the MA has already ported back (an add on our xtarget it never had):
        -- the fight mode would Chase it home through the labyrinth (seen live 2026-11-02, a
        -- cleric "missed the crystal" and ran to the middle). Stay put anyway -- no port with
        -- mobs on aggro -- but in Manual, fighting whatever is nearest where we stand.
        if echo_ma_left_room() then
            if not stranded then
                stranded = true
                echo_manual()
                announce_g('Echo: %s left the room with %d mob(s) still on my aggro -- %s holding here in Manual',
                    tostring(mq.TLO.Group.MainAssist()), #adds, def.name)
            end
            table.sort(adds, function(a, b) return (a.Distance() or 999) < (b.Distance() or 999) end)
            if mq.TLO.Target.ID() ~= adds[1].ID() then safe_target(adds[1].ID()) end
            if not mq.TLO.Me.Combat() then mq.cmd("/attack on") end
        end
        if (mq.gettime() - nag) > ECHO.ADD_NAG * 1000 then
            nag = mq.gettime()
            announce_g('Echo: still %d labyrinth mob(s) on aggro, holding before %s', #adds, before)
        end
        echo_ma_engage_add(adds)
        mq.doevents('greedling')
        mq.delay(def.pulse)
        adds = echo_adds()
    end
    debug_local('Echo: adds clear, carrying on to %s', before)
    return true
end

-- Each toon counts rooms off its own emotes, so one that missed an emote (zoned in late)
-- runs a room behind for the rest of the event (seen live 2026-10-30: a toon tried north
-- while we did east, east while we did south). The MA's count is the truth: it pushes it
-- after every room, and on request from a toon that has just started sorm.
local function echo_sync()
    if not flags.MA_MODE then return end
    Core.bcge("%s echonext %s", def.cmd, ECHO.order[echo_st.next] or 'done')
end

-- ============================================================
-- Illusion for Echo of Hate: skeleton (Amulet of Necropotence) or djinn (Jann's Veil),
-- picked by flags.USE_SKEL. The Dark Stranger (south) kills anyone not of the group's most
-- common race, so the whole group wears the same one. Skipped entirely with Other
-- (flags.ILLUSION_OTHER), the default.
-- ============================================================

-- Retried at most every 6s so a toon that cannot take it does not spend the fight paused.
ECHO.illusions = {
    skel = { item = "Amulet of Necropotence", race = "Skeleton" },
    jann = { item = "Jann's Veil",            race = "Djinn" },
}
echo_st.illusion_retry_at = 0
local function wanted_illusion() return flags.USE_SKEL and ECHO.illusions.skel or ECHO.illusions.jann end

local function has_illusion()
    local race = mq.TLO.Me.Race()
    return race and race:find(wanted_illusion().race) ~= nil or false
end

-- Does the whole group carry the selected illusion's item? Every member (us too) answers
-- with plain commands, so no sorm is needed on them: "ECHOITEMS <name> <amulet 0/1>
-- <veil 0/1>". Run when Skeleton or Jann is picked in the UI and again at Start; anyone
-- missing it shows as a UI warning and refuses the start. Never switches the type itself.
-- Skipped with Other (flags.ILLUSION_OTHER), the default.
ECHO.POLL_WAIT = 8   -- s for the answers
echo_st.poll = {}
echo_st.illusion_missing = nil   -- who lacks the selected item, from the last check (UI)
echo_st.illusion_check_pending = false   -- set by the UI radio, run from Main (it blocks)
-- Only 0/1 answers count: our own outgoing command echoes the unexpanded ${...} text.
local function event_echo_items(line, name, skel, jann)
    if (skel ~= '0' and skel ~= '1') or (jann ~= '0' and jann ~= '1') or not name then return end
    echo_st.poll[name:lower()] = { skel = skel == '1', jann = jann == '1' }
end
-- auto: a check outside Start (UI pick, Echo task coming up) -- a failure is a warning,
-- not a refused start.
local function echo_illusion_check(auto)
    echo_st.illusion_missing = nil
    if flags.ILLUSION_OTHER then
        debug_local('Echo: illusion set to Other -- not checking items')
        return true
    end
    local ill = wanted_illusion()
    -- only toons on our DanNet/EQBC: anyone else (an outside player) cannot answer the
    -- poll, handles their own illusion, and does not fail the check
    local reach, members, outside = Core.reachable_names(), { def.name }, {}
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local n = mq.TLO.Group.Member(i).Name()
        if n and reach[n:lower()] then members[#members + 1] = n
        elseif n then outside[#outside + 1] = n end
    end
    if #outside > 0 then
        announce('Echo: not checking %s (not on %s) -- they handle their own illusion',
            table.concat(outside, ', '), flags.USE_EQBC and 'EQBC' or 'DanNet')
    end
    -- our own answer locally: our reply goes to the rest of the group, never back to us
    echo_st.poll = { [def.name:lower()] = {
        skel = mq.TLO.FindItem('=Amulet of Necropotence')() ~= nil,
        jann = mq.TLO.FindItem("=Jann's Veil")() ~= nil } }
    local q = "ECHOITEMS ${Me.CleanName} ${If[${FindItem[=Amulet of Necropotence].ID},1,0]} ${If[${FindItem[=Jann's Veil].ID},1,0]}"
    -- reply as an announce_g: an /echo on the rest of the group, not the whole network
    Core.bcg_np("/docommand %s/echo SOR-Missions [${Me.CleanName}]: %s", flags.USE_EQBC and '/bcg /' or '/dgge ', q)
    local t0 = mq.gettime()
    while (mq.gettime() - t0) < ECHO.POLL_WAIT * 1000 do
        mq.doevents('echoitems')
        local all = true
        for _, n in ipairs(members) do
            if not echo_st.poll[n:lower()] then all = false break end
        end
        if all then break end
        mq.delay(250)
    end
    local key = flags.USE_SKEL and 'skel' or 'jann'
    local no_reply, no_item = {}, {}
    for _, n in ipairs(members) do
        local r = echo_st.poll[n:lower()]
        if not r then no_reply[#no_reply + 1] = n
        elseif not r[key] then no_item[#no_item + 1] = n end
    end
    local why
    if #no_item > 0 then
        why = string.format('no %s: %s', ill.item, table.concat(no_item, ', '))
    elseif #no_reply > 0 then
        why = 'no item answer from ' .. table.concat(no_reply, ', ')
    end
    if why then
        echo_st.illusion_missing = why
        local head = auto and 'illusion check' or 'NOT starting'
        announce_g('\arEcho: %s -- %s. Pick the other item, or Other to handle the illusion yourselves.\ax', head, why)
        return false
    end
    announce('Echo: whole group has %s -- going %s', ill.item, ill.race)
    return true
end

-- CWTN's autoremoveillusion strips the illusion the moment it lands. relic-2 has to turn it
-- on (the Jann illusion blocks mounting) with nosave, so it lasts until the plugin reloads
-- and carries into the next Echo. Turn it off once per Echo run.
echo_st.illusion_kept = false
local function keep_illusion()
    if echo_st.illusion_kept then return end
    echo_st.illusion_kept = true
    if Core.isclass_plugin_loaded() then cwtn("autoremoveillusion off nosave") end
end

-- Set when the Echo dies, so check_illusion does not click the illusion straight back on
-- while we are still in the zone. Cleared on zoning.
echo_st.defeated = false

local function check_illusion()
    if State.current_task ~= "Echo of Hate" or echo_st.defeated or flags.ILLUSION_OTHER then return end
    keep_illusion()
    if has_illusion() then return end
    local now = mq.gettime()
    if now < echo_st.illusion_retry_at then return end
    echo_st.illusion_retry_at = now + 6000
    local ill = wanted_illusion()
    if not mq.TLO.FindItem('='..ill.item)() then
        announce_g('%s is missing -- cannot go %s', ill.item, ill.race)
        echo_st.illusion_retry_at = now + 60000
        return
    end
    announce('I need to be a %s, using %s', ill.race, ill.item)
    local xt_empty = true
    for i = 1, 20 do
        if (mq.TLO.Me.XTarget(i).ID() or 0) ~= 0 then xt_empty = false break end
    end
    if xt_empty and Core.isclass_plugin_loaded() then
        -- Out of combat: let CWTN strip whatever illusion we are wearing (1s), clear it by
        -- hand too, then turn autoremove back off so it does not strip the one we click
        cwtn("autoremoveillusion on nosave")
        mq.delay(1000)
        mq.cmd("/removebuff Illusion:")
        cwtn("autoremoveillusion off nosave")
    elseif mq.TLO.Me.Buff('Illusion: ')() then
        mq.cmd("/removebuff Illusion:")
    end
    Core.pause()
    mq.cmd("/stopcast")
    -- Bard: the plugin stops the current song a beat after "pause on", and a cast started
    -- before then dies with it (Jann's Veil has a cast time; the amulet is instant). Same
    -- 1s settle common.lua's cast() uses for bards.
    if def.class == 'BRD' then mq.delay(1000) end
    mq.cmdf("/useitem %s", ill.item)
    mq.delay(500)
    -- Jann's Veil has a cast time; wait it out before handing control back
    local t = mq.gettime()
    while mq.TLO.Window('CastingWindow').Open() and (mq.gettime() - t) < 10000 do mq.delay(250) end
    Core.resume()
end

-- "You have defeated Echo of Hate." Drop the illusion so it does not follow us into the
-- next mission or raid (the Jann illusion blocks mounting in relic-2).
local function event_echo_defeated()
    echo_st.defeated = true
    announce('Echo of Hate dead, Mission Complete!')
    mq.delay(500 + math.random(0,5000))
    announce('Echo of Hate defeated: removing the illusion')
    if mq.TLO.Me.Buff('Illusion: ')() then mq.cmd("/removebuff Illusion:") end
end

-- Main is blocked for the whole room run, so its per-pulse check_illusion does not run.
-- Forced re-check around south: two tries, skipping the 6s throttle.
local function echo_reillusion()
    if State.current_task ~= "Echo of Hate" or flags.ILLUSION_OTHER then return end
    for _ = 1, 2 do
        if has_illusion() then return end
        echo_st.illusion_retry_at = 0
        check_illusion()
        mq.delay(3000, has_illusion)
    end
    if not has_illusion() then
        announce_g('Echo: still %s, not a %s', tostring(mq.TLO.Me.Race()), wanted_illusion().race)
    end
end

-- MA only, before south. The Dark Stranger kills anyone not of the group's most common
-- race ("You are deemed worthless as you are not of the most common species"), so a single
-- illusioned toon in an un-illusioned group is the one who dies. Each toon illusions itself
-- only if its own sorm is running and current, so the MA checks every member's race
-- locally and sends the item click straight to anyone missing it, without needing their
-- sorm. Re-sent every 5s, capped at ECHO.ILLUSION_WAIT, then south goes ahead regardless.
ECHO.ILLUSION_WAIT = 15   -- s
-- Backstop for group members not on our DanNet/EQBC (outside players): we cannot poll or
-- click for them, so watch their spawn's race and warn in the UI if it is not the group's
-- illusion. Never fails a check. Refreshed from Main (echo_st.outside_warn).
echo_st.outside_warn = nil
local function echo_outside_check()
    echo_st.outside_warn = nil
    if State.current_task ~= "Echo of Hate" or flags.ILLUSION_OTHER then return end
    local want, reach, bad = wanted_illusion().race, Core.reachable_names(), {}
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        local name, race = m.Name(), m.Spawn.Race()
        if name and not reach[name:lower()] and not (race and race:find(want)) then
            bad[#bad + 1] = string.format('%s (%s)', name, tostring(race or 'not in zone'))
        end
    end
    if #bad > 0 then
        echo_st.outside_warn = string.format('not on our DanNet/EQBC and not %s: %s', want, table.concat(bad, ', '))
    end
end

-- Only toons we can reach: an outside player cannot be clicked for, so waiting on them
-- would just hold south for ECHO.ILLUSION_WAIT (echo_outside_check warns about them).
local function group_missing_illusion()
    local want, out, reach = wanted_illusion().race, {}, Core.reachable_names()
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        local name, race = m.Name(), m.Spawn.Race()
        if name and reach[name:lower()] and not (race and race:find(want)) then
            out[#out + 1] = { name = name, class = (m.Class.ShortName() or ''):lower() }
        end
    end
    return out
end

local function names(list)
    local t = {}
    for _, m in ipairs(list) do t[#t + 1] = m.name end
    return table.concat(t, ', ')
end

local function echo_group_illusion()
    if not flags.MA_MODE or State.current_task ~= "Echo of Hate" or flags.ILLUSION_OTHER then return end
    local ill = wanted_illusion()
    local t0, sent = mq.gettime(), nil   -- sent: last click, nil until the first
    local clicks = {}   -- name -> clicks sent; bards lock up on repeated item clicks
    while (mq.gettime() - t0) < ECHO.ILLUSION_WAIT * 1000 do
        local out = group_missing_illusion()
        if #out == 0 then return end
        if not sent or (mq.gettime() - sent) >= 5000 then
            announce_g('Echo: not %s before south: %s -- clicking %s', ill.race, names(out), ill.item)
            for _, m in ipairs(out) do
                clicks[m.name] = (clicks[m.name] or 0) + 1
                -- their CWTN would strip it again (see keep_illusion); a toon without the
                -- plugin just reports an unknown command
                if m.class ~= '' then Core.bct(m.name, "/%s autoremoveillusion off nosave", m.class) end
                if m.class == 'brd' and clicks[m.name] > 2 then
                    -- capped: leave it to them
                elseif m.class == 'brd' then
                    -- a playing song (or one the plugin restarts) kills the click's cast:
                    -- pause, let the song stop, click, then hand the bard back after the cast
                    Core.bct(m.name, "/brd pause on")
                    Core.bct(m.name, "/stopsong")
                    Core.bct(m.name, '/timed 10 /useitem "%s"', ill.item)
                    Core.bct(m.name, "/timed 35 /brd pause off")   -- click at 1s + 1.5s cast + 1s spare
                else
                    Core.bct(m.name, '/useitem "%s"', ill.item)
                end
            end
            sent = mq.gettime()
        end
        mq.delay(500)
    end
    local out = group_missing_illusion()
    if #out > 0 then
        announce_g('Echo: going south with %s still not %s', names(out), ill.race)
    end
end

-- One room, then back to the middle in Chase to fight the Echo.
-- The room is used up as soon as we set off, even if the port fails -- the encounter
-- moves on regardless, and the next emote belongs to the next room.
local function do_echo_room()
    local dir = ECHO.order[echo_st.next]
    if not dir then
        announce('Echo: all %d rooms done (%s echo reset to start over)', #ECHO.order, def.cmd)
        return
    end
    echo_st.next = echo_st.next + 1
    echo_st.saved_mode = nil
    echo_st.summoned = false
    echo_wait_lings()
    if echo_st.abort then return end
    if not echo_clear_adds('the ' .. dir .. ' room') then return end
    echo_manual()
    announce('Echo: heading to the %s room', dir)
    -- Sitting a room out in the middle: hold in Manual until the room is done. Chase now
    -- would follow the MA into the labyrinth on foot and drag its mobs back to the middle's
    -- door (seen live 2026-11-01, a toon whose port failed). Same done test as echo_room:
    -- the mini came and went.
    local function sit_out()
        echo_manual()
        local seen, t0 = false, mq.gettime()
        while not echo_st.abort and (mq.gettime() - t0) < ECHO.MINI_MAX * 1000 do
            local up = (mq.TLO.SpawnCount("npc "..ECHO.mini[dir])() or 0) > 0
            if up then seen = true
            elseif seen or (mq.gettime() - t0) > ECHO.MINI_WAIT * 1000 then break end
            mq.delay(def.pulse)
        end
    end
    -- The Dark Stranger banishes anyone not wearing the illusion, so make sure of it
    -- (clicking the item if needed) before transit, and sit south out without it.
    local skip = false
    if dir == 'south' and State.current_task == "Echo of Hate" then
        echo_reillusion()
        echo_group_illusion()
        if not has_illusion() then
            announce_g('Echo: not a %s (%s missing or blocked) -- staying in the middle for south',
                wanted_illusion().race, wanted_illusion().item)
            skip = true
            sit_out()
        end
    end
    if not skip and not echo_port(dir) then
        -- No port and still in the middle (the switch gone or locked): sit it out here
        if echo_where() == 'center' then
            announce_g('Echo: %s could not port to %s -- holding in the middle until it is done', def.name, dir)
            sit_out()
        end
    elseif not skip then
        echo_room(dir)
        -- Summoned to the middle after the mini: stop here, in Manual, before anything
        -- else -- the room's fight mode would chase its target back out to the room.
        if echo_st.summoned or echo_where() == 'center' then echo_manual() end
        if dir == 'south' then echo_reillusion() end
        -- Anything still on aggro dies here, in the room's fight mode, before the port.
        -- That can leave the Echo idle long enough to fail the event, but a reset is
        -- safer than porting back with adds that then path through the labyrinth after
        -- us (seen live 2026-10-30: 3 adds back from south became 7+ in the middle).
        if not echo_clear_adds('the switch back to the middle') then return end
    end
    echo_manual()
    -- Summoned out of the room: we are already with the Echo. Never go back for the
    -- room's switch (seen live 2026-11-02, a summoned tank ran back out to click it).
    local back
    if echo_st.summoned then
        announce_g('Echo: %s was summoned out of the %s room -- not going back for its switch', def.name, dir)
        back = true
    else
        back = echo_port('center')
    end
    if not back then
        -- Not back in the middle: Chase would walk the labyrinth, so stay in Manual -- but
        -- say so, a toon left silently in Manual sits out the rest of the fight
        announce_g('Echo: %s could not get back to the middle (%s) -- left in Manual, move me and set my mode',
            def.name, tostring(echo_where()))
    else
        Core.fight_mode()   -- the group Chases the MA onto the Echo
        -- After a quiet room (north, nobody fights) the Echo may be off the hate list, and
        -- pick_target only takes xtarget mobs, so the MA would wait for it to aggro on its
        -- own. Engage it by spawn instead.
        local e = echo_boss()
        if e and flags.MA_MODE then
            Core.engage(e.ID(), 0)
        elseif e and safe_target(e.ID()) then
            mq.delay(200)
            mq.cmd("/attack on")
        end
        announce('Echo: Back in Center. Fighting the Echo until the next emote.')
    end
    echo_sync()
end

local function run_echo_room()
    if flags.ECHO_RUNNING then return end
    flags.ECHO_RUNNING = true
    echo_st.abort = false
    local ok, err = pcall(do_echo_room)
    if not ok then
        announce_g('do_echo_room error: %s', tostring(err))
        if is_healer() and not echo_restore_xtargethealnpc() then cwtn("xtargethealnpc off nosave") end
        Core.set_mode(echo_st.saved_mode)
    end
    flags.ECHO_RUNNING = false
end

-- echo_power: "The Echo sends power away, off into the labyrinth"
local function event_echo_power()
    echo_st.pending = true
    announce('Echo sent power into the labyrinth: next room %s', tostring(ECHO.order[echo_st.next]))
end
-- ============================================================
-- Echo of Hate phase 2: below the labyrinth. Step off the Echo on landing, deal with a
-- rageling that ported down with us, take the fight to the NE corner, and burn at the
-- waxes (or on landing with P2_FULLBURN).
-- ============================================================

-- A rageling that came down to phase 2 with us. With enough DPS we overrun the phase 2
-- trip while the last add is still getting ready to go live, so it ports down too. It is
-- not on xtarget at first, can be attacked but undamageable, so it is found by spawn.
local function p2_rageling()
    local r = mq.TLO.NearestSpawn('npc rageling')
    if r() and not r.Dead() and (r.Z() or 0) < -500
            and not (r.CleanName() or ''):find('corpse', 1, true) then return r end
end

-- That rageling once it has gone live: it is on our xtarget as an auto hater. Until then
-- the MA holds the Echo so the tank keeps aggro on it.
local function p2_rageling_live()
    local r = p2_rageling()
    if not r then return nil end
    local id = r.ID()
    for i = 1, 20 do
        local xt = mq.TLO.Me.XTarget(i)
        if xt.ID() == id and xt.TargetType() == 'Auto Hater' then return r end
    end
end

-- Phase 2 sits far below the labyrinth (Z -1161 against -23). On the frame we land down
-- there, once per descent: Manual, run to the NE corner, then Chase.
ECHO.p2_corner = {182, -165, -1161}
-- The waxes (and with them the burn) start when the Echo reaches ECHO.BURN_PCT. While a
-- rageling that came down with us is still to be dealt with, DPS on the Echo stops
-- ECHO.HOLD_MARGIN above that, so the burn never starts before we are in the corner.
ECHO.BURN_PCT    = 75
ECHO.HOLD_MARGIN = 10
-- xtarget still shows a rageling that was live up top for a while after the port, then
-- drops it until it really goes live. Trust an xtarget entry once it has been off since
-- we landed, or after this many seconds if it never drops.
ECHO.P2_SETTLE = 10
ECHO.RAG_ARRIVE = 5   -- s to wait on landing for a rageling still up top to port down
ECHO.P2_STEP = 20     -- units the whole group steps south off the Echo on landing
ECHO.CORNER_SLACK = 10 -- within this of the NE corner counts as there: stop re-navving
echo_st.was_down = false
echo_st.burned = false

-- Phase 2 burn: burnnow on the first wax spawn of each trip down, twice 2s apart. Set off
-- by the wax-spawn emote (echo_wax) or, as a backstop if the emote text is off, by a boiling
-- wax showing up down here. The emote repeats as later waxes spawn; echo_st.burned holds
-- those off until we go back up.
local function echo_burn(why)
    if State.current_task ~= "Echo of Hate" or echo_st.burned or (mq.TLO.Me.Z() or 0) >= -500 then return end
    echo_st.burned = true
    announce('Echo: Burn started! (%s)', why)
    cwtn("burnnow")
    mq.delay(2000)
    cwtn("burnnow")
end

local function check_wax_burn()
    if echo_st.burned or State.current_task ~= "Echo of Hate" then return end
    local w = mq.TLO.NearestSpawn('npc boiling wax')
    if w() and (w.Z() or 0) < -500 then echo_burn('boiling wax up') end
end

-- The phase 2 setup below holds Main for a while (rageling, corner navs), and the waxes
-- can start in that time: catch them on every wait pulse, not after.
local function echo_p2_wait(ms)
    mq.doevents('echo_wax')
    check_wax_burn()
    mq.delay(ms)
end

local function check_echo_port_down()
    if State.current_task ~= "Echo of Hate" then return end
    local z = mq.TLO.Me.Z()
    local down = z ~= nil and z < -500
    -- re-arm the burn on the way back up, so a wax emote handled on the very pass we
    -- landed still counts as this trip's burn
    if not down and echo_st.was_down then echo_st.burned = false end
    if down and not echo_st.was_down then
        -- Full burn (crystals achievement): burn on landing instead of at the waxes. This
        -- trip's wax emote then finds echo_st.burned set and does not burn again.
        if flags.P2_FULLBURN then echo_burn('full phase 2 burn') end
        -- We all land stacked on top of the Echo: everyone, tank included, steps 20 south
        -- (-Y) off it. Paused so Chase does not pull us straight back mid-step; resume()
        -- re-camps a SicTank MA where it now stands.
        do
            local y, x, z = mq.TLO.Me.Y(), mq.TLO.Me.X(), mq.TLO.Me.Z()
            Core.pause()
            local ok, err = pcall(function()
                if nav_to_loc(y and y - ECHO.P2_STEP, x, z, 'distance=3 log=off') then Core.wait_nav() end
                local e = echo_boss()
                if e then mq.cmdf("/face fast id %d", e.ID()) end
            end)
            Core.resume()
            if not ok then announce_g('Echo: phase 2 step south error: %s', tostring(err)) end
        end
        -- A rageling that ported down with us is not live yet; the Echo goes live much
        -- sooner. Everyone assists the MA: first the Echo, down to ECHO.BURN_PCT +
        -- ECHO.HOLD_MARGIN, then the MA moves onto the rageling and the group waits on it
        -- there until it goes live and dies where it is, before anyone moves. If it goes
        -- live before the Echo is down to the hold, the MA switches to it then. Only the MA
        -- picks targets -- the rest follow it in their fight mode. Re-asserted every pulse:
        -- CWTN re-picks the Echo off xtarget (seen live 2026-10-30, 81% to 49% and an
        -- early burn). The MA targets here because this wait holds Main, and with it
        -- pick_target.
        -- Full burn: no stop for the rageling either. It comes with us to the NE corner
        -- and dies there with the Echo, picked off xtarget like any other add.
        -- A rageling can land a beat after us (seen: a toon found none on landing, went for
        -- the corner, and the rageling arrived behind -- Echo split between the two). If one
        -- is still up top, give it ECHO.RAG_ARRIVE to come down before deciding.
        local up_top = mq.TLO.NearestSpawn('npc rageling')
        if not flags.P2_FULLBURN and not p2_rageling() and up_top() and not up_top.Dead() then
            announce('Echo: a rageling is still up top, waiting up to %ds for it to come down', ECHO.RAG_ARRIVE)
            local t0 = mq.gettime()
            while not p2_rageling() and (mq.gettime() - t0) < ECHO.RAG_ARRIVE * 1000 do echo_p2_wait(250) end
        end
        if flags.P2_FULLBURN and p2_rageling() then
            announce('Echo: Full burn is set, taking the rageling to the NE corner')
        elseif p2_rageling() then
            debug_local('Echo: rageling came down with us, on the Echo to %d%% first',
                ECHO.BURN_PCT + ECHO.HOLD_MARGIN)
            Core.fight_mode()
            local t0 = mq.gettime()
            local seen_off = not p2_rageling_live()   -- on xtarget now = stale, from up top
            local holding, live_said = false, false
            local hold_pct = ECHO.BURN_PCT + ECHO.HOLD_MARGIN
            -- The Echo's HP reads stale (its phase-1 low) until the heal shows up: seen live
            -- 2026-10-30, every toon held at "14%". Arm the hold only once it reads above.
            local healed = false
            while p2_rageling() and (mq.gettime() - t0) < ECHO.ADD_MAX * 1000 do
                local rag = p2_rageling()
                local live = p2_rageling_live()
                if not live then seen_off = true end
                if live and not seen_off and (mq.gettime() - t0) < ECHO.P2_SETTLE * 1000 then live = nil end
                local e = echo_boss()
                if live and not live_said then
                    live_said = true
                    debug_local('Echo: rageling is live, killing it before the NE corner')
                end
                if e and (e.PctHPs() or 0) > hold_pct then healed = true end
                if not live and not holding and healed and e and (e.PctHPs() or 100) <= hold_pct then
                    holding = true
                    -- only the MA switches, so only the MA announces it
                    if flags.MA_MODE then
                        debug_local('Echo at %d%%: off it and onto the rageling', e.PctHPs() or 0)
                    end
                end
                -- The Echo first, to the hold -- unless the rageling goes live sooner: a live
                -- rageling always comes first
                if rag and (live or holding) then
                    if flags.MA_MODE and (State.assigned_target ~= rag.ID() or mq.TLO.Target.ID() ~= rag.ID()) then
                        Core.engage(rag.ID(), 0)
                    end
                elseif e and flags.MA_MODE
                        and (State.assigned_target ~= e.ID() or mq.TLO.Target.ID() ~= e.ID()) then
                    Core.engage(e.ID(), 0)
                end
                echo_p2_wait(def.pulse)
            end
            if p2_rageling() then
                announce_g('Echo: rageling still up after %ds, heading to the NE corner anyway', ECHO.ADD_MAX)
            end
        end
        announce('Echo: Phase 2 port down, heading to the NE corner')
        echo_manual()
        -- Sent once, then twice more at 4s intervals in case a nav drops or stops short.
        -- Backward so we keep facing the room on the way.
        local c = ECHO.p2_corner
        -- RGMercs keeps its own melee positioning in Boxr's Manual and pulled the tank back
        -- toward the Echo on every nav (the tank stopped ~67 short of the corner). Pause it
        -- outright for the walk; a class plugin's Manual already holds still.
        local rg = Core.rgmercs_lua()
        if rg then Core.pause() end
        local ok_corner, err_corner = pcall(function()
        for i = 1, 3 do
            if i > 1 then echo_p2_wait(4000) end
            -- Pull the pet off whatever it is on so it follows us to the corner
            if (mq.TLO.Me.Pet.ID() or 0) ~= 0 then mq.cmd("/pet back") end
            mq.cmd("/swarm leave")
            Core.remove_selos()
            if nav_to_loc(c[1], c[2], c[3], 'distance=5 facing=backward log=off') then
                Core.wait_nav()
                -- the 2nd/3rd nav could leave us facing away from the Echo
                local e = echo_boss()
                if e then mq.cmdf("/face fast id %d", e.ID()) end
                -- In the corner: fight as soon as the Echo has followed us in -- the
                -- retries are only for a nav that dropped or stopped short
                if Core.dist2d(c[1], c[2]) <= ECHO.CORNER_SLACK then
                    local t0 = mq.gettime()
                    while (mq.gettime() - t0) < 4000 do
                        e = echo_boss()
                        if not e or (e.Distance() or 999) <= (e.MaxRange() or 20) + 5 then break end
                        echo_p2_wait(250)
                    end
                    break
                end
            else
                announce_g('Echo: no nav path to the NE corner -- move me by hand')
                break
            end
        end
        end)
        if rg then Core.resume() end
        if not ok_corner then announce_g('Echo: NE corner move error: %s', tostring(err_corner)) end
        Core.fight_mode()
    end
    echo_st.was_down = down
end

-- echo_wax: "The Echo destroys the mystical candles and takes their magic to form its own creation"
local function event_wax_spawn() echo_burn('emote') end

-- ============================================================
-- Giving plat to an NPC (the Echo's greedlings), with every step checked so a split that
-- goes wrong can never hand over the whole stack.
-- ============================================================

-- Callback to determine if the Inventory window is open
---@return boolean
local function inventory_window()
	return mq.TLO.Window("InventoryWindow").Open()
end
-- Callback to determine if the Give window is open
---@return boolean
local function give_window()
	return mq.TLO.Window("GiveWnd").Open()
end
local function cursor_plat() return mq.TLO.Me.CursorPlatinum() or 0 end

-- Put any plat on the cursor back in the money slot. True once the cursor holds none.
local function return_cursor_plat()
    if cursor_plat() == 0 then return true end
    mq.TLO.Window("InventoryWindow").Child("IW_Money0").LeftMouseUp()
    mq.delay(1000, function() return cursor_plat() == 0 end)
    if cursor_plat() > 0 then mq.cmd("/autoinventory") mq.delay(500) end
    return cursor_plat() == 0
end

-- Adapted from Epic Laziness with a whole lot more guards after we overpaid a greedling by several million plat
-- Give exactly `qty` plat to the nearest live NPC matching `npc`. The amount is checked
-- at every step -- cursor before starting, cursor after the split, give window before
-- Give -- and any mismatch puts the plat back and aborts, so a split that goes wrong
-- (quantity window late, slider ignoring SetText) can never hand over the whole stack.
local function do_npc_give_money(qty, npc)
    local MAX_DISTANCE = 20
    local qw = mq.TLO.Window("QuantityWnd")
    local gw = mq.TLO.Window("GiveWnd")
    if mq.TLO.Cursor() or cursor_plat() > 0 then
        announce_g("\arSomething is already on the cursor. Not giving.")
        return false
    end
    local mob = mq.TLO.NearestSpawn('npc '..npc)
    if not mob() then
        announce_g("\arNo %s up to give to.", npc)
        return false
    end
    local id = mob.ID()
    if (mob.Distance() or 999) > MAX_DISTANCE then
        mq.cmdf("/nav id %s distance=10 log=off", id)
        mq.delay(500)
        while mq.TLO.Navigation.Active() do mq.delay(100) end
    end
    mob = mq.TLO.Spawn(id)
    if not mob() or (mob.Distance() or 999) > MAX_DISTANCE then
        announce_g("\ar%s \aois over %s units away.", npc, MAX_DISTANCE)
        return false
    end
    mob.DoTarget()
    mq.delay(1000, function() return mq.TLO.Target.ID() == id end)
    if mq.TLO.Target.ID() ~= id then
        announce_g("\arCould not target %s.", npc)
        return false
    end

    local plat_before = mq.TLO.Me.Platinum() or 0
    if plat_before < qty then
        announce_g("\arOnly %spp, need %spp.", plat_before, qty)
        return false
    end
    if not mq.TLO.Window("InventoryWindow").Open() then
        mq.TLO.Window("InventoryWindow").DoOpen()
    end
    mq.delay("5s", inventory_window)
    mq.TLO.Window("InventoryWindow").Child("IW_Money0").LeftMouseUp()
    mq.delay(2000, function() return qw.Open() end)
    if not qw.Open() then
        announce_g("\arQuantity window did not open. Aborting.")
        return_cursor_plat()
        return false
    end
    qw.Child("QTYW_SliderInput").SetText(tostring(qty))
    mq.delay(200)
    qw.Child("QTYW_Accept_Button").LeftMouseUp()
    mq.delay(1000, function() return cursor_plat() > 0 end)
    if cursor_plat() ~= qty then
        announce_g("\arCursor holds %spp, not %spp. Putting it back.", cursor_plat(), qty)
        return_cursor_plat()
        return false
    end

    mq.TLO.Target.LeftClick()
    mq.delay(3000, give_window)
    if not gw.Open() then
        announce_g("\arGive window did not open. Putting the plat back.")
        return_cursor_plat()
        return false
    end
    if tonumber(gw.Child('GVW_MyMoney0').Text()) ~= qty then
        announce_g("\arINCORRECT AMOUNT IN GIVE WINDOW (%s). ABORTING.", tostring(gw.Child('GVW_MyMoney0').Text()))
        gw.Child("GVW_Cancel_Button").LeftMouseUp()
        mq.delay(500)
        return_cursor_plat()
        return false
    end
    for _ = 1, 10 do
        gw.Child("GVW_Give_Button").LeftMouseUp()
        mq.delay(500)
        if not gw.Open() then break end
    end
    if gw.Open() then
        announce_g("\arGive window would not close. Cancelling.")
        gw.Child("GVW_Cancel_Button").LeftMouseUp()
        mq.delay(500)
        return_cursor_plat()
        return false
    end
    mq.TLO.Window("InventoryWindow").DoClose()
    local spent = plat_before - (mq.TLO.Me.Platinum() or 0)
    debug_local("\aoGave \ag%s \aoplatinum to \ag%s\ao.", spent, npc)
    if spent ~= qty then announce_g('Greedling: expected to give %spp, plat went down by %s', qty, spent) end
    return true
end

---@param qty number @The amount of money to give
---@param npc string @The name of the NPC to give money to
local function npc_give_money(qty, npc)
    if qty == nil or npc == nil then
        announce_g("\arnpc_give_money missing parameters. qty: %s, npc: %s", tostring(qty), tostring(npc))
        return false
    end
    debug_local("\aoGiving \ag%s\ao platinum to \ag%s\ao.", qty, npc)
    Core.pause()
    local ok, res = pcall(do_npc_give_money, qty, npc)
    if not ok then
        announce_g('npc_give_money error: %s', tostring(res))
        pcall(return_cursor_plat)
        res = false
    end
    Core.resume()
    return res
end

-- greedling event: "A greedling stops and sniffs the air, holding its hand out"
local function trigger_greedling()
    if not flags.GREEDLING_GIVE_PLAT then return end
    debug_local('Greedling trigger called')
    npc_give_money(5,'greedling')
end

-- ============================================================
-- Mission hooks (see init.lua)
-- ============================================================

function E.events()
    mq.event('echo_power', '#*#The Echo sends power away, off into the labyrinth#*#', event_echo_power)
    mq.event('greedling', '#*#A greedling stops and sniffs the air, holding its hand out#*#', trigger_greedling)
    mq.event('echo_wax', '#*#The Echo destroys the mystical candles and takes their magic to form its own creation#*#', event_wax_spawn)
    mq.event('echo_defeated', '#*#You have defeated Echo of Hate.#*#', event_echo_defeated)
    mq.event('echoitems', '#*#ECHOITEMS #1# #2# #3#', event_echo_items)
end

-- Echo task just came up: the group MA checks the selected illusion item (a no-op on
-- Other) so a warning shows before anyone presses Start. Never changes the type.
function E.enter()
    if mq.TLO.Group.MainAssist() == def.name then echo_illusion_check(true) end
end

-- Not the MA (true on our first pulse): ask the MA where the rooms are, in case we
-- started mid-event. The MA never pushes on its own start -- a restarted MA has lost its
-- count and would drag everyone back to north.
function E.ma_changed(is_ma)
    local ma = mq.TLO.Group.MainAssist()
    if not is_ma and ma then Core.bct(ma, "%s echosync", def.cmd) end
end

-- A hater 300+ out is in another part of the labyrinth (a room's mini from the middle,
-- ~490 off). Chasing it walks the labyrinth -- seen live 2026-11-01, the MA stranded in
-- the middle by a failed port ran for the Dark Maniac. An ignored greedling is left too.
function E.skip(spawn)
    return ignored_greedling(spawn.Name()) or (spawn.Distance() or 0) > 300
end

-- Phase 2 (ported down below the labyrinth): a rageling that came down with us first
-- once it goes live, then the Echo and nothing else. On a full burn the Echo only: the
-- rageling rides along on the tank and dies to splash or after.
-- Up top: already on a greedling we are meant to leave alone (CWTN picked it, or the flag
-- was turned off mid-fight): get off it, even if there is nothing else to switch to.
function E.pick()
    if (mq.TLO.Me.Z() or 0) < -500 then
        local rag = not flags.P2_FULLBURN and p2_rageling_live()
        if rag then
            if State.assigned_target ~= rag.ID() or mq.TLO.Target.ID() ~= rag.ID() then
                Core.engage(rag.ID(), 0)
            end
            return true
        end
        local echo = echo_boss()
        if echo and (State.assigned_target ~= echo.ID() or mq.TLO.Target.ID() ~= echo.ID()) then
            Core.engage(echo.ID(), 0)
        end
        return true
    end
    if ignored_greedling(mq.TLO.Target.Name()) then leave_greedling() end
    return false
end

function E.pulse()
    -- Skeleton / Jann picked in the UI: check the group carries it (blocks, so not in the UI)
    if echo_st.illusion_check_pending then
        echo_illusion_check(true)
        echo_st.illusion_check_pending = false
    end
    check_illusion()
    echo_outside_check()
    check_echo_port_down()
    check_wax_burn()
    if echo_st.pending then
        echo_st.pending = false
        run_echo_room()
    end
end

function E.reset()
    echo_st.next = 1   -- new instance, start the rooms over
    echo_st.illusion_kept = false   -- re-send autoremoveillusion off (a relic run may have turned it on)
    echo_st.defeated = false
    echo_st.burned = false          -- a new run's first trip down burns again
end

function E.can_start() return echo_illusion_check() end

function E.start()
    -- Only ever to the Echo, inside: a failed /target echo left Kerina targeted outside
    -- and the start said withstand to her (user report)
    if not Core.in_instance_zone() then
        announce_g('Start: not inside the Echo mission (%s) -- not saying withstand', tostring(mq.TLO.Zone.ShortName()))
        return
    end
    local e = mq.TLO.Spawn("npc an echo")
    if not e() or e.Dead() then
        announce_g('Start: no Echo found -- start it by hand')
        return
    end
    mq.cmdf("/nav id %d distance=15 log=off", e.ID())
    mq.delay(500)
    while mq.TLO.Navigation.Active() do mq.delay(250) end
    mq.delay(500)
    safe_target(e.ID())
    mq.delay(500)
    if mq.TLO.Target.ID() ~= e.ID() then
        announce_g('Start: could not target the Echo (on %s) -- start it by hand', tostring(mq.TLO.Target.CleanName()))
        return
    end
    mq.cmd("/say withstand")
    announce('Start: Echo of Hate started')
end

local FULL_DIR = { n='north', e='east', s='south', w='west' }

E.commands = {
    greedling = function(value)
        flags.GREEDLING_GIVE_PLAT = Core.bool_arg(value, flags.GREEDLING_GIVE_PLAT)
        printf('GREEDLING_GIVE_PLAT set to %s',tostring(flags.GREEDLING_GIVE_PLAT))
    end,
    killgreedling = function(value)
        flags.KILL_GREEDLING = Core.bool_arg(value, flags.KILL_GREEDLING)
        printf('KILL_GREEDLING set to %s (%s)',tostring(flags.KILL_GREEDLING),
            flags.KILL_GREEDLING and 'MA kills it' or 'MA ignores it')
    end,
    -- The UI's Give Now goes through here: npc_give_money blocks on nav and window
    -- waits, which an ImGui callback cannot do. Not gated on GREEDLING_GIVE_PLAT.
    givenow = function() npc_give_money(5, 'greedling') end,
    echo = function(value)
        if value == 'stop' then
            echo_st.abort = true
            printf('Echo rooms: stopping')
        elseif value == 'reset' then
            echo_st.next = 1
            printf('Echo rooms: next is %s', ECHO.order[1])
        else
            echo_st.pending = true
        end
    end,
    healnorth = function(value)
        flags.HEAL_NORTH = Core.bool_arg(value, flags.HEAL_NORTH)
        printf('HEAL_NORTH set to %s',tostring(flags.HEAL_NORTH))
    end,
    p2burn = function(value)
        flags.P2_FULLBURN = Core.bool_arg(value, flags.P2_FULLBURN)
        printf('P2_FULLBURN set to %s',tostring(flags.P2_FULLBURN))
    end,
    illusion = function(value)
        if value == 'skel' or value == 'jann' then
            flags.USE_SKEL = value == 'skel'
            flags.ILLUSION_OTHER = false
            echo_st.illusion_retry_at = 0   -- apply the swap on the next pulse, not after the throttle
            echo_st.illusion_missing = nil   -- that check was for the other item
            printf('Echo illusion: %s (%s)', flags.USE_SKEL and 'skeleton' or 'Jann', wanted_illusion().item)
        elseif value == 'other' then
            flags.ILLUSION_OTHER = true
            echo_st.illusion_missing = nil
            printf('Echo illusion: Other (handled by the players, not sorm)')
        else
            printf('usage: %s illusion skel|jann|other', def.cmd)
        end
    end,
    echoorder = function(value)
        if not value then return end
        local order = {}
        for d in value:lower():gmatch('%a+') do
            d = FULL_DIR[d] or d
            if ECHO.mini[d] then table.insert(order, d) end
        end
        if #order > 0 then ECHO.order = order; echo_st.next = 1 end
        printf('Echo order: %s', table.concat(ECHO.order, ', '))
    end,
    -- Set the next room by name ('done' = all rooms used). Sent by the MA's echo_sync.
    echonext = function(value)
        if not value then return end
        local want = FULL_DIR[value:lower()] or value:lower()
        local idx = (want == 'done') and (#ECHO.order + 1) or nil
        for i, dir in ipairs(ECHO.order) do
            if dir == want then idx = i end
        end
        if idx then
            if idx ~= echo_st.next then
                debug_local('Echo: next room %s -> %s (synced)', tostring(ECHO.order[echo_st.next] or 'done'), want)
            end
            echo_st.next = idx
        else
            printf('Echo: %s is not in the room order (%s)', want, table.concat(ECHO.order, ', '))
        end
    end,
    -- On the MA: push our room count to the group. Anywhere else it does nothing.
    echosync = function() echo_sync() end,
}

function E.usage(c)
    print('  Echo of Hate:')
    printf('  %s echo [stop|reset]        --> run the next mini room now, stop it, or start over', c)
    printf('  %s echoorder n,e,s,w        --> set the mini room order (now %s)', c, table.concat(ECHO.order, ','))
    printf('  %s echonext n|e|s|w|done    --> set this toon\'s next room (the MA syncs it)', c)
    printf('  %s echosync                 --> on the MA: push its next room to the group', c)
    printf('  %s healnorth [on|off]       --> healing the Flagellant (off for achievement); this toon only,', c)
    print('                                  the UI button sets the whole group')
    printf('  %s p2burn [on|off]          --> burn the Echo from the start of phase 2, no hold (crystals);', c)
    print('                                  this toon only, the UI button sets the whole group')
    printf('  %s illusion skel|jann|other --> Echo illusion item; other = players handle it, no checks or clicks', c)
    printf('  %s greedling [on|off]       --> giving 5pp to greedlings', c)
    printf('  %s givenow                  --> give 5pp to the nearest greedling now', c)
    printf('  %s killgreedling [on|off]   --> MA kills greedlings (off = ignore, wait for it to leave)', c)
    printf('  Now: illusion %s, heal north %s, p2 full burn %s, greedling %s',
        flags.ILLUSION_OTHER and 'other' or (flags.USE_SKEL and 'skeleton' or 'Jann'),
        tostring(flags.HEAL_NORTH), tostring(flags.P2_FULLBURN), tostring(flags.GREEDLING_GIVE_PLAT))
end

function E.ui()
    local COLOR = Core.COLOR
    ImGui.Text('Illusion:')
    ImGui.SameLine()
    -- each choice goes to the whole group, so every toon's sorm agrees; picking an item
    -- also checks (here, from Main) that the whole group carries it
    local other = flags.ILLUSION_OTHER
    if ImGui.RadioButton('Other##ill', other) and not other then
        Core.bcg("%s illusion other", def.cmd)
    end
    ImGui.SameLine()
    if ImGui.RadioButton('Skeleton##ill', flags.USE_SKEL and not other) and not (flags.USE_SKEL and not other) then
        Core.bcg("%s illusion skel", def.cmd)
        -- set here too: our own copy of the broadcast can land after Main runs the check
        flags.USE_SKEL, flags.ILLUSION_OTHER = true, false
        echo_st.illusion_check_pending = true
    end
    ImGui.SameLine()
    if ImGui.RadioButton('Jann##ill', not flags.USE_SKEL and not other) and (flags.USE_SKEL or other) then
        Core.bcg("%s illusion jann", def.cmd)
        flags.USE_SKEL, flags.ILLUSION_OTHER = false, false
        echo_st.illusion_check_pending = true
    end
    ImGui.SameLine()
    if other then ImGui.TextColored(COLOR.GREY, '[DISABLED]')
    elseif has_illusion() then ImGui.TextColored(COLOR.GREEN, '[UP]') else ImGui.TextColored(COLOR.RED, '[DOWN]') end
    if other then
        ImGui.TextColored(COLOR.RED, 'WARNING: Other means manually illusioned.  You must handle your own.')
    elseif echo_st.illusion_check_pending then
        ImGui.TextColored(COLOR.AMBER, 'Checking the group for '..wanted_illusion().item..'...')
    elseif echo_st.illusion_missing then
        ImGui.TextColored(COLOR.RED, 'WARNING: '..echo_st.illusion_missing)
    end
    if not other and echo_st.outside_warn then
        ImGui.TextColored(COLOR.RED, 'WARNING: '..echo_st.outside_warn)
    end

    Core.status_flag('Greedling Give Plat:', flags.GREEDLING_GIVE_PLAT)
    ImGui.SameLine()
    flags.GREEDLING_GIVE_PLAT = Core.toggle_button('greed', flags.GREEDLING_GIVE_PLAT)
    ImGui.SameLine()
    if ImGui.Button('Give Now##greed') then mq.cmdf("%s givenow", def.cmd) end

    ImGui.Text('Greedling (MA):')
    ImGui.SameLine()
    if flags.KILL_GREEDLING then ImGui.TextColored(COLOR.GREEN, '[KILL]') else ImGui.TextColored(COLOR.AMBER, '[IGNORE]') end
    ImGui.SameLine()
    flags.KILL_GREEDLING = Core.toggle_button('killgreed', flags.KILL_GREEDLING, 'Kill', 'Ignore')
    if not flags.KILL_GREEDLING then
        ImGui.TextColored(COLOR.RED, 'WARNING:  You must pick a toon and assign them to\n give plat or manually give if you have this set.')
    end
    -- Group-wide: each healer acts on its own copy of this flag, so it has to be off on
    -- all of them, not just the toon clicked
    Core.status_flag('Heal North (group):', flags.HEAL_NORTH)
    ImGui.SameLine()
    if ImGui.Button((flags.HEAL_NORTH and 'Disable' or 'Enable')..'###north') then
        Core.bcg("%s healnorth %s", def.cmd, flags.HEAL_NORTH and 'off' or 'on')
    end
    -- Group-wide too: the hold runs on every toon
    Core.status_flag('P2 Full Burn (group):', flags.P2_FULLBURN)
    ImGui.SameLine()
    if ImGui.Button((flags.P2_FULLBURN and 'Disable' or 'Enable')..'###p2burn') then
        Core.bcg("%s p2burn %s", def.cmd, flags.P2_FULLBURN and 'off' or 'on')
    end

    ImGui.Separator()
    ImGui.Text('Rooms:')
    for i, dir in ipairs(ECHO.order) do
        ImGui.SameLine()
        if i < echo_st.next then ImGui.TextDisabled(dir)
        elseif i == echo_st.next then ImGui.TextColored(COLOR.AMBER, '['..dir..']')
        else ImGui.Text(dir) end
    end
    if echo_st.next > #ECHO.order then
        ImGui.SameLine()
        ImGui.TextColored(COLOR.GREEN, '(all done)')
    end
    if flags.ECHO_RUNNING then
        ImGui.TextColored(COLOR.AMBER, 'Room run in progress')
        ImGui.SameLine()
    end
    if ImGui.Button('Run Next Room') then echo_st.pending = true end
    ImGui.SameLine()
    if ImGui.Button('Stop##echo') then echo_st.abort = true end
    ImGui.SameLine()
    if ImGui.Button('Reset##echo') then echo_st.next = 1 end
    if flags.MA_MODE then
        ImGui.SameLine()
        if ImGui.Button('Sync Group##echo') then echo_sync() end
    end
end

return E
