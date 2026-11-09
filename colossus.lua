-- Colossus of Skylance: worker auras, the Colossus' armor drags, and the AE feign.
local mq = require("mq")
local Core = require((...):match('^(.*)%.[^.]+$'))   -- the core: this module's parent

local CO = {}
CO.TASK  = "Colossus"
CO.giver = 'Black Jay'

local def, flags, State = Core.def, Core.flags, Core.state
local announce, announce_g, debug_local = Core.announce, Core.announce_g, Core.debug_local
local safe_target, dist2d, tow_nav_opts = Core.safe_target, Core.dist2d, Core.tow_nav_opts
local cwtn, nav_to_loc = Core.cwtn, Core.nav_to_loc

Core.kill_order[CO.TASK] = {"a_runic_worker","a_stony_worker","a_bedeviled_scrykin","a_crazed_scrykin","The_Colossus_of_Skylance"}
Core.BURN.boss[CO.TASK]    = 'Colossus of Skylance'
Core.BURN.trigger[CO.TASK] = {}   -- keyed to the first HP-add emote only (BURN.emote)
-- first HP-based add wave; repeats per wave, burn_st.active holds off the repeats
Core.BURN.emote[CO.TASK]   = '#*#Skittering and odd crooning sounds can be heard even before the creatures making them teleport into the area#*#'

-- col_stomp: "The Colossus scuffs the ground with one foot" -- an AE feign; stand back up
local function col_ae_feign()
    local start_time = mq.gettime()
    announce('AEFD in 10s, autostand set')
    while mq.gettime() - start_time < 10000 do mq.delay(500) end
    mq.delay(750)
    debug_local('AEFD, standing')
    mq.cmd("/stand")
end

-- Colossus workers. Each worker is killed standing in its own aura: the runic worker in
-- the Runic_Runaway, the stony worker in the Stony_Storm. The auras wander (~28.6/s) and
-- cannot be targeted. Both workers aggro on Torm's "now". With DO_AURAS on, the MA
-- goes to the NEAREST aura whose worker is on xtarget, stays on it (nav aimed AURA.LEAD s
-- ahead, re-aimed every pulse), and kills that worker as it arrives; then the other.
-- Manual for the whole run (attack stays on), then back to the saved mode.
-- buffs: the worker's armor (names per arc-2's mission table). Once it drops the aura has
-- done its job, so we stop chasing it and kill the worker where it stands.
local AURA = {}
AURA.workers = {
    { worker = 'runic worker', aura = 'Runic_Runaway', buffs = {'Rune Armor', 'Runic Armor'} },
    { worker = 'stony worker', aura = 'Stony_Storm',   buffs = {'Stone Armor', 'Stony Armor', 'Illusion: Skeleton'} },
}
AURA.LEAD, AURA.MAX = 1, 180   -- s ahead to aim; s cap on one worker
-- stripped: worker IDs whose armor is gone -- never chase their aura again.
-- did_workers, went_colossus: set once we have worked a worker, and once we have walked
-- to the Colossus after them. The walk can't hang off the end of the worker run any more:
-- a stripped worker is let go alive, so the run ends before either worker dies.
local aura_st = { stripped = {}, did_workers = false, went_colossus = false }

-- The worker's ID if it is on our xtarget (aggroed), else nil
local function worker_hater(pair)
    for i = 1, 20 do
        local xt = mq.TLO.Me.XTarget(i)
        if (xt.CleanName() or ''):lower():find(pair.worker, 1, true) then return xt.ID() end
    end
end

-- Nearest aura (to us) whose worker is aggroed: pair, worker ID
local function next_worker()
    local best, best_id, best_d
    for _, p in ipairs(AURA.workers) do
        local wid = worker_hater(p)
        local a = mq.TLO.Spawn(p.aura)
        if wid and not aura_st.stripped[wid] and a() then
            local d = dist2d(a.Y(), a.X())
            if not best_d or d < best_d then best, best_id, best_d = p, wid, d end
        end
    end
    return best, best_id
end

