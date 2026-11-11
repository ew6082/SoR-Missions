print('====== SoR Missions =======')
print('version 0.980' )
print('by nerp')
print('=======================')
print('/sorm for help')

-- SoR Missions, the common core: state, group comms, mode/nav control, MA targeting, burn
-- mode, the zone-in / start, commands, the window, and the main loop. Everything that
-- belongs to one mission lives in that mission's module (MISSION_MODULES), which hooks in
-- through the fields below -- all optional except TASK:
--   TASK          the shared task's title, which is what turns the mission on
--   giver         name of the NPC handing the mission out (start: zone-in)
--   events()      register the mission's mq.events (Init)
--   enter()       the task has just come up
--   ma_changed(is_ma)  we just became / stopped being the group MA
--   pre_pulse()   every pulse, before targeting
--   hold()        true: the MA stands down this pulse (no pick_target)
--   pick()        true: the mission chose the MA's target itself this pulse
--   skip(spawn)   true: leave this hater out of the kill-order pick
--   pulse()       every pulse, after events
--   reset()       zoned: a new instance
--   can_start()   false refuses the start (it says why)
--   start()       inside the mission: start the event
--   commands      { key = function(value, args) } for /sorm <key> [value]
--   sync()        list of '<key> <value>' commands: the MA's group-wide settings, pushed
--                 to the group on a start
--   usage(cmd)    print the mission's /sorm lines
--   ui()          the mission's section of the window
--   own_kill_announce  true: the mission announces its own boss kill
-- The modules get this core by requiring this folder's module name (MOD) -- registered
-- below before any of them loads, so it is never run a second time -- and add their kill
-- order (Core.kill_order) and burn settings (Core.BURN) when they load.
local mq = require("mq")
require("ImGui")

