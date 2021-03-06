-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--- you can use this to turn of Just In Time compilation for debugging purposes:
--jit.off()
vmType = 'game'

package.path = 'lua/ge/?.lua;lua/gui/?.lua;lua/common/?.lua;lua/common/libs/?/init.lua;lua/common/libs/luasocket/?.lua;lua/?.lua;?.lua'
package.cpath = ''
require('luaCore')

require_optional('replayInterpolation')

log = function(...) Lua:log(...) end
print = function(...)
  local args = { n = select("#", ...), ... }
  local s_args = {}
  for i = 1, args.n do
    table.insert(s_args, tostring(args[i]))
  end
  Lua:log('A', "print", table.concat(s_args, ', '))
  -- if you want to find out, where the print was used:
  -- Lua:log('A', "print", debug.traceback())
end
log("I", "", "============== Game Engine Lua VM started ==============")

function getGame()
  return scenetree.findObject("Game")
end

require("utils")
require("devUtils")
require("ge_utils")
require('ge_deprecated')
require('colorF')
require("luaProfiler")
local STP = require "libs/StackTracePlus/StackTracePlus"
debug.traceback = STP.stacktrace
debug.tracesimple = STP.stacktraceSimple

json = require("json")
guihooks = require("guihooks")
screenshot = require("screenshot")
bullettime = require("bullettime")
extensions = require("extensions")
extensions.addModulePath("lua/ge/extensions/")
extensions.addModulePath("lua/common/extensions/")
map = require("map")
settings = extensions.core_settings_settings
perf = require("utils/perf")
spawn = require("spawn")
setSpawnpoint= require ("setSpawnpoint")
serverConnection = require("serverConnection")
server = require("server/server")
commands = require("server/commands")
editor = {}
worldReadyState = -1 -- tracks if the level loading is done yet: 0 = no, 1 = yes, load play ui, 2 = all done

gdcdemo = nil -- demo mode disabled
sailingTheHighSeas = the_high_sea_crap_detector()


-- how to log into a json file:
--globalJsonLog = LogSink()
--globalJsonLog:open('/gamelog.json')

--[[
-- function to trace the memory usage
local maxMemUsage = 0
local function trace_mem(event, line)
  local s = debug.getinfo(2)
  local m, _ = gcinfo()
  if m > maxMemUsage then
    maxMemUsage = m
  end
  Lua:log('D', 'luaperf', tostring(event) .. ' = ' .. tostring(s.what) .. '_' .. tostring(s.source) .. ':' .. tostring(s.linedefined) .. ' / memory usage: ' .. tostring(m) .. ' (max: ' .. tostring(maxMemUsage) .. ')')
end
debug.sethook(trace_mem, "c")
--]]

--[[
gdcdemo = {
  start = function()
      campaign_campaigns.startByFolder('campaigns/gdc_2017', gdcdemo.startCampaign)
  end
}
]]

local ffi = require("ffi")

math.randomseed(os.time())
local cmdArgs = Engine.getStartingArgs()

--Lua:enableStackTraceFile("lua.ge.stack.txt", true)

logAlways=print

if tableFindKey(cmdArgs, '-luadebug') then
  startDebugger()
end
local _isSafeMode = tableFindKey(cmdArgs, '-safemode')
function isSafeMode()
  return _isSafeMode
end