-- Stay on an aura, fighting `tid`, while needed() holds (capped at `cap` s). Only moves
-- once the MOB is more than AURA.SLACK from the aura's center -- re-aiming every pulse at
-- a wandering aura had us constantly on the move -- and then aims AURA.LEAD s ahead of it.
-- The mob, not us: it is the one that has to be in the aura, and the Colossus is huge.
-- Falls back to our own position if the mob cannot be read.
AURA.SLACK = 50
AURA.FETCH = 25   -- mob on someone else and further than this: go get it
AURA.NAV_DIST = 5 -- nav stop distance on aura re-aims
AURA.REACH_SLACK = 5 -- stand (mob MaxRange - this) past the aura, so the mob stops on it

-- The mob is targeting someone other than us: another PC, or someone's pet (a worker
-- stuck on a pet never comes to the aura). Our own pet does not count.
local function mob_on_other(tid)
    if mq.TLO.Target.ID() ~= tid then return false end
    local id = mq.TLO.Me.TargetOfTarget.ID()
    if not id or id == 0 or id == mq.TLO.Me.ID() then return false end
    return id ~= (mq.TLO.Me.Pet.ID() or 0)
end

-- AURA.ENGAGE_WAIT: on it and swinging first, so it is on us before we start leading it
AURA.ENGAGE_WAIT = 1.5   -- s
local function do_aura_follow(aura_name, tid, needed, cap)
    -- A mob on a pet stays on the pet and never follows us to the aura (seen live
    -- 2026-11-06, the workers): pets off before we start leading it.
    Core.bcg("/pet back off")
    Core.bcg("/swarm leave")
    if mq.TLO.Target.ID() ~= tid then safe_target(tid) end
    mq.cmd("/attack on")
    mq.delay(AURA.ENGAGE_WAIT * 1000)
    local t0, py, px, pt = mq.gettime()
    local fetching = false
    while (mq.gettime() - t0) < cap * 1000 and needed() do
        local a = mq.TLO.Spawn(aura_name)
        if not a() then announce_g('Aura: no %s up', aura_name) break end
        local y, x, now = a.Y(), a.X(), mq.gettime()
        local off = dist2d(y, x)
        local mob = mq.TLO.Spawn(tid)
        if mob() and mob.Y() and mob.X() then
            off = math.sqrt((mob.Y() - y)^2 + (mob.X() - x)^2)
        end
        -- Waiting in the aura is pointless if the mob is beating on someone else: it never
        -- comes. Run to it and get its attention back, then the next pulses lead it in.
        if mob() and mob_on_other(tid) and (mob.Distance() or 0) > AURA.FETCH then
            if not fetching then
                announce('Aura: %s is on %s, going to get it', mob.CleanName(),
                    tostring(mq.TLO.Me.TargetOfTarget.CleanName()))
                fetching = true
                -- A pet or swarm pet that keeps hitting it would just take it back. Everyone
                -- targets it first, then backs the pets off it.
                safe_target(tid)
                Core.bcge_np(Core.TARGET_IF_NEAR, tid, def.TARGET_RANGE, tid)
                Core.bcg("/pet back")
                Core.bcg("/swarm leave")
                -- and the group off it: come to us, so it is the tank it turns to
                Core.bcge("/nav spawn pc %s", def.name)
            end
            if not mq.TLO.Navigation.Active() then
                mq.cmdf("/nav id %d distance=%d log=off", tid, AURA.FETCH - 10)
            end
            if mq.TLO.Me.AbilityReady('Taunt')() then mq.cmd("/doability taunt") end
        elseif fetching then
            fetching = false
            if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
        elseif off > AURA.SLACK then
            local ty, tx = y, x
            if py and now > pt then   -- lead the aura along its current heading
                ty = y + (y - py) / (now - pt) * AURA.LEAD * 1000   -- units/ms over LEAD s
                tx = x + (x - px) / (now - pt) * AURA.LEAD * 1000
            end
            -- Stand one reach past the aura, on the far side from the mob, so it stops IN
            -- the aura: the Colossus hits from ~35 and halted that far short of us -- 26s in
            -- Manual with him never reaching it. Small for the workers.
            if mob() and mob.Y() and mob.X() then
                local reach = math.max(0, (mob.MaxRange() or 0) - AURA.REACH_SLACK)
                local dy, dx = ty - mob.Y(), tx - mob.X()
                local d = math.sqrt(dy * dy + dx * dx)
                if reach > 0 and d > 0 then ty, tx = ty + reach * dy / d, tx + reach * dx / d end
            end
            -- distance=: without it nav goes for the exact point, overshoots and turns back,
            -- and every re-aim can flip our facing again
            local opts = string.format('%s distance=%d', tow_nav_opts(), AURA.NAV_DIST)
            if not nav_to_loc(ty, tx, mq.TLO.Me.Z(), opts) then
                mq.cmdf("/nav id %d %s", a.ID(), opts)
            end
        elseif mq.TLO.Navigation.Active() then
            mq.cmd("/nav stop")
        end
        py, px, pt = y, x, now
        if mq.TLO.Target.ID() ~= tid then safe_target(tid) end
        if not mq.TLO.Me.Combat() then mq.cmd("/attack on") end
        mq.delay(def.pulse)
    end
    if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
    -- a backward tow can stop with our back to the mob
    if mq.TLO.Spawn(tid)() then mq.cmdf("/face fast id %d", tid) end