-- This folder's module name, from where this file sits under the lua folder:
-- 'SoR-Missions' standalone, 'subfolder.SoR-Missions' in the other github folder. The same files then
-- work in either place.
local function module_name()
    local src = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
    local root = (mq.luaDir or ''):gsub('\\', '/'):gsub('/$', '')
    if root ~= '' and src:lower():sub(1, #root + 1) == root:lower()..'/' then src = src:sub(#root + 2) end
    return (src:gsub('/init%.lua$', ''):gsub('/', '.'))
end
local MOD = module_name()

local Core = {}
package.loaded[MOD] = Core

local MISSION_MODULES = { 'echo', 'wax', 'colossus', 'shardrahn' }

local def  = {
    class = mq.TLO.Me.Class.ShortName(),
    name  = mq.TLO.Me.CleanName(),
    DEBUG = false,
    pulse = 600,
    cmd   = "/sorm",
    TARGET_RANGE = 200,   -- safe_target: farther than this only if on xtarget
    ENGAGE_MAX = 400,       -- xt_sane: a hater farther than this (3D) is not engaged
    ENGAGE_NEAR = 100,      -- xt_sane: past this, the nav path is checked too
    ENGAGE_PATH_MAX = 600,  -- xt_sane: a longer nav path (or none) is not engaged
}

local flags = {
    PAUSED = false,         -- UI Pause button / '/sorm pause': Main does nothing, events dropped
    GREEDLING_GIVE_PLAT = false,
    KILL_GREEDLING = true,  -- MA: off leaves greedlings alone for whoever is giving them coin
    WAX_BALANCE = true,     -- Waxwork: MA balances the adds' HP (off = kill in order)
    DO_AURAS = true,       -- Colossus: tank drags each worker onto its aura (see check_auras)
    DODGE_STORMS = true,   -- Shar'Drahn: step out of '_storm' spawns (see check_storms)
    BURN_MODE = true,      -- Shar'Drahn/Colossus: burn at the trigger, then boss only (see BURN)
    MA_MODE = false,
    DOING_CIRCLE = false,
    HEAL_NORTH = true,   -- heal the Dark Flagellant; off for the achievement
    P2_FULLBURN = false, -- Echo of Hate: burn the Echo the moment we land in phase 2, no hold (crystals achievement)
    USE_SKEL = true,     -- Echo of Hate illusion: true = skeleton, false = Jann
    ILLUSION_OTHER = true,  -- Echo of Hate: players handle the illusion themselves; sorm neither checks nor clicks it (default)
    USE_EQBC = false,       -- group broadcasts over EQBC instead of DanNet (UI radio / set_use_eqbc)
    ANNO = true, --basic info
}

-- task title -> kill order (spawn names), filled in by each mission module. Unlisted
-- haters go after the adds, before the boss (get_priority).
local kill_order = {}

-- Script-wide values that change as it runs, shared with the mission modules.
local State = {
    current_task = 'None',
    assigned_target = nil,           -- MA's pick (engage)
    current_target_priority = 20,
    self_held = false,               -- MA parked in Manual on a self-target (see engage)
    OPENGUI = true,                  -- closing the window ends the script
    DRAWGUI = false,
}

local missions = {}   -- task title -> mission module

Core.def, Core.flags, Core.kill_order, Core.state, Core.missions = def, flags, kill_order, State, missions

-- The current task's mission module, or nil outside our missions
local function mission() return missions[State.current_task] end
Core.mission = mission

-- Command work that blocks (navs, waits): the bind only queues it and the main loop runs
-- it, so the bind returns at once.
local deferred = {}
function Core.defer(fn) deferred[#deferred + 1] = fn end

-- ============================================================
-- Comms and small helpers
-- ============================================================

-- EQBC is the default when MQ2EQBC is loaded and every group member (us too) is in its
-- name list: a group split across remote machines only shares EQBC. Set once at startup (Init);
-- the UI radio / set_use_eqbc changes it after that.
local function eqbc_has_group()
    if not mq.TLO.Plugin('mq2eqbc').IsLoaded() then return false end
    local ok, names = pcall(function() return mq.TLO.EQBC.Names() end)
    if not ok or not names or names == '' then return false end
    local on = {}
    for n in names:gmatch('%S+') do on[n:lower()] = true end
    if not on[def.name:lower()] then return false end
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local n = mq.TLO.Group.Member(i).Name()
        if not n or not on[n:lower()] then return false end
    end
    return true
end

-- Lowercased names we can reach on the selected transport, us included. 
function Core.reachable_names()
    local list
    if flags.USE_EQBC then
        local ok, n = pcall(function() return mq.TLO.EQBC.Names() end)
        list = ok and n or ''
    else
        list = mq.TLO.DanNet.Peers() or ''
    end
    local set = { [def.name:lower()] = true }
    for n in list:gmatch('[^%s|]+') do set[(n:gsub('^.*_', '')):lower()] = true end
    return set
end

-- The rest of the group, split: boxes (reachable on the transport -- ours, can run sorm)
-- and outside (an outside player, or a toon off EQBC/DanNet). Mercenaries in neither.
function Core.group_boxes()
    local reach, boxes, outside = Core.reachable_names(), {}, {}
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        local n = m.Name()
        if n and not m.Mercenary() then
            if reach[n:lower()] then boxes[#boxes + 1] = n else outside[#outside + 1] = n end
        end
    end
    return boxes, outside
end

-- The shared task (mission) only: Type 'Shared'. Plain quests read 'Quest'. One of our
-- missions is looked up by its title; any other shared task is read from Task(1) (the
-- shared task when there is one), so it shows as "not one of ours".
local function read_task()
    for title in pairs(missions) do
        local t = mq.TLO.Task(title)
        if t() and t.Title() == title and t.Type() == 'Shared' then return title end
    end
    if mq.TLO.Task(1).Type() ~= 'Shared' then return 'None' end
    local t = mq.TLO.Task(1).Title()
    return (t and t ~= '' and t ~= 'NULL') and t or 'None'
end

local function debug_local(str,...) if(def.DEBUG) then printf('DEBUG: '..str, ...) end end
local function announce(str,...) if(flags.ANNO) then printf('\awSOR-Missions: \ag'..str, ...) end end

-- A player can target what is near, or anything on their XTarget window
local function can_target(id)
    local s = mq.TLO.Spawn(id)
    if not s() then return false end
    if (s.Distance() or math.huge) <= def.TARGET_RANGE then return true end
    for i = 1, 20 do
        if mq.TLO.Me.XTarget(i).ID() == id then return true end
    end
    return false
end

-- /target id, only when a player could. False (and nothing sent) if not.
local function safe_target(id)
    if not id or not can_target(id) then
        debug_local('not targeting %s: over %d away and not on xtarget',
            tostring(mq.TLO.Spawn(id or 0).CleanName()), def.TARGET_RANGE)
        return false
    end
    mq.cmdf("/target id %d", id)
    return true
end
-- Send over the selected transport: eqbc / dannet are the two command prefixes. noparse
-- leaves ${...} in the command for each receiver to expand, instead of us.
local function group_send(noparse, eqbc, dannet, fmt, ...)
    mq.cmdf((noparse and '/noparse ' or '')..(flags.USE_EQBC and eqbc or dannet)..fmt, ...)
end
-- Run a command on every group member, self included, over the selected transport.
local function bcg(fmt, ...) group_send(false, '/bcga /', '/dgga ', fmt, ...) end
local function bcge(fmt, ...) group_send(false, '/bcg /', '/dgge ', fmt, ...) end   -- not on us
-- Same, /noparse
local function bcg_np(fmt, ...) group_send(true, '/bcga /', '/dgga ', fmt, ...) end
local function bcge_np(fmt, ...) group_send(true, '/bcg /', '/dgge ', fmt, ...) end
-- Run a command on one named toon over the selected transport.
local function bct_send(noparse, name, fmt, ...)
    mq.cmdf((noparse and '/noparse ' or '')..(flags.USE_EQBC and '/bct %s /' or '/dex %s ')..fmt, name, ...)
end
local function bct(name, fmt, ...) bct_send(false, name, fmt, ...) end
local function bct_np(name, fmt, ...) bct_send(true, name, fmt, ...) end
-- Quiet versions for chatter nobody needs to read (ping/pong): /squelch on our side. The
-- receiver's EQBC still prints its '# CMD' line unless that toon has /bccmd set silentcmd
-- on (this EQBC server has no silent /bcsg, /bcst).
local function bcge_q(fmt, ...) mq.cmdf('/squelch '..(flags.USE_EQBC and '/bcg /' or '/dgge ')..fmt, ...) end
local function bct_q(name, fmt, ...) mq.cmdf('/squelch '..(flags.USE_EQBC and '/bct %s /' or '/dex %s ')..fmt, name, ...) end
-- safe_target for another toon: the receiver checks its own distance. Send with a _np
-- sender, args (id, def.TARGET_RANGE, id).
local TARGET_IF_NEAR = "/if (${SpawnCount[id %d radius %d]}) /target id %d"
-- Zone-in pushes: the receiver checks it is in game and not zoning before running them,
-- and drops them if it is. Send with a _np sender.
local INGAME = "${EverQuest.GameState.Equal[INGAME]} && !${Me.Zoning}"
local IF_INGAME = "/if (" .. INGAME .. ") "
local TARGET_IF_NEAR_INGAME = "/if (" .. INGAME .. " && ${SpawnCount[id %d radius %d]}) /target id %d"

-- announce, plus an /echo on the rest of the group (not the whole DanNet/EQBC network)
local function announce_g(str, ...)
    if not flags.ANNO then return end
    local msg = string.format(str, ...)
    printf('\awSOR-Missions: \ar%s', msg)
    -- a raw \a is a BEL byte, and the EQBC server console beeps on every one it prints.
    bcge_np("/echo \\awSOR-Missions [%s]: \\ar%s", def.name, (msg:gsub('\a', '\\a')))
end

local function check_eqbc_default()
    flags.USE_EQBC = eqbc_has_group()
    if flags.USE_EQBC and mq.TLO.Group.MainAssist() == def.name then bcge("%s set_use_eqbc on", def.cmd) end
    printf('Group broadcasts: %s (%s)', flags.USE_EQBC and 'EQBC' or 'DanNet',
        flags.USE_EQBC and 'whole group is on EQBC' or 'not all of the group is on EQBC')
end
-- 'on'/'off' set a flag with various args
local function bool_arg(value, current)
    if value == nil then return not current end
    local v = tostring(value):lower()
    if v == 'on' or v == 'true' or v=='1' then return true
    elseif v == 'off' or v == 'false' or v=='0' then return false
    else return not current end
end

local function squelch(pat,...) mq.cmdf("/squelch "..pat, ...) end

-- 2D distance from us to y, x
local function dist2d(y, x)
    if not (y and x) then return math.huge end
    return mq.TLO.Math.Distance(y..','..x)() or math.huge
end

-- 2D distance between two points
function Core.dist_yx(y1, x1, y2, x2)
    return mq.TLO.Math.Distance(y1..','..x1..':'..y2..','..x2)() or math.huge
end

-- Mission/raid instance by short name. Not Me.Instance: guild halls are instanced too and
-- read non-zero there.
local function in_instance_zone()
    local zsn = mq.TLO.Zone.ShortName() or ''
    return zsn:find('_mission$') ~= nil or zsn:find('_raid$') ~= nil
end

function Core.is_healer()
    return def.class == 'CLR' or def.class == 'SHM' or def.class == 'PAL' or def.class == 'DRU'
end

-- Nav options for a move: walk backward while anything is on our hate list, so we keep
function Core.tow_nav_opts()
    for i = 1, 20 do
        local xt = mq.TLO.Me.XTarget(i)
        if (xt.ID() or 0) ~= 0 and xt.TargetType() == 'Auto Hater' then
            return 'facing=backward log=off'
        end
    end
    return 'log=off'
end

-- Sanity check on a hater before engaging it. A spawn can warp: one landed on Shar'Drahn,
-- aggroed, then warped back to its spawn point, and the MA navved across the zone after
-- it. Gone, dead, too far, or no reasonable nav path: false (announced once per spawn).
-- The mission's own mobs (kill order, burn boss) skip the range checks: Shar'Drahn is
-- 430 from Gwark at the start. Only stray haters can be warp bugs.
local xt_warned = {}
local function mission_mob(s)
    local name = (s.Name() or ''):lower()
    for _, n in ipairs(kill_order[State.current_task] or {}) do
        if name:find(n:lower(), 1, true) then return true end
    end
    local boss = Core.BURN and Core.BURN.boss[State.current_task]
    return boss ~= nil and (s.CleanName() or ''):lower():find(boss:lower(), 1, true) ~= nil
end
local function xt_sane(id)
    local s = mq.TLO.Spawn(id or 0)
    if not s() or s.Dead() then return false end
    if mission_mob(s) then return true end
    local d = s.Distance3D() or math.huge
    local why
    if d > def.ENGAGE_MAX then
        why = string.format('%.0f away', d)
    elseif d > def.ENGAGE_NEAR then
        local len = mq.TLO.Navigation.PathLength('id '..id)() or -1
        if len < 0 then why = 'no nav path'
        elseif len > def.ENGAGE_PATH_MAX then why = string.format('%.0f away by nav', len) end
    end
    if not why then
        xt_warned[id] = nil
        return true
    end
    if not xt_warned[id] then
        xt_warned[id] = true
        announce_g('Not engaging %s (%d): %s -- warped or bugged?', tostring(s.CleanName()), id, why)
    end
    return false
end
Core.xt_sane = xt_sane

Core.read_task, Core.debug_local, Core.announce, Core.announce_g = read_task, debug_local, announce, announce_g
Core.can_target, Core.safe_target = can_target, safe_target
Core.bcg, Core.bcge, Core.bcg_np, Core.bcge_np, Core.bct, Core.bct_np = bcg, bcge, bcg_np, bcge_np, bct, bct_np
Core.bcge_q, Core.bct_q = bcge_q, bct_q
Core.TARGET_IF_NEAR = TARGET_IF_NEAR
Core.bool_arg, Core.squelch, Core.dist2d, Core.in_instance_zone = bool_arg, squelch, dist2d, in_instance_zone

-- ============================================================
-- Pause / resume and navigation
-- ============================================================

-- CWTN class plugin by class short name
local CWTN_PLUGIN = { BER='mq2berzerker', BRD='mq2bard', BST='mq2bst', CLR='mq2cleric', DRU='mq2druid',
    ENC='mq2enchanter', MAG='mq2mage', MNK='mq2monk', NEC='mq2necro', PAL='mq2paladin', RNG='mq2ranger',
    ROG='mq2rogue', SHD='mq2eskay', SHM='mq2shaman', WAR='mq2war', WIZ='mq2wizard'
}

local function isclass_plugin_loaded()
    return mq.TLO.Plugin(CWTN_PLUGIN[mq.TLO.Me.Class.ShortName()]).IsLoaded()
end

-- Pause the class plugin / macro / helper luas. An already-paused plugin is not sent
-- "pause on" again (CWTN's bard plugin stops the current song on a delay each pause).
local function pause()
    local ok, was_paused = pcall(function() return mq.TLO.CWTN.Paused() end)
    was_paused = ok and was_paused
    if(mq.TLO.Me.Class.ShortName() == "BRD") then
        squelch("/twist off")
        mq.delay(100)
        squelch("/stopsong") end
    if(isclass_plugin_loaded() ) then
        if not was_paused then mq.cmdf("/%s pause on", mq.TLO.Me.Class.ShortName() ) end
    elseif(mq.TLO.Macro.Name() == "kissassist.mac") then squelch("/mqp on")
    elseif(mq.TLO.Macro.Name() == "rgmercs.mac") then squelch("/mqp on")
    elseif(mq.TLO.Macro.Name() == "RGMERC.mac") then squelch("/mqp on")
    elseif(mq.TLO.Lua.Script('rgmercs').Status() == 'RUNNING') then squelch('/lua pause rgmercs')
    elseif(mq.TLO.Me.Class.ShortName() == "WIZ") then squelch("/nuke pause")
    elseif(mq.TLO.Macro.Name() == "entropy.mac") then squelch("/mqp on") end

    if(mq.TLO.Lua.Script('chase').Status() == 'RUNNING') then squelch('/lua pause chase') end
    mq.delay(10)
    if (def.class == 'BER') and (mq.TLO.Me.ActiveDisc.Name() == mq.TLO.Spell('Frenzied Resolve Discipline').RankName()) then
        mq.cmd("/stopdisc")
    end
    mq.cmd("/stick off")
end

local function resume()
    if(isclass_plugin_loaded() ) then
        mq.cmdf("/%s pause off", mq.TLO.Me.Class.ShortName() )
        -- SicTank keeps a camp: we were moved while paused, so camp here or it walks us back
        local ok, m = pcall(function() return mq.TLO.CWTN.Mode() end)
        if ok and (m or ''):find('Sic') then mq.cmdf("/%s resetcamp", mq.TLO.Me.Class.ShortName()) end
    elseif(mq.TLO.Macro.Name() == "kissassist.mac") then squelch("/mqp off")
    elseif(mq.TLO.Macro.Name() == "rgmercs.mac") then squelch("/mqp off")
    elseif(mq.TLO.Macro.Name() == "RGMERC.mac") then squelch("/mqp off")
    elseif(mq.TLO.Macro.Name() == "entropy.mac") then squelch("/mqp off")
    elseif(mq.TLO.Me.Class.ShortName() == "WIZ") then squelch("/nuke resume") end

    if(mq.TLO.Lua.Script('offtank').Status() == 'PAUSED') then squelch('/lua pause offtank') end
    if(mq.TLO.Lua.Script('chase').Status() == 'PAUSED') then squelch('/lua pause chase') end
    if(mq.TLO.Lua.Script('rgmercs').Status() == 'PAUSED') then squelch('/lua pause rgmercs') end
end

-- Scan +/- 200 in Z for a spot nav can path to. Returns that Z, or false.
local function find_z_nav(y1,x1,z1)
    if not y1 or not x1 or not z1 then return false end
    local range = 200
    local checknav = string.format('locyxz %s %s %s',y1,x1,z1)
    if mq.TLO.Navigation.PathExists(checknav)() then return z1 end
    for dz = 1,range do
        if mq.TLO.Navigation.PathExists('locyxz '..y1..' '..x1..' '..z1+dz)() then
            return z1+dz
        elseif mq.TLO.Navigation.PathExists('locyxz '..y1..' '..x1..' '..z1-dz)() then
            return z1-dz
        end
    end
    return false
end

-- Validate and execute navigation to coordinates with Z correction fallback
-- Returns corrected z on success, false if no valid path exists
local function nav_to_loc(y, x, z, nav_opts)
    if not y or not x or not z then return false end
    if not nav_opts then nav_opts = 'log=off' end
    if mq.TLO.Navigation.PathExists(string.format('locyxz %s %s %s', y, x, z))() then
        mq.cmdf("/nav locyxz %s %s %s %s", y, x, z, nav_opts)
        return z
    end
    local corrected_z = find_z_nav(y, x, z)
    if corrected_z then
        debug_local('nav_to_loc: Z corrected %s -> %s at (%.0f, %.0f)', z, corrected_z, y, x)
        mq.cmdf("/nav locyxz %s %s %s %s", y, x, corrected_z, nav_opts)
        return corrected_z
    end
    debug_local('nav_to_loc: No valid path to (%.0f, %.0f, %s)', y, x, tostring(z))
    return false
end

-- Wait for a nav we just sent: up to 1s for it to start, then up to max_s (default 30s)
-- for it to end.
function Core.wait_nav(max_s)
    local t = mq.gettime()
    while not mq.TLO.Navigation.Active() and (mq.gettime() - t) < 1000 do mq.delay(50) end
    t = mq.gettime()
    while mq.TLO.Navigation.Active() and (mq.gettime() - t) < (max_s or 30) * 1000 do mq.delay(100) end
end

-- Selo's (bard run speed) slides us past nav stops. Strip it before a nav that has to
-- stop on a spot; the bard re-pulses it within seconds, so do it per nav, not once.
-- The client refuses a buff removal mid-cast ("You cannot remove this effect"), and in a
-- fight CWTN keeps clicking items/AAs, so wait the cast out first. Not on a bard: its
-- Me.Casting stays set for as long as a song plays.
function Core.remove_selos()
    for _ = 1, 3 do
        local n = mq.TLO.Me.Song('Selo')() or mq.TLO.Me.Buff('Selo')()
        if not n then return end
        if def.class ~= 'BRD' then mq.delay(3000, function() return not mq.TLO.Me.Casting() end) end
        mq.cmdf("/removebuff %s", n)
        mq.delay(100)
    end
end

Core.isclass_plugin_loaded, Core.pause, Core.resume = isclass_plugin_loaded, pause, resume
Core.find_z_nav, Core.nav_to_loc = find_z_nav, nav_to_loc

-- ============================================================
-- MODE CONTROL: CWTN class plugin, else MQ2Boxr
-- ============================================================
-- Everything below talks CWTN ('mode N', 'burnnow', ...). Without a CWTN plugin for our
-- class the same calls go through MQ2Boxr, which drives RGMercs (macro or Lua),
-- KissAssist or MuleAssist with one command set: Manual, Camp, Chase, Pause/Unpause,
-- BurnNow (read from the MQ2Boxr DLL; Boxr maps them onto CWTN as mode manual / mode
-- assist + resetcamp / mode chase). Boxr has no Vorpal or tank modes, so each CWTN mode
-- maps to the closest of its three: home-point modes camp where we stand, mobile ones
-- chase. CWTN-only settings (xtarget NPC healing) have no Boxr form and are skipped.
local BOXR_FOR_MODE = {
    [0] = 'Manual',
    [1] = 'Camp',    -- Assist
    [2] = 'Chase',   -- Chase
    [3] = 'Chase',   -- Vorpal: mobile, no home point
    [4] = 'Camp',    -- Tank
    [5] = 'Camp',    -- PullerTank
    [6] = 'Camp',    -- PullerAssist
    [7] = 'Camp',    -- SicTank: no going home, so camp where we are
    [8] = 'Camp',    -- HunterTank
}
-- Boxr cannot report the mode, so remember the last one we set. default to Chase
local boxr_mode = 'Chase'
local boxr_skipped = {}   -- CWTN-only commands already reported as skipped

-- CWTN mode number by the name CWTN.Mode reports. Mode 3 reads 'VorpalAssist' (seen live
-- 2026-10-27), mode 2 'ChaseAssist' (2026-10-28); the short names kept too. Camp is
-- MQ2Boxr's name for its home-point mode (get_cwtn_mode under Boxr).
Core.MODE_NUM = { Assist=1, Camp=1, Chase=2, ChaseAssist=2, Vorpal=3, VorpalAssist=3, Tank=4, PullerTank=5, PullerAssist=6, SicTank=7, HunterTank=8 }

-- RGMercs Lua edition, driving this character instead of a CWTN plugin. It has commands
-- Boxr does not use (read from /rgl help, RGMercs 2.3.2): burnnow, a one-off burn (Boxr's
-- BurnNow sets BurnAlways 1 instead); forcetarget, so an RGMercs MA fights what we pick
-- instead of its own auto-target; ignoretarget; and backoff, to stop engaging entirely.
local function rgmercs_lua()
    return not isclass_plugin_loaded() and mq.TLO.Lua.Script('rgmercs').Status() == 'RUNNING'
end

local function boxr_cmd(cmd)
    local n = tonumber(cmd:match('^mode%s+(%d+)'))
    if n then
        local b = BOXR_FOR_MODE[n]
        -- The MA has nobody to chase: RGMercs answers "No valid chase target!" 
        if b == 'Chase' and mq.TLO.Group.MainAssist() == def.name then b = 'Camp' end
        if b then
            boxr_mode = b
            mq.cmdf("/boxr %s", b)
        end
    elseif cmd:lower() == 'burnnow' then
        if rgmercs_lua() then mq.cmd("/rgl burnnow") else mq.cmd("/boxr BurnNow") end
    elseif cmd:lower() == 'resetcamp' then
        if boxr_mode == 'Camp' then mq.cmd("/boxr camp") end   -- camp is where we stand
    else
        local key = cmd:match('^(%S+)') or cmd
        if not boxr_skipped[key] then
            boxr_skipped[key] = true
            debug_local('MQ2Boxr: no equivalent for CWTN "%s", skipped', cmd)
        end
    end
end

local function cwtn(cmd)
    if isclass_plugin_loaded() then
        mq.cmd("/"..def.class.." "..cmd)
        -- SicTank (the MA's mode) returns to its camp: camp where we are switching to it
        if cmd:match('^mode%s+7') then mq.cmd("/"..def.class.." resetcamp") end
    else boxr_cmd(cmd) end
end

-- Mode / pause on another toon, which may or may not run sorm. The receiver picks: its
-- CWTN class plugin if loaded (the exact CWTN command), else MQ2Boxr's form of it.
-- delay: tenths of a second, sent as /timed.
-- ingame: only if the receiver is in game and not zoning (zone-in pushes).
local function bct_mode(name, cls, cwtn_cmd, boxr_cmd, delay, ingame)
    local plugin = CWTN_PLUGIN[cls or '']
    local cmd = plugin
        and string.format("/docommand ${If[${Plugin[%s].IsLoaded},/%s %s,/boxr %s]}", plugin, cls:lower(), cwtn_cmd, boxr_cmd)
        or "/boxr "..boxr_cmd
    if delay then cmd = "/timed "..delay.." "..cmd end
    if ingame then cmd = IF_INGAME..cmd end
    bct_np(name, "%s", cmd)
end

-- Mode name: CWTN's own, or under MQ2Boxr the last one set (Manual / Camp / Chase)
local function get_cwtn_mode()
    if not isclass_plugin_loaded() then return boxr_mode end
    ---@diagnostic disable-next-line: undefined-field
    return mq.TLO.CWTN.Mode()
end

-- Back to a mode by the name get_cwtn_mode gave for it (a saved mode). Manual / none /
-- nil leave us where we are.
local function set_mode(m)
    local key = m and (tostring(m):gsub(' ', ''))
    local n = key and Core.MODE_NUM[key]
    if n then cwtn("mode "..n)
    elseif key and key ~= 'Manual' and key ~= 'none' then
        announce_g('Cannot restore CWTN mode "%s" -- unknown name, still in Manual', key)
    end
end

-- Fight mode after a scripted move: the MA SicTanks (not Vorpal), everyone else Chases it
local function fight_mode()
    cwtn(mq.TLO.Group.MainAssist() == def.name and 'mode 7' or 'mode 2')
end

-- Target `id` as MA. Under RGMercs Lua also force it as RGMercs' auto-target, or RGMercs
-- picks its own and fights our choice (forcetarget holds until the mob is invalid).
local function ma_target(id)
    if not can_target(id) then return end
    mq.cmdf("/mqtarget id %d", id)
    if rgmercs_lua() then mq.cmdf("/rgl forcetarget %d", id) end
end

-- Stop / resume engaging entirely (RGMercs Lua only; CWTN callers use Manual instead).
function Core.rgmercs_backoff(on)
    if rgmercs_lua() then mq.cmdf("/rgl backoff %s", on and 'on' or 'off') end
end

-- Required plugins, checked once at startup: MQ2Nav, DanNet or EQBC for the group, and a
-- CWTN class plugin or MQ2Boxr for mode control. Lists what is missing; false if anything is.
local function check_plugins()
    local missing = {}
    if not mq.TLO.Plugin('mq2nav').IsLoaded() then
        missing[#missing + 1] = 'MQ2Nav (/plugin mq2nav)'
    end
    if not mq.TLO.Plugin('mq2dannet').IsLoaded() and not mq.TLO.Plugin('mq2eqbc').IsLoaded() then
        missing[#missing + 1] = 'MQ2DanNet or MQ2EQBC (/plugin mq2dannet)'
    end
    if not isclass_plugin_loaded() and not mq.TLO.Plugin('mq2boxr').IsLoaded() then
        missing[#missing + 1] = string.format('a CWTN plugin for %s, or MQ2Boxr (/plugin mq2boxr)', tostring(def.class))
    end
    if #missing == 0 then
        if not isclass_plugin_loaded() then print('Mode control: MQ2Boxr (Manual / Camp / Chase)') end
        return true
    end
    print('\arSoR Missions needs these plugins loaded:')
    for _, p in ipairs(missing) do print('\ar  - '..p) end
    return false
end

Core.rgmercs_lua, Core.cwtn, Core.get_cwtn_mode, Core.set_mode = rgmercs_lua, cwtn, get_cwtn_mode, set_mode
Core.fight_mode, Core.ma_target, Core.bct_mode = fight_mode, ma_target, bct_mode

-- ============================================================
-- MA targeting: the hate list in the mission's kill order
-- ============================================================

local xtars={}
local spawns_data={}
local xtar_count = 0

-- Kill order: kill in order, kill unlisted mobs 1st (stray aggro)
local function get_priority(spawn)
    local order = kill_order[State.current_task]
    if not order then return 0 end
    local name = spawn.Name()
    if not name then return #order + 1 end
    name = name:lower()
    for i = 1, #order do
        if name:find(order[i]:lower(), 1, true) then return i end
    end
    return #order - 0.5 --unlisted: after the adds, before the boss
end

-- populate xtars array | xtars == [#][ID]
-- Walks all 20 slots: haters are not packed at the front, so reading only the first
-- <hater count> slots missed any mob sitting behind an empty or non-hater slot.
local function radar()
    xtars = {}
    spawns_data = {}
    for i = 1, 20 do
        local xt = mq.TLO.Me.XTarget(i)
        local xtid = tonumber(xt.ID())
        if xtid and xtid ~= 0 and xt.TargetType() == 'Auto Hater' and xt.Type() == 'NPC' and xt.Master() == nil
                and not (xt.CleanName() or ''):find('corpse', 1, true)   -- fresh corpse can read NPC
                and xt_sane(xtid) then
            table.insert(xtars, xtid)
        end
    end
    xtar_count = #xtars
    local m = mission()
    for _, v in ipairs(xtars) do
        local xt = mq.TLO.Spawn(v)
        if not (m and m.skip and m.skip(xt)) then
            table.insert(spawns_data, {ID = v, name = xt.Name(), priority = get_priority(xt)})
        end
    end
    -- ID as tiebreak so equal-priority mobs keep a stable order and the pick does not flap
    table.sort(spawns_data, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.ID < b.ID
    end)
end

-- RGMercs MA: Camp fights from where it stands and Chase has nobody to follow, so nothing
-- walks the MA to a target out of reach (seen: the MA 200 off the Echo, attack on, idle).
-- Walk it into melee and re-camp there. Not in Manual: sorm is moving us itself then.
local BOXR_RG = { next = 0, EVERY = 3000 }   -- ms
function BOXR_RG.close_in()
    if not rgmercs_lua() or mq.TLO.Group.MainAssist() ~= def.name or boxr_mode == 'Manual' then return end
    if not State.assigned_target or mq.TLO.Navigation.Active() or mq.gettime() < BOXR_RG.next then return end
    local t = mq.TLO.Spawn(State.assigned_target)
    if not t() or t.Dead() then return end
    local reach = math.max(10, t.MaxRange() or 10)
    if (t.Distance() or 0) <= reach + 5 then return end
    BOXR_RG.next = mq.gettime() + BOXR_RG.EVERY
    debug_local('RGMercs MA: %s is %.0f off -- walking in', tostring(t.CleanName()), t.Distance() or -1)
    mq.cmdf("/nav id %d distance=%d log=off", t.ID(), math.floor(reach - 2))
    mq.delay(500)
    mq.delay(15000, function() return not mq.TLO.Navigation.Active() end)
    mq.cmd("/boxr camp")   -- camp is where we stand now
    boxr_mode = 'Camp'
end

local function engage(targid, priority)
    if not xt_sane(targid) then
        if State.assigned_target == targid then State.assigned_target = nil end
        return
    end
    State.assigned_target = targid
    State.current_target_priority = priority
    if not mq.TLO.Spawn(targid)() then return end
    local name = mq.TLO.Spawn(targid).Name()
    debug_local('Engaging: %s(%s) p: %s',name,targid,State.current_target_priority)
    if State.self_held then   -- parked in Manual on a self-target (echo's leave_greedling): back to SicTank
        State.self_held = false
        fight_mode()
    end
    ma_target(targid)
    mq.delay(500)
    local t = mq.gettime()
    while mq.TLO.Window('CastingWindow').Open() and (mq.gettime() - t) < 3000 do mq.delay(150) end
    mq.cmd("/attack on")

    BOXR_RG.next = 0
    BOXR_RG.close_in()
    if get_cwtn_mode() == 'Manual' then mq.cmdf("/face fast id %d", targid) end
    debug_local('spawns_data:')
    for k=1,#spawns_data do
        debug_local('   %s: %s(%s) P%s',k,spawns_data[k].name,spawns_data[k].ID ,spawns_data[k].priority)
    end
    ma_target(targid)
    mq.delay(1000)
    ma_target(targid)
end

local function reset_engage()
    debug_local('Resetting Engage  ATID[%s] P[%s]',State.assigned_target,State.current_target_priority)
    State.assigned_target = nil
    State.current_target_priority = kill_order[State.current_task] and #kill_order[State.current_task] or 10
end

Core.engage, Core.reset_engage = engage, reset_engage

-- ============================================================
-- BURN. With BURN_MODE on, the first trigger of the fight fires burnnow and from then
-- on the MA fights only the boss, ignoring adds, until the boss is gone. Trigger is the
-- mission's emote (BURN.emote, hooked in burn_events) or, whichever comes first, one of
-- the BURN.trigger spawns appearing while the boss is on xtarget -- the boss check keeps
-- trash that is up before the pull from setting it off. Missions using it fill in all
-- three tables for their task.
-- ============================================================
local BURN = { boss = {}, trigger = {}, emote = {} }
local burn_st = {}
burn_st.active  = false
burn_st.pending = false   -- UI 'Burn Now': ImGui cannot delay, so Main runs it
burn_st.known   = {}      -- trigger-mob IDs that were up before the pull (check_burn)
Core.BURN, Core.burn_st = BURN, burn_st

local function burn_boss_spawn()
    local name = BURN.boss[State.current_task]
    local s = name and mq.TLO.Spawn("npc "..name)
    if s and s() and not s.Dead() then return s end
end
Core.burn_boss_spawn = burn_boss_spawn

local function boss_on_xtarget()
    local name = BURN.boss[State.current_task]
    if not name then return false end
    name = name:lower()
    for i = 1, 20 do
        local n = mq.TLO.Me.XTarget(i).CleanName()
        if n and n:lower():find(name, 1, true) then return true end
    end
    return false
end

-- force: Burn Now from the UI/bind, which skips the BURN_MODE and boss checks.
local function start_burn(why, force)
    if burn_st.active or not BURN.boss[State.current_task] then return end
    if not force and not flags.BURN_MODE then return end
    burn_st.active = true
    announce('Burn (%s): burning, MA on %s only', why, BURN.boss[State.current_task])
    cwtn("burnnow")
    mq.delay(2000)
    cwtn("burnnow")
end

local function check_burn()
    if not BURN.boss[State.current_task] then return end
    if burn_st.pending then
        burn_st.pending = false
        start_burn('Manual', true)
    end
    if burn_st.active then
        if not burn_boss_spawn() then burn_st.active = false end
        return
    end
    if not flags.BURN_MODE then return end
    -- Only a trigger mob that appears after the pull counts: Colossus has a runic worker
    -- standing by Torm before the event. Anything seen while the boss is not on xtarget
    -- is remembered by ID and never triggers.
    local engaged = boss_on_xtarget()
    for _, n in ipairs(BURN.trigger[State.current_task] or {}) do
        for _, s in ipairs(mq.getFilteredSpawns(function(sp)
            return (sp.CleanName() or ''):lower():find(n:lower(), 1, true) ~= nil
        end)) do
            local id = s.ID()
            if not engaged then
                burn_st.known[id] = true
            elseif not burn_st.known[id] then
                start_burn(n..' spawned')
                return
            end
        end
    end
end

-- Burn triggers. Checked against the task at fire time, so one registration per text.
local function burn_events()
    for task, text in pairs(BURN.emote) do
        mq.event('burn_'..task:gsub('%W', ''), text, function()
            if State.current_task == task and boss_on_xtarget() then start_burn('emote') end
        end)
    end
end

local function pick_target()
    local m = mission()
    if m and m.pick and m.pick() then return end
    -- Burning: the boss and nothing else.
    if burn_st.active then
        local boss = burn_boss_spawn()
        if boss then
            if State.assigned_target ~= boss.ID() or mq.TLO.Target.ID() ~= boss.ID() then
                engage(boss.ID(), 0)
            end
            return
        end
    end
    radar()

    -- Release the assignment as soon as it leaves the hate list, not only when it dies:
    -- a mob that goes non-aggro (the Echo during the labyrinth phase) stays alive, and
    -- the MA used to sit on it while a live add was up.
    local current
    for _, s in ipairs(spawns_data) do
        if s.ID == State.assigned_target then current = s break end
    end
    if State.assigned_target and not current then
        debug_local('target %s dead or off the hate list', tostring(State.assigned_target))
        reset_engage()
    end

    if #spawns_data == 0 then return end
    local top = spawns_data[1]

    if not current then
        engage(top.ID, top.priority)
    elseif top.priority < current.priority then
        -- something higher in the kill order is up: switch, whatever the current HP
        engage(top.ID, top.priority)
    elseif mq.TLO.Target.ID() ~= State.assigned_target then
        -- Something else moved our target: the echo room code, or SicTank, which grabs
        -- named mobs on its own. Snap straight back -- a full engage() takes seconds, and
        -- SicTank would just swap again in the meantime.
        debug_local('target drifted off %s onto %s, retargeting', tostring(current.name),
            tostring(mq.TLO.Target.CleanName()))
        ma_target(current.ID)
        if not mq.TLO.Me.Combat() then mq.cmd("/attack on") end
    end
end

-- ============================================================
-- Start, part 1: out of the mission, get in. Target the task's giver (by name, else the
-- nearest NPC -- we are standing at it), say ready, and wait out the zone. Each toon says
-- it for itself, a random beat apart so the givers' replies don't all land at once.
-- ============================================================
local START = {}
START.GIVER_RADIUS = 60
START.ZONE_WAIT    = 120   -- s for the port into the mission
START.SETTLE       = 5     -- s after landing for the spawns to come in

local function start_giver()
    local m = mission()
    local name = m and m.giver
    local giver = name and mq.TLO.Spawn(string.format("npc radius %d %s", START.GIVER_RADIUS, name))
    if not (giver and giver()) then
        giver = mq.TLO.NearestSpawn(string.format('npc radius %d', START.GIVER_RADIUS))
    end
    return giver
end

-- The rest of the group gets plain commands, so they zone in whether or not sorm is
-- running on them: target the giver by ID (the same on every client), then say ready a
-- random 0-10s later (as /bcgat10), so they don't all hit the giver at once. noparse
-- keeps ${Math.Rand} for each receiver to roll.
-- The class plugins in assist modes (assist/chase/vorpal) force-target the MA's target --
-- nothing, once the MA has ported -- so the group's plugins are paused for the zone-in
-- and unpaused as each toon lands (start_group_catchup). only = set of names, or all.
local function start_group_pause(on, only)
    local reach = Core.reachable_names()   -- an outside player gets nothing
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        local name, cls = m.Name(), m.Class.ShortName()
        if name and cls and not m.Mercenary() and reach[name:lower()] and (not only or only[name]) then
            bct_mode(name, cls, on and 'pause on' or 'pause off', on and 'pause' or 'unpause', nil, true)
        end
    end
end

-- The group's tank: the Main Tank role if someone holds it, else the Main Assist if it
-- is a tank class, else the first tank class in the group (us first). nil if none.
START.TANK_CLASS = { WAR=true, PAL=true, SHD=true }
local function start_group_tank()
    local mt = mq.TLO.Group.MainTank()
    if mt and mt ~= '' then return mt end
    local ma = mq.TLO.Group.MainAssist()
    for i = 0, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        if m.Name() == ma and START.TANK_CLASS[m.Class.ShortName() or ''] then return ma end
    end
    for i = 0, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        if START.TANK_CLASS[m.Class.ShortName() or ''] then return m.Name() end
    end
    return nil
end

-- The tank made MT + MA if it is not already. Roles can only be set by the group leader:
-- sent to it if not us. False if there is no tank or the roles did not take.
local function start_group_roles()
    local tank = start_group_tank()
    if not tank then
        announce_g('Start: no tank class in the group -- set MT/MA by hand, then start again')
        return false
    end
    local leader = mq.TLO.Group.Leader()
    local function role(n)
        if leader == def.name then mq.cmdf("/grouproles set %s %d", tank, n)
        elseif leader then bct(leader, "/grouproles set %s %d", tank, n) end
    end
    if mq.TLO.Group.MainTank() ~= tank then role(1) end
    if mq.TLO.Group.MainAssist() ~= tank then role(2) end
    mq.delay(2000, function()
        return mq.TLO.Group.MainTank() == tank and mq.TLO.Group.MainAssist() == tank
    end)
    if mq.TLO.Group.MainAssist() ~= tank then
        announce_g('Start: could not make %s MT/MA (leader %s) -- set the roles by hand', tank, tostring(leader))
        return false
    end
    announce('Start: %s is MT and MA', tank)
    return true
end

-- Group check before a start: grouped, and every member online, in the zone with us and
-- alive -- outside, also gathered at the giver (within START.GATHER of us). Lists what
-- is wrong; false if anything is.
START.GATHER = 150
START.ZONEIN_VALID = 300   -- s a start's zone-in mark lasts (event_zoned)
local function start_validate(outside)
    local n = mq.TLO.Group.Members() or 0
    if n == 0 then
        announce_g('Start: not in a group')
        return false
    end
    local bad = {}
    for i = 1, n do
        local m = mq.TLO.Group.Member(i)
        local name = m.Name() or ('member '..i)
        local d = m.Spawn.Distance() or math.huge
        if m.Offline() then bad[#bad + 1] = name..' offline'
        elseif m.OtherZone() or (m.Spawn.ID() or 0) == 0 then bad[#bad + 1] = name..' not in zone'
        elseif m.Spawn.Dead() then bad[#bad + 1] = name..' dead'
        elseif outside and d > START.GATHER then bad[#bad + 1] = string.format('%s %.0f away', name, d) end
    end
    if #bad == 0 then return true end
    announce_g('Start: group not ready -- %s', table.concat(bad, ', '))
    return false
end

-- Before the hail: everyone visible, the MA in SicTank (not Vorpal) and the rest in Chase.
-- noauto, so the plugins' own auto mode switching leaves them there.
local function start_group_modes()
    local ma = mq.TLO.Group.MainAssist()
    local reach = Core.reachable_names()   -- an outside player sets their own
    for i = 0, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        local name, cls = m.Name(), m.Class.ShortName()
        if name and cls and not m.Mercenary() and reach[name:lower()] then
            local mode = (name == ma) and 7 or 2   -- 7 SicTank, 2 Chase
            if name == def.name then
                mq.cmd("/makemevisible")
                cwtn('mode '..mode..' noauto')
            else
                bct_np(name, IF_INGAME.."/makemevisible")
                -- Boxr: the MA camps (nobody to chase), the rest chase
                bct_mode(name, cls, 'mode '..mode..' noauto', mode == 7 and 'camp' or 'chase', nil, true)
            end
        end
    end
    mq.delay(500)
end

local function start_group_zone_in()
    local giver = start_giver()
    if not giver() then
        announce_g('Start: no mission giver within %d -- group not told to zone in', START.GIVER_RADIUS)
        return
    end
    local id = giver.ID()
    -- marks this as a start-driven zone-in, on every box (event_zoned unpauses on landing)
    START.zonein_at = mq.gettime()
    bcge("%s start_zonein", def.cmd)
    debug_local('Start: telling the group to say ready to %s (%d)', tostring(giver.CleanName()), id)
    start_group_pause(true)
    -- give the pause time to land: a paladin's plugin retargets itself, and a /target
    -- sent before the pause takes hold is swapped straight back
    mq.delay(1500)
    bcge_np(TARGET_IF_NEAR_INGAME, id, def.TARGET_RANGE, id)
    bcge_np(IF_INGAME.."/timed ${Math.Rand[100]} /say ready")
    announce('Start: group told to say ready to %s', tostring(giver.CleanName()))
end

-- Target the giver for a /say ready and make sure it stuck: the plugin can swap the
-- target back (a paladin's retargets itself) and the ready then goes to the wrong one.
-- Waits out the pause first. False if it never stuck.
local function target_for_ready(id)
    for _ = 1, 5 do
        if not safe_target(id) then break end
        mq.delay(500)
        if mq.TLO.Target.ID() == id then return true end
    end
    announce_g('Start: could not keep the mission giver targeted (on %s)', tostring(mq.TLO.Target.CleanName()))
    return false
end

-- Re-send target + ready to each straggler
START.GROUP_WAIT  = 60   -- s
START.RESEND_EVERY = 30  -- s
START.UNPAUSE_AFTER = 5  -- s after the whole party is in: the last one in may still be loading
START.SPAWN_SETTLE = 16  -- s after that before moving, for spawn locations to update (zone-in only)

local function start_zone_in()
    if in_instance_zone() then return true end
    local giver = start_giver()
    if not giver() then
        announce_g('Start: no mission giver within %d -- stand at it and start again', START.GIVER_RADIUS)
        return false
    end
    mq.delay(math.random(0, 3000))
    if in_instance_zone() then return true end   -- ported while we waited (another start ran)
    if not giver() then return false end
    START.giver_id = giver.ID()   -- for start_group_catchup, once we can no longer see it
    pause()   -- an assist-mode plugin would swap the target to the MA's
    mq.delay(1000)   -- let the pause land before targeting
    if target_for_ready(giver.ID()) then
        announce('Start: telling %s ready', tostring(giver.CleanName()))
        mq.cmd("/say ready")
    end
    -- A fresh (or slept) instance refuses entry for a while ("too dangerous to enter at
    -- the moment"), so keep saying ready until it lets us in.
    local t0, said = mq.gettime(), mq.gettime()
    while not in_instance_zone() or mq.TLO.EverQuest.GameState() ~= 'INGAME' do
        if (mq.gettime() - t0) > START.ZONE_WAIT * 1000 then
            announce_g('Start: still not in the mission after %ds', START.ZONE_WAIT)
            resume()
            return false
        end
        if (mq.gettime() - said) >= START.RESEND_EVERY * 1000 and mq.TLO.EverQuest.GameState() == 'INGAME'
                and not in_instance_zone() then
            said = mq.gettime()
            if target_for_ready(START.giver_id) then
                announce('Start: not in yet, telling %s ready again', tostring(mq.TLO.Target.CleanName()))
                mq.cmd("/say ready")
            end
        end
        mq.delay(500)
    end
    mq.delay(START.SETTLE * 1000)
    resume()
    return true
end

-- Unpause the whole group at once, each toon for its own class plugin (or MQ2Boxr).
local function start_group_unpause()
    start_group_pause(false)
end

local function start_group_catchup()
    local id = START.giver_id
    if not id then start_group_unpause() return true end
    local function missing()
        local out = {}
        for i = 1, (mq.TLO.Group.Members() or 0) do
            local m = mq.TLO.Group.Member(i)
            if m.Name() and (m.Spawn.ID() or 0) == 0 then out[#out + 1] = m.Name() end
        end
        return out
    end
    -- Unpause only once the whole party is in the zone, then all at once. A toon's spawn
    -- shows here as soon as the server places it, while its client is still loading, and
    -- a pause off sent then is lost 
    local t0, sent, due = mq.gettime(), nil, {}   -- due: name -> when to send its target + ready
    while (mq.gettime() - t0) < START.GROUP_WAIT * 1000 do
        local list = missing()
        if #list == 0 then
            mq.delay(START.UNPAUSE_AFTER * 1000)
            start_group_unpause()
            return true
        end
        if not sent or (mq.gettime() - sent) >= START.RESEND_EVERY * 1000 then
            sent = mq.gettime()
            announce_g('Start: %s not in the mission yet -- re-sending ready', table.concat(list, ', '))
            -- nav first, target once there: a straggler can be well away from the giver.
            -- Only our boxes: an outside player is waited for, not driven.
            local reach = Core.reachable_names()
            local i = 0
            for _, name in ipairs(list) do
                if reach[name:lower()] then
                    i = i + 1
                    bct_np(name, IF_INGAME.."/nav id %d distance=50 log=off", id)
                    due[name] = sent + 5000 + (i - 1) * 2000   -- 2s apart, not all at once
                end
            end
        end
        -- Sent from here, not with /timed: the receiver's distance check has to run after
        -- the nav, and a /timed line can have its ${} expanded when it is received.
        for _, name in ipairs(list) do
            if due[name] and mq.gettime() >= due[name] then
                due[name] = nil
                bct_np(name, TARGET_IF_NEAR_INGAME, id, def.TARGET_RANGE, id)
                bct_np(name, IF_INGAME.."/timed 5 /say ready")
            end
        end
        mq.delay(1000)
    end
    announce_g('Start: %s still outside after %ds -- NOT starting, %s start again once all are in',
        table.concat(missing(), ', '), START.GROUP_WAIT, def.cmd)
    start_group_unpause()   -- don't leave anyone paused, in here or out there
    return false
end

-- On Start, stop and kill xtarget trash while moving in. Return false if given up on.
START.CLEAR_MAX = 120   -- s cap on one stop
function Core.start_nav_clearing(spawn_name)
    local function hater()
        for i = 1, 20 do
            local xt = mq.TLO.Me.XTarget(i)
            if (xt.ID() or 0) ~= 0 and xt.TargetType() == 'Auto Hater'
                    and not (xt.Name() or ''):lower():find(spawn_name:lower(), 1, true)
                    and xt_sane(xt.ID()) then
                return xt.ID()
            end
        end
    end
    for _ = 1, 10 do   -- each pass: nav until done or something aggros
        mq.cmdf("/nav spawn %s", spawn_name)
        mq.delay(500)
        local tn = mq.gettime()
        while mq.TLO.Navigation.Active() and not hater() and (mq.gettime() - tn) < 60000 do mq.delay(250) end
        if not hater() then return true end
        if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
        debug_local('Start: mobs on the way in, killing them first')
        local t0 = mq.gettime()
        while hater() do
            if (mq.gettime() - t0) > START.CLEAR_MAX * 1000 then
                announce_g('Start: adds on the way in still up after %ds -- carrying on', START.CLEAR_MAX)
                return true
            end
            local id = hater()
            if mq.TLO.Target.ID() ~= id then
                safe_target(id)
                mq.delay(200)
            end
            if not mq.TLO.Me.Combat() then mq.cmd("/attack on") end
            mq.delay(250)
        end
        mq.cmd("/attack off")
    end
    return true
end

local function start_event()
    if not start_zone_in() then return end
    local m = mission()
    if m and m.start then m.start() end
end

-- Comms check before a start: every group member running sorm answers a ping with a
-- pong (bind_raid). Anyone silent is told to start it (/lua run) and pinged again; false,
-- with them named, if still silent.
START.PING_WAIT = 3    -- s for the pongs
START.LAUNCH_WAIT = 15 -- s re-pinging for a /lua run to come up
START.pongs = {}
local LUA_NAME = MOD:gsub('%.', '/')
-- Start sorm on these toons (only if in game and not zoning). Harmless if already running.
function Core.launch_sorm(names)
    for _, n in ipairs(names) do bct_np(n, IF_INGAME.."/lua run %s", LUA_NAME) end
end
local function start_comms_check()
    local boxes, outside = Core.group_boxes()
    if #outside > 0 then
        announce_g('Start: %s not on %s -- not checked, they play themselves', table.concat(outside, ', '),
            flags.USE_EQBC and 'EQBC' or 'DanNet')
    end
    START.pongs = {}   -- kept across rounds: a box that answered is not asked again
    local function silent()
        local out = {}
        for _, n in ipairs(boxes) do
            if not START.pongs[n:lower()] then out[#out + 1] = n end
        end
        return out
    end
    -- Each still-silent box by name. The receiver runs it only if its sorm is up: a box
    -- without it would print "Couldn't parse '/sorm ping'" on every round.
    local function ping(list)
        for _, n in ipairs(list) do
            bct_np(n, "/if (${Lua.Script[%s].Status.Equal[RUNNING]}) %s ping %s", LUA_NAME, def.cmd, def.name)
        end
        mq.delay(START.PING_WAIT * 1000, function() return #silent() == 0 end)
        return silent()
    end
    local out = ping(boxes)
    if #out == 0 then return true end
    announce_g('Start: no answer from %s -- starting %s there', table.concat(out, ', '), LUA_NAME)
    local launch = Core.launch_sorm
    launch(out)
    -- re-ping the silent until all answer or LAUNCH_WAIT is up: a fresh script takes a few
    -- seconds. The /lua run is re-sent to the still-silent every other round: a first one
    -- was seen to arrive and not start the script (Echo, 2026-11-11). Twice is harmless.
    local t0, round = mq.gettime(), 0
    repeat
        mq.delay(1000)
        out = ping(out)
        round = round + 1
        if #out > 0 and round % 2 == 0 then launch(out) end
    until #out == 0 or (mq.gettime() - t0) >= START.LAUNCH_WAIT * 1000
    if #out == 0 then
        announce('Start: whole group now running sorm')
        return true
    end
    announce_g('Start: %s not running sorm (or not on DanNet/EQBC) -- /lua run %s there, then start again',
        table.concat(out, ', '), LUA_NAME)
    return false
end

-- The MA's group-wide settings to the rest of the group, once everyone runs sorm: a box
-- whose sorm the comms check just launched has the defaults, and anything set before it
-- ran (/sorm illusion skel) never reached it.
local function start_push_settings()
    bcge("%s burn %s", def.cmd, flags.BURN_MODE and 'on' or 'off')
    local m = mission()
    for _, c in ipairs(m and m.sync and m.sync() or {}) do bcge("%s %s", def.cmd, c) end
end

-- /sorm start: comms check, roles and group check, then the MA runs it -- started on
-- anyone else it is handed to the MA, since the group Chases the MA, not us. The group
-- is set to Chase noauto and the MA to SicTank. From outside the mission the whole group
-- has to say ready, not just us. Inside, the group is unpaused before the hail. One
-- start at a time: a second click while the first is still zoning would say ready again
-- on landing.
local function run_start()
    START.queued = false
    if START.busy then printf('start already running') return end
    local m = mission()
    if m and m.can_start and not m.can_start() then return end
    START.busy = true
    local outside = not in_instance_zone()
    if not (start_comms_check() and start_group_roles() and start_validate(outside)) then
        START.busy = false
        return
    end
    local ma = mq.TLO.Group.MainAssist()
    if ma ~= def.name then
        announce('Start: handing the start to the MA, %s', tostring(ma))
        bct(ma, "%s start", def.cmd)
        START.busy = false
        return
    end
    start_push_settings()
    -- Everyone's mode out here, put back when the mission ends (Core.mission_complete).
    -- The group records its own on 'savemode'; the pause lets that land before the mode
    -- changes below reach their plugins.
    if outside then
        START.saved_mode = get_cwtn_mode()
        debug_local('Start: mode outside was %s', tostring(START.saved_mode))
        bcge("%s savemode", def.cmd)
        mq.delay(1500)
    end
    start_group_modes()
    if outside then start_group_zone_in() end
    -- Everyone visible, first thing inside: invis put up outside or on the way in would
    -- carry into the event (seen live 2026-11-11, Waxwork's first add wave with invis on)
    local function group_visible()
        mq.cmd("/makemevisible")
        bcge_np(IF_INGAME.."/makemevisible")
    end
    local ok, err = pcall(function()
        if not outside then group_visible() end
        if outside then
            if not start_zone_in() then start_group_pause(false) return end
            if not start_group_catchup() then return end
            group_visible()
            -- unpaused for the wait, not after it: the plugins refresh buffs meanwhile
            start_group_unpause()
            resume()
            announce('Start: group all in and unpaused, %ds for client control and buffs', START.SPAWN_SETTLE)
            mq.delay(START.SPAWN_SETTLE * 1000)
        end
        -- everyone unpaused before the hail
        start_group_unpause()
        resume()
        mq.delay(1000)
        START.started = mq.TLO.Zone.ShortName()   -- until we leave this zone (Main clears it)
        start_event()
        local mode = get_cwtn_mode() or ''
        if mq.TLO.Group.MainAssist() == def.name and (mode:find('Sic') or mode == 'Camp') then
            cwtn("resetcamp")
        end
    end)
    if not ok and outside then start_group_pause(false) end
    START.busy = false
    if not ok then printf('start failed: %s', tostring(err)) end
end

-- ============================================================
-- Events and commands
-- ============================================================

local function event_zoned(line,arg1,arg2)
    burn_st.active = false
    burn_st.known = {}
    for _, m in pairs(missions) do
        if m.reset then m.reset() end
    end
    if arg2 ~= nil then
        State.current_task = read_task()
        if arg2~=State.current_task then debug_local('current_task: %s arg2: %s',State.current_task,arg2) end
    end
    -- Landed in a mission on a start's zone-in: unpause ourselves after a settle (a pause
    -- off while the client is still loading is lost), so a toon the start paused comes
    -- back even if the group unpause missed it. Only after a start (START.zonein_at, set
    -- by the start's 'start_zonein' push), so a toon paused by hand stays paused. A CWTN
    -- plugin only if it is paused: an unneeded resume would resetcamp a SicTank MA.
    local started = START.zonein_at and (mq.gettime() - START.zonein_at) < START.ZONEIN_VALID * 1000
    if in_instance_zone() and started then
        START.zonein_at = nil
        Core.defer(function()
            mq.delay(START.SETTLE * 1000)
            local ok, paused = pcall(function() return mq.TLO.CWTN.Paused() end)
            if isclass_plugin_loaded() and not (ok and paused) then return end
            announce('In the mission: unpausing')
            resume()
        end)
    end
end
local function event_assigned(line,arg1)
    if arg1 ~= nil then
        State.current_task = read_task()
        if arg1~=State.current_task then debug_local('current_task: %s arg2: %s',State.current_task,arg1) end
    end
end

-- Missions in a fixed order, for usage and command lookup
local function each_mission()
    local i = 0
    return function()
        i = i + 1
        local name = MISSION_MODULES[i]
        return name and require(MOD..'.'..name)
    end
end

local function usage()
    local c = def.cmd
    print('USAGE:')
    printf('  %s ma                       --> toggle MA mode (picks targets by kill order)', c)
    printf('  %s start                    --> start the current mission (outside it: the whole group zones in first)', c)
    print('                                  runs the whole mission: stay at the keyboard and watch it')
    printf('  %s debug [on|off]           --> set debug output (no argument toggles)', c)
    printf('  %s pause [on|off]           --> pause this toon\'s script (no checks, events dropped)', c)
    print('  Shar\'Drahn / Colossus:')
    printf('  %s burn [on|off|now|reset]  --> burn mode: burn at the first storm call / add spawn,', c)
    print('                                  then the MA fights only the boss')
    for m in each_mission() do
        if m.usage then m.usage(c) end
    end
    print('  General:')
    printf('  %s set_use_eqbc on|off      --> group broadcasts over EQBC (off = DanNet)', c)
    printf('  Now: MA %s, %s', tostring(flags.MA_MODE), flags.USE_EQBC and 'EQBC' or 'DanNet')
end

local function bind_raid(...)
    local args = {...}
    local key = args[1]
    local value = args[2]
    if not key or key == 'help' then
        usage()
    elseif (key == 'pause') then
        flags.PAUSED = bool_arg(value, flags.PAUSED)
        printf('sorm %s', flags.PAUSED and 'PAUSED' or 'resumed')
    elseif (key == 'start') then
        -- Guarded here, not just in run_start: a second start that arrives while the first
        -- runs would queue and run straight after it. Once a mission is started in this
        -- zone, only 'start force' runs it again.
        if START.busy or START.queued then
            printf('start already running')
        elseif START.started == mq.TLO.Zone.ShortName() and value ~= 'force' then
            printf('already started here -- %s start force to run it again', def.cmd)
        else
            START.queued = true
            announce('Start: requested for %s -- checking the group', tostring(State.current_task))
            Core.defer(run_start)
        end
    elseif key == 'ping' and value then   -- start's comms check: answer whoever asked
        bct_q(value, "%s pong %s", def.cmd, def.name)
    elseif key == 'pong' and value then
        START.pongs[value:lower()] = true
    elseif key == 'start_zonein' then   -- the MA's start is zoning us in (event_zoned)
        START.zonein_at = mq.gettime()
    elseif key == 'savemode' then   -- the MA's start: remember our mode outside
        START.saved_mode = get_cwtn_mode()
        debug_local('Start: mode outside was %s', tostring(START.saved_mode))
    elseif (key == 'debug') then
        if value == 'on' then def.DEBUG = true
        elseif value == 'off' then def.DEBUG = false
        else def.DEBUG = not def.DEBUG end
        printf('DEBUG set to %s',tostring(def.DEBUG))
    elseif key == 'set_use_eqbc' then
        local was = flags.USE_EQBC
        if value == 'on' then flags.USE_EQBC = true
        elseif value == 'off' then flags.USE_EQBC = false end
        if flags.USE_EQBC ~= was then printf('USE_EQBC set to %s',tostring(flags.USE_EQBC)) end
    elseif key == 'burn' then
        if value == 'now' then
            burn_st.pending = true
        elseif value == 'reset' then
            burn_st.active = false
            printf('Burn: re-armed')
        else
            flags.BURN_MODE = bool_arg(value, flags.BURN_MODE)
            printf('BURN_MODE set to %s', tostring(flags.BURN_MODE))
        end
    elseif key == 'ma' then
        flags.MA_MODE = bool_arg(value, flags.MA_MODE)
        printf('MA_MODE set to %s',tostring(flags.MA_MODE))
    else
        -- a mission's own command; they answer whatever mission we are in
        for m in each_mission() do
            local f = m.commands and m.commands[key]
            if f then f(value, args) return end
        end
    end
end

-- ============================================================
-- UI
-- ============================================================

local COLOR = {}
Core.COLOR = COLOR

-- "Label: [ON]/[OFF]"
function Core.status_flag(label, on)
    ImGui.Text(label)
    ImGui.SameLine()
    if on then ImGui.TextColored(COLOR.GREEN, '[ON]') else ImGui.TextColored(COLOR.GREY, '[OFF]') end
end

-- One button that flips a flag; the label is the action a click performs, and '###id'
function Core.toggle_button(id, value, off_label, on_label)
    if ImGui.Button((value and (on_label or 'Disable') or (off_label or 'Enable'))..'###'..id) then
        value = not value
    end
    return value
end

-- Burn mode row, for the missions with a BURN entry. trigger_label names what starts it;
-- holding: the mission has the MA standing down (shown instead of the kill-order note).
-- Group-wide, unlike the other toggles: every toon has to burn, not just this one.
function Core.burn_row(trigger_label, holding)
    Core.status_flag('Burn Mode (group):', flags.BURN_MODE)
    ImGui.SameLine()
    if ImGui.Button((flags.BURN_MODE and 'Disable' or 'Enable')..'###burn') then
        bcg("%s burn %s", def.cmd, flags.BURN_MODE and 'off' or 'on')
    end
    ImGui.SameLine()
    if burn_st.active then ImGui.TextColored(COLOR.AMBER, 'BURNING - boss only')
    elseif flags.BURN_MODE then ImGui.TextDisabled('Burn @: '..trigger_label)
    elseif holding then ImGui.TextColored(COLOR.AMBER, 'MA holding for Storm Call')
    else ImGui.TextDisabled('adds killed in order') end
    if ImGui.Button('Burn Now##burn') then bcg("%s burn now", def.cmd) end
    ImGui.SameLine()
    if ImGui.Button('Reset##burn') then bcg("%s burn reset", def.cmd) end
end

local function ui()
    if not State.OPENGUI then return end   -- closed: Main sees it and ends the script
    if mq.TLO.EverQuest.GameState() ~= 'INGAME' then return end   -- hidden at char select / zoning
    if not COLOR.GREEN then
        COLOR.GREEN = ImVec4(0.3, 1, 0.3, 1)
        COLOR.GREY  = ImVec4(0.6, 0.6, 0.6, 1)
        COLOR.AMBER = ImVec4(1, 0.7, 0.1, 1)
        COLOR.RED   = ImVec4(1, 0.2, 0.2, 1)
    end
    State.OPENGUI, State.DRAWGUI = ImGui.Begin('SoR Missions', State.OPENGUI)
    if not State.DRAWGUI then ImGui.End() return end

    ImGui.Text('Mission:')
    ImGui.SameLine()
    local m = mission()
    if m then ImGui.TextColored(COLOR.GREEN, State.current_task)
    else ImGui.TextColored(COLOR.GREY, tostring(State.current_task or 'None')) end
    if m then
        ImGui.SameLine()
        if START.busy or START.queued then
            ImGui.TextColored(COLOR.AMBER, 'Starting...')
        elseif START.started == mq.TLO.Zone.ShortName() then
            ImGui.TextColored(COLOR.GREEN, 'Started')
        elseif ImGui.Button('Start Event') then
            mq.cmdf("%s start", def.cmd)
        end
    end

    ImGui.Separator()
    Core.status_flag('MA Mode:', flags.MA_MODE)
    ImGui.SameLine()
    flags.MA_MODE = Core.toggle_button('ma', flags.MA_MODE)
    ImGui.SameLine()
    ImGui.Text('  ')
    ImGui.SameLine()
    -- '/sorm pause' rather than flipping the flag here, so it prints the same as the command
    if ImGui.Button((flags.PAUSED and 'Resume' or 'Pause') .. '###pause') then
        mq.cmdf('%s pause %s', def.cmd, flags.PAUSED and 'off' or 'on')
    end
    --ImGui.SameLine()
    --if flags.PAUSED then ImGui.TextColored(COLOR.RED, 'PAUSED') else ImGui.TextColored(COLOR.GREEN, 'RUNNING') end

    if m and m.ui then
        ImGui.Separator()
        m.ui()
    end

    ImGui.Separator()
    Core.status_flag('Announce:', flags.ANNO)
    ImGui.SameLine()
    flags.ANNO = Core.toggle_button('anno', flags.ANNO)
    ImGui.SameLine()
    Core.status_flag('  Debug:', def.DEBUG)
    ImGui.SameLine()
    def.DEBUG = Core.toggle_button('dbg', def.DEBUG)
    if ImGui.RadioButton('DanNet', not flags.USE_EQBC) then
        flags.USE_EQBC = false
        bcg("%s set_use_eqbc off", def.cmd)
    end
    ImGui.SameLine()
    if ImGui.RadioButton('EQBC', flags.USE_EQBC) then
        flags.USE_EQBC = true
        bcg("%s set_use_eqbc on", def.cmd)
    end

    ImGui.End()
end

-- ============================================================
-- Init and the main loop
-- ============================================================

local function Init()
    if not check_plugins() then mq.exit() end
    -- per-toon seed: unseeded, every client draws the same "random" pulse jitter
    math.randomseed(os.time() + (mq.TLO.Me.ID() or 0))
    for m in each_mission() do
        missions[m.TASK] = m
        if m.events then m.events() end
    end
    burn_events()   -- after the missions: they fill BURN in as they load

    State.current_task = read_task()
    if mission() then
        debug_local('Current Task: %s',State.current_task)
        debug_local('Kill Order: %s',table.concat(kill_order[State.current_task] or {},', '))
    else
        debug_local('No current mission')
    end

    mq.event('zoned', '#*#You have entered #1#:#2#.', event_zoned)
    mq.event('assigned', '#*#You have been assigned the task \'#1#\'.', event_assigned)

    mq.bind(def.cmd, bind_raid)
    check_eqbc_default()
    mq.imgui.init('SoR Missions', ui)
end

-- Mission done (boss step passed, or a mission's own kill event), on every toon: back to
-- the mode we had outside when the start began (START.saved_mode). Nothing recorded (a
-- start run from inside): the MA goes to Manual, so SicTank does not run off after
-- anything else, and the rest are left as they are. Once per kill: both can fire for one.
local completed_at = 0
function Core.mission_complete()
    if mq.gettime() - completed_at < 60000 then return end
    completed_at = mq.gettime()
    local m = START.saved_mode
    START.saved_mode = nil
    local is_ma = mq.TLO.Group.MainAssist() == def.name
    if not m then
        if is_ma then
            cwtn('mode 0')
            announce('Mission complete: MA set to Manual')
        end
    elseif m == 'Manual' or m == 'none' then
        cwtn('mode 0')
        announce('Mission complete: back to Manual')
    elseif Core.MODE_NUM[(tostring(m):gsub(' ', ''))] then
        set_mode(m)
        announce('Mission complete: back to %s', tostring(m))
    else
        if is_ma then cwtn('mode 0') end
        announce_g('Mission complete: could not restore mode "%s"%s', tostring(m), is_ma and ' -- MA set to Manual' or '')
    end
end

local function Main()
    local was_group_ma = nil   -- nil: the first pulse always applies the role
    local was_task = nil
    local was_step = nil      -- last task step, to see the boss step move on

    while State.OPENGUI do   -- closing the window ends the script
        -- queued command work, paused or not: it was asked for by hand
        while #deferred > 0 do table.remove(deferred, 1)() end
        -- left the zone a start ran in: a new instance can be started again
        if START.started and START.started ~= mq.TLO.Zone.ShortName() then START.started = nil end
        if flags.PAUSED then
            mq.flushevents()   -- drop what was heard while paused, so nothing fires late
            mq.delay(def.pulse)
        else
            State.current_task = read_task()
            local m = mission()
            -- Boss death from the task, not the spawn: the Abolishion despawns every wave.
            local step = State.current_task ~= 'None' and mq.TLO.Task(State.current_task).Step() or nil
            if step and step ~= '' and step ~= was_step then
                local boss = was_step and was_step:match('^Defeat (.+)$')
                if boss and not (m and m.own_kill_announce) then
                    announce('%s dead, Mission Complete!', (boss:gsub('^the ', '')))
                end
                if boss then Core.mission_complete() end
                was_step = step
            end
            -- Only run inside one of this script's missions. Out of them -- another zone's
            -- task, or none -- nothing but events runs, so MA does not take over targeting outside
            local in_task = m ~= nil
            if State.current_task ~= was_task then
                was_task = State.current_task
                announce('Task "%s": %s', tostring(State.current_task), in_task and 'active' or 'not one of ours, idle')
                if not in_task then reset_engage() end
                if m and m.enter then m.enter() end
            end
            -- MA mode follows the group's Main Assist role.
            local is_ma = mq.TLO.Group.MainAssist() == def.name
            if is_ma ~= was_group_ma then
                was_group_ma = is_ma
                flags.MA_MODE = is_ma
                announce('%s group MA: MA mode %s', is_ma and 'Now' or 'No longer', is_ma and 'on' or 'off')
                if m and m.ma_changed then m.ma_changed(is_ma) end
            end
            if m and m.pre_pulse then m.pre_pulse() end
            if in_task and flags.MA_MODE and not (m.hold and m.hold()) then
                pick_target()
                BOXR_RG.close_in()   -- RGMercs MA only: walk in to a target out of reach
            end
            mq.doevents()   -- always: the zone/task events are what set current_task

            if in_task then
                check_burn()
                if m.pulse then m.pulse() end
            end

            -- jittered so the toons do not all pulse in step
            mq.delay(def.pulse + math.random(0, 150))
        end
    end
end

Init()
Main()