-- immediate command line arguments
-- worked off before anything else
-- called when the world is init'ed
local function handleCommandLineFirstFrame()
  if tableFindKey(cmdArgs, '-flowgraph') then
    if getMissionFilename() == "" then
      freeroam_freeroam.startFreeroam("levels/smallgrid/main.level.json")
      extensions.load('editor_flowgraphEditor')
      editor_flowgraphEditor.requestedEditor = true
      --core_levels.startLevel("levels/smallgrid/main.level.json")
    end
  end

  if tableFindKey(cmdArgs, '-resaveMaterials') then

    -- first: find levels
    TorqueScript.exec("core/art/datablocks/datablockExec.cs")

    local function resaveTSFiles(pattern, fnSuffix)
      local filenames = FS:findFiles('/', pattern, -1, true, false)
      dump(filenames)
      for _, fn in pairs(filenames) do
        local dir, filename, ext = path.split(fn)
        --local outName = dir .. 'folder.material.json'
        log('I', 'resaveMaterials', 'converting ts script: ' .. tostring(fn) )
        -- record known things
        local knownObjects = scenetree.getAllObjects()
        -- convert to map
        local newKnownObjects = {}
        for k, v in pairs(knownObjects) do
          newKnownObjects[v] = 1
        end
        knownObjects = newKnownObjects

        -- load the file
        TorqueScript.exec(fn)

        -- figure out what objects were loaded from that file by diffing with the known objects above
        local knownObjects2 = scenetree.getAllObjects()
        local newObjects = {}
        for _, o in pairs(knownObjects2) do
          if not knownObjects[o] then
            table.insert(newObjects, o)
          end
        end
        dump(newObjects)

        -- get all objects in it
        for _, oName in pairs(newObjects) do
          local obj = scenetree.findObject(oName)
          if obj then
            local s = obj:serialize(true, -1)
            s = string.gsub(s,'%s+$','') -- trim right

            -- save every object on its own
            local outName = dir .. obj.name ..  fnSuffix
            print(outName)
            writeFile(outName, s)
            --obj:delete()
          end
        end
      end
    end

    resaveTSFiles('material.cs', '.material.json')
    resaveTSFiles('*Data.cs', '.datablock.json')
    log('I', 'resaveMaterials', 'all done, exiting gracefully')
    shutdown(0)

  elseif tableFindKey(cmdArgs, '-deps') then
    extensions.util_dependencyTree.test()
    print('done')
    shutdown(0)
  end
end

local coreModules =  {'ui_audio', 'ui_apps', 'ui_uiControl', 'scenario_scenariosLoader', 'campaign_campaignsLoader', 'freeroam_freeroam', 'core_levels',
                        'scenario_quickRaceLoader', 'core_highscores', 'core_replay', 'core_vehicles', 'core_vehicle_colors', 'core_settings_settings', 'core_settings_graphic',
                        'core_jobsystem', 'core_modmanager', 'core_hardwareinfo',
                        'core_commandhandler', 'core_remoteController', 'core_gamestate', 'core_online',
                        'core_paths', 'util_creatorMode', 'core_sounds', 'core_audio', 'ui_imgui', 'core_environment',
                        'core_inventory', 'core_terrain', 'editor_main', 'trackbuilder_trackBuilder', 'core_input_actions', 'core_input_bindings', 'core_input_virtualInput',
                        'core_settings_audio', 'core_settings_gameplay', 'core_input_categories', 'core_input_deprecatedActions', 'core_multiseat',
                        'core_quickAccess', 'core_camera', "core_input_actionFilter",
                        'ui_flowgraph_editor', 'core_flowgraphManager', 'core_vehicle_manager'
                    }
                    -- , 'ui_external' --needed for external ui

local sharedModules = { 'core_groundMarkers', 'core_weather',
                        'core_trailerRespawn', 'util_richPresence',
                        'core_prefabLogic', 'core_checkpoints', 'core_collectables',
                        'gameplay_traffic', 'core_multiSpawn'}

local extraUserRequestedExtensions = {}

function loadCoreExtensions()
  extensions.load(coreModules)
end

function loadGameModeModules(...)
  extensions.unloadExcept(coreModules)
  extensions.load(sharedModules, extraUserRequestedExtensions, ...)
  extraUserRequestedExtensions = {}
  extensions.hookExcept(coreModules, 'onInit')
end

function unloadGameModules()
  extensions.unloadExcept(coreModules)
end

function registerCoreModule(modulePath)
  local moduleExtName = extensions.luaPathToExtName(modulePath)
  for _, modExtName in ipairs(coreModules) do
    if modExtName == moduleExtName then return end
  end
  table.insert(coreModules, moduleExtName)
end

function endActiveGameMode(callback)
  local endCallback = function ()
    unloadGameModules()

    if type(callback) == 'function' then
      callback()
    end
  end
  -- NOTE: We have to use a callback to serverConnection.disconnect because is it updated in a
  --       State machine
  serverConnection.disconnect(endCallback)
end

function queueExtensionToLoad(modulePath)
  -- log('I', 'main', "queueExtensionToLoad called...."..modulePath)
  table.insert(extraUserRequestedExtensions, modulePath)
end

-- called before the Mission Resources are loaded
function clientPreStartMission(mission)
  worldReadyState = 0
  extensions.hook('onClientPreStartMission', mission)
  guihooks.trigger('PreStartMission')
  core_vehicles.loadDefaultVehicle()
end