end

-- True once the worker is our target, its buffs have loaded, and none of its armor is on.
-- Unloaded buffs read as "no armor", so wait for BuffsPopulated before believing that.
local function worker_stripped(pair, wid)
    if mq.TLO.Target.ID() ~= wid or not mq.TLO.Target.BuffsPopulated() then return false end
    for _, b in ipairs(pair.buffs) do
        if mq.TLO.Target.Buff(b)() then return false end
    end
    return true
end

local function do_aura_station(pair, wid)
    do_aura_follow(pair.aura, wid, function()
        local w = mq.TLO.Spawn(wid)
        if not w() or w.Dead() then return false end
        if worker_stripped(pair, wid) then
            aura_st.stripped[wid] = true
            return false
        end
        return true
    end, AURA.MAX)
    announce('Aura: done with the %s (%s)', pair.worker, aura_st.stripped[wid] and 'armor stripped' or 'dead')
end

-- The Colossus takes the same armor as its workers, and the same aura strips it: Rune
-- Armor in the Runic_Runaway, Stone Armor in the Stony_Storm (names per arc-2's mission
-- table). With either up while we are on it, drag it there until the armor drops.
AURA.COLOSSUS = 'The Colossus of Skylance'
AURA.armor = {
    { buff = 'Rune Armor',  aura = 'Runic_Runaway' },
    { buff = 'Stone Armor', aura = 'Stony_Storm' },
}
AURA.DRAG_MAX = 60

local function colossus_armor_up()
    if mq.TLO.Target.CleanName() ~= AURA.COLOSSUS then return end
    for _, c in ipairs(AURA.armor) do
        if mq.TLO.Target.Buff(c.buff)() and mq.TLO.Spawn(c.aura)() then return c end
    end
end

local function do_colossus_drag(c)
    local tid = mq.TLO.Target.ID()
    announce('Aura: dragging the Colossus to the %s for its %s', c.aura, c.buff)
    do_aura_follow(c.aura, tid, function()
        return mq.TLO.Target.ID() == tid and mq.TLO.Target.Buff(c.buff)() ~= nil
    end, AURA.DRAG_MAX)
    announce('Aura: Colossus %s %s', c.buff,
        mq.TLO.Target.Buff(c.buff)() and 'still up (gave up)' or 'stripped')
end

-- Both workers dead: take the group to the Colossus. Stops just inside his melee reach
-- (MaxRange: he is huge, so a fixed distance would park us too far or inside him).
local function colossus_wanted()
    return aura_st.did_workers and not aura_st.went_colossus
        and (mq.TLO.SpawnCount("npc worker")() or 0) == 0
        and mq.TLO.Spawn("npc "..AURA.COLOSSUS)() ~= nil
end