-- called when level, car etc. are completely loaded (after clientPreStartMission)
function clientPostStartMission(mission)
  --default game state, will get overriden by each mode
  core_gamestate.setGameState('freeroam', 'freeroam', 'freeroam')
  extensions.hook('onClientPostStartMission', mission)
end

-- called when the level items are already loaded (after clientPostStartMission)
function clientStartMission(mission)
  log("D", "clientStartMission", "starting mission: " .. tostring(mission))
  extensions.hookNotify('onClientStartMission', mission)
  map.assureLoad() --> needs to be after extensions.hook('onClientStartMission', mission)
  guihooks.trigger('MenuHide')
 -- SteamLicensePlateVehicleId = nil
end

function clientEndMission(mission)
  -- core_gamestate.requestGameState()
  -- log("D", "clientEndMission", "ending mission: " .. tostring(mission))
  be:physicsStopSimulation()
  bullettime.pause(false)
  extensions.hookNotify('onClientEndMission', mission)
end

function returnToMainMenu()
  endActiveGameMode()
end

function onEditorEnabled(enabled)
  --print('onEditorEnabled', enabled)
  extensions.hook('onEditorEnabled', enabled)
  map.setEditorState(enabled)
end

local luaPreRenderMaterialCheckDuration = 0

-- called from c++ side whenever a performance check log is wanted
local geluaProfiler
function requestGeluaProfile()
  geluaProfiler = LuaProfiler("update() and luaPreRender() gelua function calls")
  extensions.setProfiler(geluaProfiler)
end
-- this function is called right before the rendering, and after running the physics
function luaPreRender(dtReal, dtSim, dtRaw)
  if geluaProfiler then geluaProfiler:start() end
  local updateUIData = true -- only update UI data
  map.updateGFX(dtReal)
  if geluaProfiler then geluaProfiler:add("luaPreRender map update") end
  extensions.hook('onPreRender', dtReal, dtSim, dtRaw)
  if geluaProfiler then geluaProfiler:add("luaPreRender extensions") end
  extensions.hook('onDrawDebug', Lua.lastDebugFocusPos, dtReal, dtSim, dtRaw)
  if geluaProfiler then geluaProfiler:add("luaPreRender drawdebug") end

  -- will be used for ge streams later
  -- guihooks.frameUpdated(dtReal)

  -- detect if we need to switch the UI around
  if worldReadyState == 1 then
    -- log('I', 'gamestate', 'Checking if vehicle is done rendering material') -- this is far too verbose and seriously slows down the debugging
    luaPreRenderMaterialCheckDuration = luaPreRenderMaterialCheckDuration + dtRaw
    local pv = be:getPlayerVehicle(0)
    local allReady = (not pv) or (pv and pv:isRenderMaterialsReady())
    if allReady or luaPreRenderMaterialCheckDuration > 5 then
      log('D', 'gamestate', 'Checking material finished loading')
      core_gamestate.requestExitLoadingScreen('worldReadyState')
      -- switch the UI to play mode
      -- be:executeJS("HookManager.trigger('ChangeState', 'menu', ['loading', 'backgroundImage.mainmenu']);")
      worldReadyState = 2
      luaPreRenderMaterialCheckDuration = 0
      extensions.hook('onWorldReadyState', worldReadyState)
    end
  end
  if geluaProfiler then geluaProfiler:add("luaPreRender ending") end
  if geluaProfiler then
    geluaProfiler:finish(true)
    geluaProfiler = nil
    extensions.setProfiler(geluaProfiler)
  end
end

gAutoHideDashboard = false -- when enabled, it is not working correctly for some reason...
local lastTimeSinceLastMouseMoved = 0
local lastTimeSinceLastRadialMoved = 0 -- for radial menu app (moved by gamepad usually)

function updateFirstFrame()
  -- completeIntegrityChunk("base") -- unused for now

  bullettime.init()
  extensions.hook('onFirstUpdate')

  -- make sure the editing tools are in the correct state
  onEditorEnabled(Engine.getEditorEnabled())

  if gdcdemo then
    gdcdemo.start()
  end
  handleCommandLineFirstFrame()
end