local function go_to_colossus()
    if not colossus_wanted() then return end
    aura_st.went_colossus = true
    local col = mq.TLO.Spawn("npc "..AURA.COLOSSUS)
    local reach = math.max(10, (col.MaxRange() or 20) - 5)
    announce('Aura: workers down, heading to the Colossus')
    -- pets left over from the workers would open on him before we get there
    Core.bcg("/pet back off")
    Core.bcg("/swarm leave")
    mq.cmdf("/nav id %d distance=%d %s", col.ID(), reach, tow_nav_opts())
    Core.wait_nav()
    safe_target(col.ID())
    mq.cmdf("/face fast id %d", col.ID())   -- the backward walk can end facing away
end

local function do_aura_run()
    while true do
        local pair, wid = next_worker()
        if pair then
            announce('Aura: to the %s for the %s', pair.aura, pair.worker)
            do_aura_station(pair, wid)
            aura_st.did_workers = true
        elseif colossus_wanted() then
            go_to_colossus()
            break   -- armor drags start on a later pulse, once he is the target
        else
            local c = colossus_armor_up()
            if not c then break end
            do_colossus_drag(c)
            break   -- one armor per run; the next pulse picks up whatever comes next
        end
    end
end

local function check_auras()
    if State.current_task ~= CO.TASK or not flags.DO_AURAS or flags.AURA_DRAG then return end
    if not flags.MA_MODE or not (next_worker() or colossus_wanted() or colossus_armor_up()) then return end
    flags.AURA_DRAG = true
    local saved = Core.get_cwtn_mode()
    -- Already in Manual (left over from an earlier mission): "restoring" that would strand
    -- the MA in Manual for the rest of the fight, so come back in SicTank instead.
    if saved == 'Manual' and Core.isclass_plugin_loaded() then
        announce('Aura: %s was in Manual, will return to SicTank', def.name)
        saved = 'SicTank'
    end
    cwtn("mode 0")
    local ok, err = pcall(do_aura_run)
    if not ok then
        announce_g('aura run error: %s', tostring(err))
        if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
    end
    Core.set_mode(saved)
    flags.AURA_DRAG = false
end

-- ============================================================
-- Mission hooks (see init.lua)
-- ============================================================

function CO.events()
    mq.event('col_stomp', '#*#The Colossus scuffs the ground with one foot#*#', col_ae_feign)
end

CO.pulse = check_auras

-- New instance: no workers worked yet
function CO.reset()
    aura_st.stripped, aura_st.did_workers, aura_st.went_colossus = {}, false, false
end

-- Hail Torm: "now" makes the workers killable and they aggro. The tank's check_auras
-- takes it from there (nearest aura, its worker, then the other).
function CO.start()
    mq.cmd("/nav locyxz -415 1825 1775 distance=10 log=off")
    mq.delay(500)
    while mq.TLO.Navigation.Active() do mq.delay(250) end
    local torm = mq.TLO.Spawn("npc Torm")
    if not (torm() and safe_target(torm.ID())) then
        announce_g('Start: Torm not in reach -- start it by hand')
        return
    end
    mq.delay(500)
    mq.cmd("/say now")
    announce('Start: Colossus started')
    mq.cmd("/target clear")
    -- wait for the workers to go live in the middle of the Stony_Storm
    local storm = mq.TLO.Spawn("Stony_Storm")
    if storm() then
        announce('Start: to the Stony_Storm to wait for the workers')
        mq.cmdf("/nav id %d distance=5 log=off", storm.ID())
        mq.delay(500)
        mq.delay(30000, function() return not mq.TLO.Navigation.Active() end)
    else
        announce_g('Start: no Stony_Storm up to wait in')
    end
end

function CO.ui()
    Core.burn_row('1st Adds emote')
    Core.status_flag('Workers to Auras (MA):', flags.DO_AURAS)
    ImGui.SameLine()
    flags.DO_AURAS = Core.toggle_button('auras', flags.DO_AURAS)
    if flags.AURA_DRAG then
        ImGui.SameLine()
        ImGui.TextColored(Core.COLOR.AMBER, 'dragging')
    end
end

return CO