-- this function is called after input and before physics
function update(dtReal, dtSim, dtRaw)
  if geluaProfiler then geluaProfiler:start() end
  --local used_memory_bytes, _ = gcinfo()
  --log('D', "update", "Lua memory usage: " .. tostring(used_memory_bytes/1024) .. "kB")

  debugPoll()

  extensions.core_input_bindings.updateGFX(dtRaw)
  bullettime.update(dtReal)
  screenshot.updateGFX()
  if geluaProfiler then geluaProfiler:add("update beginning") end

  extensions.hook('onUpdate', dtReal, dtSim, dtRaw)
  if geluaProfiler then geluaProfiler:add("update extensions") end
  perf.update()

  local timeSinceLastMouse = Engine.Platform.getRealMilliseconds() - getMovedMouseLastTimeMs()
  if timeSinceLastMouse - lastTimeSinceLastMouseMoved < 0 then
    guihooks.trigger('MenuFocusShow', false)
  end
  lastTimeSinceLastMouseMoved = timeSinceLastMouse

  if core_quickAccess then
    local timeSinceLastRadial = Engine.Platform.getRealMilliseconds() - core_quickAccess.getMovedRadialLastTimeMs()
    if timeSinceLastRadial - lastTimeSinceLastRadialMoved < 0 then
      guihooks.trigger('MenuFocusShow', false)
    end
    lastTimeSinceLastRadialMoved = timeSinceLastRadial
  end

  if gAutoHideDashboard and extensions.core_input_bindings.isMenuActive and ((Engine.Platform.getRealMilliseconds() - getCEFFocusMouseLastTimeMs()) > 30000) then
    guihooks.trigger('MenuHide')
  end
  if geluaProfiler then geluaProfiler:add("update ending") end
end

-- called when the UI is up and running
function uiReady()
  extensions.hook('onUiReady')
end

-- Called on reload (Control-L)
function init()
  settings.initSettings()
  guihooks.trigger("EngineLuaReloaded")
  --log('D', "init", 'GameEngine Lua (re)loaded')
  flowGraphEditor_ffi_cdef_loaded = false

  -- be sensitive about global writes from now on
  detectGlobalWrites()

  extensions.load(coreModules)
  extraUserRequestedExtensions = {}

  core_online.openSession() -- try to connect to online services

  -- import state last
  importPersistentData()

  -- request the UI ready state
  if be then
    be:executeJS('HookManager.trigger("isUIReady")')
  end

  map.assureLoad()

  -- world ready to do sth
  worldReadyState = 0

  -- put the mods folder in clear view, so users don't put stuff in the wrong place
  if not FS:directoryExists("mods") then FS:directoryCreate("mods") end

  if not FS:directoryExists("trackEditor") or not string.startswith(FS:getFileRealPath("trackEditor"), getUserPath())  then FS:directoryCreate("trackEditor") end
  extensions.hook('onAfterLuaReload')
end

function onBeamNGWaypoint(args)
  map.onWaypoint(args)
  extensions.hook('onBeamNGWaypoint', args)
end

-- do not delete - this is the default function name for the BeamNGTrigger from the c++ side
function onBeamNGTrigger(data)
  extensions.hook('onBeamNGTrigger', data)
end

function onFileChanged(t)
  --print("onFileChanged: " .. dumps(t))
  for k,v in pairs(t) do
    --print("onFileChanged: " .. tostring(v.filename) .. ' : ' .. tostring(v.type))
    settings.onFileChanged(v.filename, v.type)
    map.onFileChanged(v.filename, v.type)
    extensions.hook('onFileChanged', v.filename, v.type)
  end
  extensions.hook('onFileChangedEnd')
end

function physicsEngineEvent(...)
  local args = unpack({...})
  extensions.hook('onPhysicsEngineEvent', args)
end

function vehicleSpawned(vid)
  local v = be:getObjectByID(vid)
  if not v then return end

  -- update the gravity of the vehicle
  if core_environment then
    v:queueLuaCommand("obj:setGravity(\""..core_environment.getGravity().."\")")
  end

  -- tell the vehicle to start its debugger as well
  if debugPoll ~= nop then
    v:queueLuaCommand("startDebugger()")
  end

  extensions.hook('onVehicleSpawned', vid)
end

function vehicleSwitched(oldVehicle, newVehicle, player)
  local oid = oldVehicle and oldVehicle:getID() or -1
  local nid = newVehicle and newVehicle:getID() or -1
  local oldinfo = oldVehicle and ("id "..dumps(oid).." ("..oldVehicle:getPath()..")") or dumps(oldVehicle)
  local newinfo = newVehicle and ("id "..dumps(nid).." ("..newVehicle:getPath()..")") or dumps(newVehicle)
  log('I', 'main', "Player #"..dumps(player).." vehicle switched from: "..oldinfo.." to: "..newinfo)
  extensions.hook('onVehicleSwitched', oid, nid, player)
  --Steam.setStat('meters_driven', 1)
end

function vehicleReset(vehicleID)
    extensions.hook('onVehicleResetted', vehicleID)
end

function onMouseLocked(locked)
  extensions.hook('onMouseLocked', locked)
end

function vehicleDestroyed(vid)
  extensions.hook('onVehicleDestroyed', vid)
end

function onCouplerAttached(objId1, objId2, nodeId, obj2nodeId)
  if settings.getValue("couplerCameraModifier", false) then
    local isEnabled = core_couplerCameraModifier ~= nil
    extensions.load('core_couplerCameraModifier')
    if core_couplerCameraModifier.checkForTrailer(objId1, objId2) == false and isEnabled == false then
      extensions.unload('core_couplerCameraModifier')
    end
  end
  extensions.hook('onCouplerAttached', objId1, objId2, nodeId, obj2nodeId)
end

function onCouplerDetached(objId1, objId2)
  extensions.hook('onCouplerDetached', objId1, objId2)
  if core_couplerCameraModifier ~= nil then
      extensions.unload('core_couplerCameraModifier')
  end
end

--Trigered when trailer coupler is detached by the user
function onCouplerDetach(objId, nodeId)
  extensions.hook('onCouplerDetach', objId, nodeId)
end

function onAiModeChange(vehicleID, newAiMode)
  extensions.hook('onAiModeChange', vehicleID, newAiMode)
end

function prefabLoaded(id, prefabName, prefabPath)
  --log('D', 'main', 'prefabLoaded: ' .. dumps(id)..',' ..dumps(prefabName))
  if prefabLogic then
    prefabLogic.prefabLoaded(id, prefabName, prefabPath)
  end
end

function prefabUnloaded(id, prefabName, prefabPath)
  --log('D', 'main', 'prefabUnloaded: ' .. dumps(id)..',' ..dumps(prefabName))
  if prefabLogic then
    prefabLogic.prefabUnloaded(id, prefabName, prefabPath)
  end
end

function replayStateChanged(...)
  core_replay.stateChanged(...)
end

function exportPersistentData()
  if not be then return end
  local d = serializePackages()
  -- log('D', 'main', 'persistent data exported: ' .. dumps(d))
  be.persistenceLuaData = serialize(d)
end

function importPersistentData()
  if not be then return end
  local s = be.persistenceLuaData
  -- log('D', 'main', 'persistent data imported: ' .. tostring(s))
  -- deserialize extensions first, so the extensions are loaded before they are trying to get deserialized
  local data = deserialize(s)
  -- TODO(AK): Remove this stuff post completing serialization work
  -- writeFile("ge_exportPersistentData.txt", dumps(data))
  deserializePackages(data)
end

function updatePhysicsState(val)
  be:executeJS('updatePhysicsState('..tostring(val)..')')
  if val then
    extensions.hook('onPhysicsUnpaused')
  else
    extensions.hook('onPhysicsPaused')
  end
end

function updateTranslations()
  -- unmount if in use, so we can update the file
  if FS:isMounted('mods/translations.zip') then
    FS:unmount('mods/translations.zip')
  end

  extensions.core_repository.installMod('locales.zip', 'translations.zip', 'mods/', function(data)
    log('D', 'updateTranslations', 'translations download done: mods/translations.zip')
    -- reload the settings to activate the new files
    settings.newTranslationsAvailable = true -- this enforces the UI refresh, fixes some state problems
    settings.load(true)
  end)
end

function enableCommunityTranslations()
  settings.setState( { communityTranslations = 'enable' } )
  updateTranslations()
end

-- little shortcut
function annotate()
  extensions.util_annotation.extractData()
end

function onExit()
    log('D', 'onExit', 'Exiting')
    extensions.hook('onExit')
    settings.save()
end

function onInstabilityDetected(jbeamFilename)
  bullettime.pause(true)
  log('E', "", "Instability detected for vehicle " .. tostring(jbeamFilename))
  ui_message({txt="vehicle.main.instability", context={vehicle=tostring(jbeamFilename)}}, 10, 'instability', "warning")
end

function resetGameplay(playerID)
  extensions.hook('onResetGameplay', playerID)
end
