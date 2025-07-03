local QBCore = exports['qb-core']:GetCoreObject()
local displayLeaderboard = false

local Config = {
    DespawnTime = 5 * 60 * 1000,              -- If player not in zone how long till peds respawn
    PatrolRadius = 80,                        -- Zone guards patrol radius size
    PatrolSpeed = 1.0,                        -- How fast zone guards patrol
    PatrolWait = 100000,                      -- How long zoneguards wait before chaing route/animation
    NumberOfGuards = 30,                      -- Number of guards per zone
    VehicleRespawnDelay = 120000,             -- 2 minutes
    VehicleDespawnDelay = 120000,             -- 2 minutes for despawn after all peds dead
    VehicleStuckCheckInterval = 60000,        -- 60 seconds to check if vehicle is stuck
    VehicleStuckDistance = 4.0,               -- Max distance to consider vehicle stuck
}

local zoneGuards = {}                         -- Table for zone guards
local zoneBlips = {}                          -- Table for zone blips
local zoneVehicles = {}                       -- Table to track zone vehicles
local vehiclesToRespawn = {}                  -- Table to track vehicles to respawn
local vehiclesToDespawn = {}                  -- Table to track vehicles to despawn

local Zones = {
    {
        name = "Ballas Turf",
        points = {
            vector2(-174.4, -1777.59),
            vector2(127.28, -2027.53),
            vector2(248.48, -1845.03),
            vector2(-32.49, -1603.78),
        },
        gangPedGroup = GetHashKey("AMBIENT_GANG_BALLAS"),
        ownerGang = "ballas"
    },
    {
        name = "Families Turf",
        points = {
            vector2(-171.88, -1787.21),
            vector2(-324.22, -1647.93),
            vector2(-248.22, -1417.49),
            vector2(-23.13, -1610.05),
        },
        gangPedGroup = GetHashKey("AMBIENT_GANG_FAMILY"),
        ownerGang = "families"
    }
}

function SetLeaderboardVisible(visible, tab)
    displayLeaderboard = visible
    SetNuiFocus(visible, visible)
    SendNUIMessage({
        action = visible and "show" or "hide",
        tab = tab or "main"
    })
end

RegisterCommand("leaderboard", function()
    TriggerServerEvent("gangs:getLeaderboardData")
end)

RegisterNUICallback("close", function(_, cb)
    SetLeaderboardVisible(false)
    cb("ok")
end)

RegisterNetEvent("gangs:sendLeaderboardData", function(data)
    if not displayLeaderboard then
        SetLeaderboardVisible(true, "main")
    end
    SendNUIMessage({
        action = "updateLeaderboard",
        leaderboard = data
    })
end)

local function IsPointInPolygon(pt, poly)
    local x, y = pt.x, pt.y
    local inside, j = false, #poly
    for i = 1, #poly do
        local xi, yi = poly[i].x, poly[i].y
        local xj, yj = poly[j].x, poly[j].y
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

local function GetPedModelFromGroup(group)
    if group == GetHashKey("AMBIENT_GANG_BALLAS") then
        return `g_m_y_ballaeast_01`
    elseif group == GetHashKey("AMBIENT_GANG_FAMILY") then
        return `g_m_y_famfor_01`
    end
    return `g_m_y_mexgang_01`
end

local function CalculateCentroid(points)
    local x, y = 0, 0
    for _, point in ipairs(points) do
        x = x + point.x
        y = y + point.y
    end
    return vector3(x / #points, y / #points, 0)
end

local function IsSafeCoord(x, y, z)
    local streetHash = GetStreetNameAtCoord(x, y, z)
    local onRoad = IsPointOnRoad(x, y, z, 0)
    return (streetHash ~= 0) and not onRoad
end

local function RunAway(ped, fromPos)
    if not DoesEntityExist(ped) or IsPedDeadOrDying(ped) then return end
    ClearPedTasksImmediately(ped)
    local px, py, pz = table.unpack(fromPos)
    local angle = math.random() * 2 * math.pi
    local radius = 50.0
    local destX = px + radius * math.cos(angle)
    local destY = py + radius * math.sin(angle)
    local found, groundZ = GetGroundZFor_3dCoord(destX, destY, pz + 50.0, false)
    local destZ = found and groundZ or pz
    TaskSmartFleeCoord(ped, px, py, destZ, 100.0, 0, false)
end

local function MakeGuardsFlee(zoneIndex, fromPos)
    if zoneGuards[zoneIndex] then
        for _, ped in ipairs(zoneGuards[zoneIndex]) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped) then
                RunAway(ped, fromPos)
            end
        end
        Wait(15000)
        for _, ped in ipairs(zoneGuards[zoneIndex]) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped) then
                ClearPedTasks(ped)
                PatrolPed(ped, GetEntityCoords(ped))
            end
        end
    end
end

local function PatrolPed(ped, centerPos)
    CreateThread(function()
        while DoesEntityExist(ped) and not IsEntityDead(ped) do
            local destX, destY, destZ
            local attempts = 0
            repeat
                local offsetX = (math.random() - 0.5) * 2 * Config.PatrolRadius
                local offsetY = (math.random() - 0.5) * 2 * Config.PatrolRadius
                destX = centerPos.x + offsetX
                destY = centerPos.y + offsetY
                local found, groundZ = GetGroundZFor_3dCoord(destX, destY, centerPos.z + 50.0, false)
                destZ = found and groundZ or centerPos.z
                attempts = attempts + 1
                Wait(0)
            until (IsSafeCoord(destX, destY, destZ) or attempts > 10)

            TaskGoStraightToCoord(ped, destX, destY, destZ, Config.PatrolSpeed, -1, 0.0, 0.0)
            Wait(Config.PatrolWait)
        end
    end)
end

-- Function to handle vehicle relocation, repair, and ped revival
local function RelocateAndReviveVehicle(zoneIndex, vehicleData)
    local zone = Zones[zoneIndex]
    local rivalZoneIndex = zone.ownerGang == "ballas" and 2 or 1
    local rivalZone = Zones[rivalZoneIndex]

    -- Get fixed spawn points for the gang
    local fixedSpawns = {}
    if zone.ownerGang == "ballas" then
        fixedSpawns = {
            vector4(111.81, -1945.56, 20.75, 343.5),
            vector4(-51.95, -1801.7, 27.01, 52.51),
            vector4(155.27, -1880.69, 23.62, 244.65),
            vector4(4.87, -1680.6, 29.16, 115.9)
        }
    elseif zone.ownerGang == "families" then
        fixedSpawns = {
            vector4(-179.0, -1648.73, 33.22, 0.16),
            vector4(-150.53, -1554.34, 34.73, 318.26),
            vector4(-31.86, -1469.49, 31.07, 276.76),
            vector4(17.12, -1532.85, 29.27, 195.56)
        }
    end

    -- Select a random spawn point
    local spawn = fixedSpawns[math.random(1, #fixedSpawns)]
    if not spawn then return end

    -- Teleport vehicle to spawn point
    SetEntityCoords(vehicleData.vehicle, spawn.x, spawn.y, spawn.z, false, false, false, true)
    SetEntityHeading(vehicleData.vehicle, spawn.w)
    SetVehicleOnGroundProperly(vehicleData.vehicle)

    -- Fix the vehicle
    SetVehicleFixed(vehicleData.vehicle)
    SetVehicleEngineHealth(vehicleData.vehicle, 1000.0)

    -- Revive all peds if they are dead
    for _, ped in ipairs(vehicleData.peds) do
        if DoesEntityExist(ped) and IsEntityDead(ped) then
            RESURRECT_PED(ped)
            SetEntityHealth(ped, 100)
            SetPedArmour(ped, 50)
            SetPedRelationshipGroupHash(ped, zone.gangPedGroup)
            GiveWeaponToPed(ped, `WEAPON_PISTOL`, 100, false, true)
            SetPedCanRagdollFromPlayerImpact(ped, false)
        end
    end

    -- Clear tasks for all peds
    for _, ped in ipairs(vehicleData.peds) do
        if DoesEntityExist(ped) then
            ClearPedTasks(ped)
        end
    end

    -- Reassign driver's task to rejoin gang war
    local driver = GetPedInVehicleSeat(vehicleData.vehicle, -1)
    if driver and DoesEntityExist(driver) then
        local center = CalculateCentroid(rivalZone.points)
        TaskVehicleDriveToCoordLongrange(driver, vehicleData.vehicle, center.x, center.y, center.z, 20.0, 786603, 10.0)
    end

    -- Ensure non-drivers are in vehicle
    for _, ped in ipairs(vehicleData.peds) do
        if ped ~= driver and DoesEntityExist(ped) then
            if not IsPedInVehicle(ped, vehicleData.vehicle, false) then
                local seat = -1
                for s = 0, 2 do
                    if IsVehicleSeatFree(vehicleData.vehicle, s) then
                        seat = s
                        break
                    end
                end
                if seat ~= -1 then
                    SetPedIntoVehicle(ped, vehicleData.vehicle, seat)
                end
            end
        end
    end

    -- Reset position and timer
    vehicleData.lastPos = GetEntityCoords(vehicleData.vehicle)
    vehicleData.stationaryStartTime = GetGameTimer()
    vehicleData.despawnTimer = nil
    print("[MnC] Vehicle repaired, peds revived, and rejoined gang war.")
end

-- Define SpawnZoneVehiclesForZone before it's called
local function SpawnZoneVehiclesForZone(zoneIndex)
    local zone = Zones[zoneIndex]
    if not zone.points or #zone.points == 0 then
        print("^1[MnC-gangmenu]^7 Zone " .. (zone.name or tostring(zoneIndex)) .. " has no points, skipping...")
        return
    end

    -- Cleanup old vehicles/peds for this zone
    if zoneVehicles[zoneIndex] then
        for _, data in ipairs(zoneVehicles[zoneIndex]) do
            if DoesEntityExist(data.vehicle) then DeleteEntity(data.vehicle) end
            for _, ped in ipairs(data.peds) do
                if DoesEntityExist(ped) then DeleteEntity(ped) end
            end
        end
    end

    zoneVehicles[zoneIndex] = {}

    local gangModel = GetPedModelFromGroup(zone.gangPedGroup)

    -- Define vehicle model lists per gang
    local vehicleModels = {}
    if zone.ownerGang == "ballas" then
        vehicleModels = {
            `cavalcade3`,
            `baller4`,
            `dubsta`,
            `granger`
        }
    elseif zone.ownerGang == "families" then
        vehicleModels = {
            `washington`,
            `impaler5`,
            `bison2`,
            `mesa`
        }
    else
        vehicleModels = {
            `surge`,
            `seminole`,
            `patriot`,
            `bjxl`
        }
    end

    -- Set fixed spawn locations per gang
    local fixedSpawns = {}
    if zone.ownerGang == "ballas" then
        fixedSpawns = {
            vector4(111.81, -1945.56, 20.75, 343.5),
            vector4(-51.95, -1801.7, 27.01, 52.51),
            vector4(155.27, -1880.69, 23.62, 244.65),
            vector4(4.87, -1680.6, 29.16, 115.9)
        }
    elseif zone.ownerGang == "families" then
        fixedSpawns = {
            vector4(-179.0, -1648.73, 33.22, 0.16),
            vector4(-150.53, -1554.34, 34.73, 318.26),
            vector4(-31.86, -1469.49, 31.07, 276.76),
            vector4(17.12, -1532.85, 29.27, 195.56)
        }
    end

    -- Create patrol points
    local patrolPoints = {}
    for _, spawn in ipairs(fixedSpawns) do
        table.insert(patrolPoints, vector3(spawn.x, spawn.y, spawn.z))
    end
    if #patrolPoints < 4 then
        for i = 1, 4 - #patrolPoints do
            local p = patrolPoints[#patrolPoints]
            table.insert(patrolPoints, vector3(p.x + 5 * i, p.y + 5 * i, p.z))
        end
    end

    for i, spawn in ipairs(fixedSpawns) do
        local vehicleModel = vehicleModels[((i - 1) % #vehicleModels) + 1]

        RequestModel(vehicleModel)
        RequestModel(gangModel)
        while not HasModelLoaded(vehicleModel) or not HasModelLoaded(gangModel) do Wait(50) end

        local veh = CreateVehicle(vehicleModel, spawn.x, spawn.y, spawn.z, spawn.w, true, false)
        SetEntityAsMissionEntity(veh, true, true)
        SetVehicleDoorsLocked(veh, 1)
        SetVehicleNeedsToBeHotwired(veh, false)
        SetVehicleEngineOn(veh, true, true, false)

        if zone.ownerGang == "ballas" then
            SetVehicleColours(veh, 145, 145)
        elseif zone.ownerGang == "families" then
            SetVehicleColours(veh, 49, 49)
        else
            SetVehicleColours(veh, 111, 111)
        end

        local peds = {}
        for seat = -1, 2 do
            if seat ~= 0 then
                local ped = CreatePedInsideVehicle(veh, 4, gangModel, seat, true, false)
                SetEntityAsMissionEntity(ped, true, true)
                SetPedRelationshipGroupHash(ped, zone.gangPedGroup)
                GiveWeaponToPed(ped, `WEAPON_PISTOL`, 100, false, true)
                SetPedArmour(ped, 50)
                SetPedCanRagdollFromPlayerImpact(ped, false)
                table.insert(peds, ped)

                if seat == -1 then
                    -- Randomized safe driving patrol logic
                    CreateThread(function()
                        Wait(10000)
                        local lastIndex = nil
                        while DoesEntityExist(ped) and DoesEntityExist(veh) and not IsEntityDead(ped) do
                            local nextIndex
                            repeat
                                nextIndex = math.random(1, #patrolPoints)
                            until nextIndex ~= lastIndex

                            local wp = patrolPoints[nextIndex]

                            TaskVehicleDriveToCoordLongrange(ped, veh, wp.x, wp.y, wp.z, 17.0, 786603, 10.0)
                            local startTime = GetGameTimer()
                            local taskSuccess = false
                            while GetGameTimer() - startTime < 10000 do
                                local vehPos = GetEntityCoords(veh)
                                if #(vehPos - wp) < 10.0 then
                                    taskSuccess = true
                                    break
                                end
                                Wait(500)
                            end

                            if not taskSuccess then
                                print("^1[MnC-gangmenu]^7 Driver failed to reach waypoint, skipping to next.")
                            end

                            lastIndex = nextIndex
                            Wait(1000)
                        end
                    end)
                end
            end
        end

        table.insert(zoneVehicles[zoneIndex], { 
            vehicle = veh, 
            peds = peds, 
            lastPos = GetEntityCoords(veh), 
            stationaryStartTime = GetGameTimer(),
            despawnTimer = nil
        })
    end
end

-- Thread to handle vehicle despawning and respawning
CreateThread(function()
    while true do
        Wait(1000)
        local currentTime = GetGameTimer()

        -- Handle despawning
        for i = #vehiclesToDespawn, 1, -1 do
            local despawnData = vehiclesToDespawn[i]
            if currentTime >= despawnData.despawnTime then
                if DoesEntityExist(despawnData.vehicleData.vehicle) then
                    DeleteEntity(despawnData.vehicleData.vehicle)
                end
                for _, ped in ipairs(despawnData.vehicleData.peds) do
                    if DoesEntityExist(ped) then
                        DeleteEntity(ped)
                    end
                end
                table.remove(vehiclesToDespawn, i)
                -- Schedule respawn
                table.insert(vehiclesToRespawn, { 
                    zoneIndex = despawnData.zoneIndex, 
                    respawnTime = currentTime + Config.VehicleRespawnDelay 
                })
            end
        end

        -- Handle respawning
        for i = #vehiclesToRespawn, 1, -1 do
            local respawnData = vehiclesToRespawn[i]
            if currentTime >= respawnData.respawnTime then
                SpawnZoneVehiclesForZone(respawnData.zoneIndex)
                table.remove(vehiclesToRespawn, i)
            end
        end
    end
end)

-- Thread to check for stuck vehicles and handle despawn/respawn
CreateThread(function()
    while true do
        Wait(1000)
        local currentTime = GetGameTimer()
        
        for zoneIndex, vehicles in pairs(zoneVehicles) do
            for i = #vehicles, 1, -1 do
                local data = vehicles[i]
                local allDead = true
                local driver = GetPedInVehicleSeat(data.vehicle, -1)
                
                -- Check peds for death status
                for _, ped in ipairs(data.peds) do
                    if DoesEntityExist(ped) and not IsEntityDead(ped) then
                        allDead = false
                    end
                end

                -- Handle despawn timer for vehicles with all peds dead
                if allDead and DoesEntityExist(data.vehicle) then
                    if not data.despawnTimer then
                        data.despawnTimer = currentTime + Config.VehicleDespawnDelay
                        table.insert(vehiclesToDespawn, {
                            zoneIndex = zoneIndex,
                            vehicleData = data,
                            despawnTime = data.despawnTimer
                        })
                    end
                else
                    data.despawnTimer = nil -- Reset despawn timer if peds are alive
                end

                -- Check if vehicle is stuck
                if DoesEntityExist(data.vehicle) and not allDead and driver and DoesEntityExist(driver) and not IsPedDeadOrDying(driver) then
                    local currentPos = GetEntityCoords(data.vehicle)
                    
                    -- Initialize or update position and timer
                    if not data.lastPos or not data.stationaryStartTime then
                        data.lastPos = currentPos
                        data.stationaryStartTime = currentTime
                    end

                    -- Check if vehicle has moved more than the stuck distance
                    local distance = #(currentPos - data.lastPos)
                    if distance > Config.VehicleStuckDistance then
                        data.lastPos = currentPos
                        data.stationaryStartTime = currentTime
                    end

                    -- Relocate if stuck for too long
                    if (currentTime - data.stationaryStartTime) > Config.VehicleStuckCheckInterval then
                        print("[MnC] Vehicle stuck within " .. Config.VehicleStuckDistance .. "m radius for " .. (Config.VehicleStuckCheckInterval / 1000) .. " seconds, relocating...")
                        RelocateAndReviveVehicle(zoneIndex, data)
                    end
                end
            end
        end
    end
end)

-- Thread to handle instant kill detection for peds
CreateThread(function()
    local deadGuards = {} -- Table to track dead guards and their respawn times
    while true do
        Wait(100)
        for zoneIndex, vehicles in pairs(zoneVehicles) do
            for _, data in ipairs(vehicles) do
                for _, ped in ipairs(data.peds) do
                    if DoesEntityExist(ped) and IsEntityDead(ped) then
                        local killer = GetPedSourceOfDeath(ped)
                        if killer == PlayerPedId() then
                            TriggerServerEvent('mnc:rewardForPedKill')
                            TriggerServerEvent('mnc:registerZoneKill')
                        end
                        DeleteEntity(ped)
                    end
                end
            end
        end
        for zoneIndex, guards in pairs(zoneGuards) do
            for i = #guards, 1, -1 do
                local ped = guards[i]
                if DoesEntityExist(ped) and IsEntityDead(ped) then
                    local killer = GetPedSourceOfDeath(ped)
                    if killer == PlayerPedId() then
                        TriggerServerEvent('mnc:rewardForPedKill')
                        TriggerServerEvent('mnc:registerZoneKill')
                    end
                    print(string.format("[MnC] Guard in %s died, scheduling respawn in 30 seconds", Zones[zoneIndex].name))
                    table.remove(guards, i)
                    DeleteEntity(ped)
                end
            end
        end
    end
end)

-- New thread to handle zone guard respawning after death
CreateThread(function()
    while true do
        Wait(1000) -- Check every second
        local currentTime = GetGameTimer()
        
        for zoneIndex, guards in pairs(zoneGuards) do
            local zone = Zones[zoneIndex]
            local currentGuardCount = #guards
            local missingGuards = Config.NumberOfGuards - currentGuardCount
            
            if missingGuards > 0 then
                print(string.format("[MnC] Zone %s (%s) has %d guards, needs %d more", zone.name, zone.ownerGang, currentGuardCount, missingGuards))
                
                -- Calculate zone boundaries for spawn points
                local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
                for _, pt in ipairs(zone.points) do
                    minX = math.min(minX, pt.x)
                    minY = math.min(minY, pt.y)
                    maxX = math.max(maxX, pt.x)
                    maxY = math.max(maxY, pt.y)
                end
                
                local model = GetPedModelFromGroup(zone.gangPedGroup)
                RequestModel(model)
                while not HasModelLoaded(model) do Wait(50) end
                
                -- Spawn missing guards
                for i = 1, missingGuards do
                    local tries = 0
                    local spawned = false
                    while tries < 50 and not spawned do
                        tries = tries + 1
                        local randX = math.random() * (maxX - minX) + minX
                        local randY = math.random() * (maxY - minY) + minY
                        
                        if IsPointInPolygon(vector2(randX, randY), zone.points) then
                            local found, z = GetGroundZFor_3dCoord(randX, randY, 1000.0, false)
                            if found and IsSafeCoord(randX, randY, z) then
                                print(string.format("[MnC] Spawning guard %d/%d for %s at (%.2f, %.2f, %.2f)", i, missingGuards, zone.name, randX, randY, z))
                                
                                local ped = CreatePed(4, model, randX, randY, z, math.random(0, 360), true, false)
                                SetPedRelationshipGroupHash(ped, zone.gangPedGroup)
                                SetEntityAsMissionEntity(ped, true, true)
                                SetPedArmour(ped, 50)
                                SetPedDropsWeaponsWhenDead(ped, false)
                                GiveWeaponToPed(ped, `WEAPON_PISTOL`, 100, false, true)
                                
                                local anims = {
                                    "WORLD_HUMAN_HANG_OUT_STREET",
                                    "WORLD_HUMAN_SMOKING",
                                    "WORLD_HUMAN_DRINKING"
                                }
                                TaskStartScenarioInPlace(ped, anims[math.random(#anims)], 0, true)
                                PatrolPed(ped, GetEntityCoords(ped))
                                
                                -- Add aggression check for new guard
                                CreateThread(function()
                                    while DoesEntityExist(ped) and not IsEntityDead(ped) do
                                        if HasEntityBeenDamagedByAnyPed(ped) then
                                            ClearEntityLastDamageEntity(ped)
                                            local attacker = PlayerPedId()
                                            for _, other in ipairs(zoneGuards[zoneIndex]) do
                                                if DoesEntityExist(other) and not IsPedDeadOrDying(other) then
                                                    ClearPedTasksImmediately(other)
                                                    SetPedAsEnemy(other, true)
                                                    TaskCombatPed(other, attacker, 0, 16)
                                                    PlayAmbientSpeech1(other, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
                                                end
                                            end
                                            break
                                        end
                                        Wait(100)
                                    end
                                end)
                                
                                table.insert(zoneGuards[zoneIndex], ped)
                                spawned = true
                            end
                        end
                        Wait(0)
                    end
                    if not spawned then
                        print(string.format("[MnC] Failed to find valid spawn point for guard %d in %s after %d tries", i, zone.name, tries))
                    end
                end
            end
        end
    end
end)

local function SpawnZoneGuards()
    for zoneIndex, zone in ipairs(Zones) do
        if zoneGuards[zoneIndex] then
            for _, ped in ipairs(zoneGuards[zoneIndex]) do
                if DoesEntityExist(ped) then DeleteEntity(ped) end
            end
        end

        zoneGuards[zoneIndex] = {}
        local model = GetPedModelFromGroup(zone.gangPedGroup)
        RequestModel(model)
        while not HasModelLoaded(model) do Wait(50) end

        local count = Config.NumberOfGuards
        local tries = 0
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        for _, pt in ipairs(zone.points) do
            minX = math.min(minX, pt.x)
            minY = math.min(minY, pt.y)
            maxX = math.max(maxX, pt.x)
            maxY = math.max(maxY, pt.y)
        end

        while count > 0 and tries < 3000 do
            tries = tries + 1
            local randX = math.random() * (maxX - minX) + minX
            local randY = math.random() * (maxY - minY) + minY

            if IsPointInPolygon(vector2(randX, randY), zone.points) then
                local found, z = GetGroundZFor_3dCoord(randX, randY, 1000.0, false)
                if found and IsSafeCoord(randX, randY, z) then
                    local ped = CreatePed(4, model, randX, randY, z, math.random(0, 360), true, false)
                    SetPedRelationshipGroupHash(ped, zone.gangPedGroup)
                    SetEntityAsMissionEntity(ped, true, true)
                    SetPedArmour(ped, 50)
                    SetPedDropsWeaponsWhenDead(ped, false)
                    GiveWeaponToPed(ped, `WEAPON_PISTOL`, 100, false, true)

                    local anims = {
                        "WORLD_HUMAN_HANG_OUT_STREET",
                        "WORLD_HUMAN_SMOKING",
                        "WORLD_HUMAN_DRINKING"
                    }
                    TaskStartScenarioInPlace(ped, anims[math.random(#anims)], 0, true)
                    PatrolPed(ped, GetEntityCoords(ped))

                    table.insert(zoneGuards[zoneIndex], ped)

                    CreateThread(function()
                        while DoesEntityExist(ped) and not IsEntityDead(ped) do
                            if HasEntityBeenDamagedByAnyPed(ped) then
                                ClearEntityLastDamageEntity(ped)
                                local attacker = PlayerPedId()
                                for _, other in ipairs(zoneGuards[zoneIndex]) do
                                    if DoesEntityExist(other) and not IsPedDeadOrDying(other) then
                                        ClearPedTasksImmediately(other)
                                        SetPedAsEnemy(other, true)
                                        TaskCombatPed(other, attacker, 0, 16)
                                        PlayAmbientSpeech1(other, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
                                    end
                                end
                                break
                            end
                            Wait(100)
                        end
                    end)

                    count = count - 1
                end
            end
            Wait(0)
        end
    end
end

local function SpawnZoneVehicles()
    for zoneIndex, zone in ipairs(Zones) do
        SpawnZoneVehiclesForZone(zoneIndex)
    end
end

local function CreateZoneBlips()
    for _, blip in ipairs(zoneBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    zoneBlips = {}

    for _, zone in ipairs(Zones) do
        local center = CalculateCentroid(zone.points)
        local blipColor = zone.gangPedGroup == GetHashKey("AMBIENT_GANG_BALLAS") and 27 or 2

        -- Zone area radius blip
        local radiusBlip = AddBlipForRadius(center.x, center.y, center.z, 120.0)
        SetBlipHighDetail(radiusBlip, true)
        SetBlipColour(radiusBlip, blipColor)
        SetBlipAlpha(radiusBlip, 80)
        table.insert(zoneBlips, radiusBlip)

        -- Name blip
        local nameBlip = AddBlipForCoord(center.x, center.y, center.z)
        SetBlipSprite(nameBlip, 1)
        SetBlipScale(nameBlip, 0.7)
        SetBlipDisplay(nameBlip, 4)
        SetBlipAsShortRange(nameBlip, true)
        SetBlipColour(nameBlip, blipColor)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(zone.name)
        EndTextCommandSetBlipName(nameBlip)
        table.insert(zoneBlips, nameBlip)

        -- Add a blip at each polygon point
        for _, pt in ipairs(zone.points) do
            local pointBlip = AddBlipForCoord(pt.x, pt.y, center.z)
            SetBlipSprite(pointBlip, 1)
            SetBlipScale(pointBlip, 0.5)
            SetBlipColour(pointBlip, blipColor)
            SetBlipAsShortRange(pointBlip, true)
            table.insert(zoneBlips, pointBlip)
        end
    end
end

local function GetPlayerGang()
    local pd = QBCore.Functions.GetPlayerData()
    return pd and pd.metadata and pd.metadata.gang and pd.metadata.gang.name or nil
end

-- Detect player death and trigger immediate flee response from guards
CreateThread(function()
    local wasDead = false
    while true do
        Wait(200)
        local playerPed = PlayerPedId()
        local isDead = IsEntityDead(playerPed)

        if isDead and not wasDead then
            wasDead = true
            TriggerServerEvent('mnc:registerZoneDeath')
            local killer = GetPedSourceOfDeath(playerPed)
            if killer and DoesEntityExist(killer) then
                local deathPos = GetEntityCoords(playerPed)
                for zoneIndex, guards in pairs(zoneGuards) do
                    for _, g in ipairs(guards) do
                        if DoesEntityExist(g) and g == killer then
                            -- Trigger flee from ALL guards in this zone (excluding dead ones)
                            CreateThread(function()
                                for _, ped in ipairs(zoneGuards[zoneIndex]) do
                                    if DoesEntityExist(ped) and not IsPedDeadOrDying(ped) then
                                        ClearPedTasksImmediately(ped)
                                        TaskSmartFleeCoord(ped, deathPos.x, deathPos.y, deathPos.z, 100.0, 15000, false)
                                    end
                                end
                                Wait(25000) -- After 25s, resume patrols
                                for _, ped in ipairs(zoneGuards[zoneIndex]) do
                                    if DoesEntityExist(ped) and not IsPedDeadOrDying(ped) then
                                        ClearPedTasks(ped)
                                        PatrolPed(ped, GetEntityCoords(ped))
                                    end
                                end
                            end)
                            break
                        end
                    end
                end
            end
        elseif not isDead then
            wasDead = false
        end
    end
end)

-- Aggression on shooting
CreateThread(function()
    local attackingGuards = {} -- Track which guards are already attacking per zone
    local vehiclesStopping = {} -- Track which vehicles are in the process of stopping per zone
    for zoneIndex, _ in ipairs(Zones) do
        attackingGuards[zoneIndex] = {} -- Initialize table for each zone
        vehiclesStopping[zoneIndex] = {} -- Initialize table for vehicle stopping status
    end

    while true do
        Wait(100)
        local ped = PlayerPedId()
        if IsPedShooting(ped) then
            local pos = GetEntityCoords(ped)
            local gang = GetPlayerGang()
            for zoneIndex, zone in ipairs(Zones) do
                if IsPointInPolygon(vector2(pos.x, pos.y), zone.points) and gang ~= zone.ownerGang then
                    -- Handle on-foot guards
                    for _, guardPed in ipairs(zoneGuards[zoneIndex]) do
                        if DoesEntityExist(guardPed) and not IsPedDeadOrDying(guardPed) then
                            -- Check if guard is already attacking
                            if not attackingGuards[zoneIndex][guardPed] then
                                ClearPedTasksImmediately(guardPed)
                                SetPedAsEnemy(guardPed, true)
                                TaskCombatPed(guardPed, ped, 0, 16)
                                PlayAmbientSpeech1(guardPed, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
                                attackingGuards[zoneIndex][guardPed] = true -- Mark guard as attacking
                            end
                        end
                    end
                    -- Handle vehicle peds
                    for _, vehicleData in ipairs(zoneVehicles[zoneIndex] or {}) do
                        if DoesEntityExist(vehicleData.vehicle) and not vehiclesStopping[zoneIndex][vehicleData.vehicle] then
                            local driver = GetPedInVehicleSeat(vehicleData.vehicle, -1)
                            if driver and DoesEntityExist(driver) and not IsPedDeadOrDying(driver) then
                                -- Mark vehicle as stopping and stop it
                                vehiclesStopping[zoneIndex][vehicleData.vehicle] = true
                                ClearPedTasksImmediately(driver)
                                TaskVehicleTempAction(driver, vehicleData.vehicle, 1, 5000) -- Slow down and stop
                                -- Create thread to handle peds exiting after vehicle stops
                                CreateThread(function()
                                    local timeout = GetGameTimer() + 5000 -- 5-second timeout
                                    local vehicleSpeed = GetEntitySpeed(vehicleData.vehicle)
                                    while vehicleSpeed > 0.1 and GetGameTimer() < timeout do
                                        vehicleSpeed = GetEntitySpeed(vehicleData.vehicle)
                                        Wait(100)
                                    end
                                    -- Vehicle has stopped or timeout reached
                                    if DoesEntityExist(vehicleData.vehicle) then
                                        for _, vehiclePed in ipairs(vehicleData.peds) do
                                            if DoesEntityExist(vehiclePed) and not IsPedDeadOrDying(vehiclePed) then
                                                -- Check if vehicle ped is already attacking
                                                if not attackingGuards[zoneIndex][vehiclePed] then
                                                    -- Make ped exit vehicle
                                                    if IsPedInVehicle(vehiclePed, vehicleData.vehicle, false) then
                                                        ClearPedTasksImmediately(vehiclePed)
                                                        TaskLeaveVehicle(vehiclePed, vehicleData.vehicle, 0)
                                                        -- Start combat after exiting
                                                        CreateThread(function()
                                                            local exitTimeout = GetGameTimer() + 5000 -- 5-second timeout for exiting
                                                            while IsPedInVehicle(vehiclePed, vehicleData.vehicle, false) and GetGameTimer() < exitTimeout do
                                                                Wait(100)
                                                            end
                                                            if DoesEntityExist(vehiclePed) and not IsPedDeadOrDying(vehiclePed) then
                                                                SetPedAsEnemy(vehiclePed, true)
                                                                TaskCombatPed(vehiclePed, ped, 0, 16)
                                                                PlayAmbientSpeech1(vehiclePed, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
                                                                attackingGuards[zoneIndex][vehiclePed] = true -- Mark vehicle ped as attacking
                                                            end
                                                        end)
                                                    else
                                                        -- Ped is already out of vehicle, start combat immediately
                                                        ClearPedTasksImmediately(vehiclePed)
                                                        SetPedAsEnemy(vehiclePed, true)
                                                        TaskCombatPed(vehiclePed, ped, 0, 16)
                                                        PlayAmbientSpeech1(vehiclePed, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
                                                        attackingGuards[zoneIndex][vehiclePed] = true -- Mark vehicle ped as attacking
                                                    end
                                                end
                                            end
                                        end
                                    end
                                    -- Clear stopping status
                                    vehiclesStopping[zoneIndex][vehicleData.vehicle] = nil
                                end)
                            end
                        end
                    end
                    break
                end
            end
        end
    end
end)

-- Zone Entry Notifications
CreateThread(function()
    local lastZone = nil
    while true do
        Wait(1000)
        local pos = GetEntityCoords(PlayerPedId())
        local inAnyZone = false

        for _, zone in pairs(Zones) do
            if IsPointInPolygon(vector2(pos.x, pos.y), zone.points) then
                inAnyZone = true
                if lastZone ~= zone.name then
                    lastZone = zone.name
                    exports.ox_lib:notify({
                        title = zone.name,
                        description = "You’ve entered " .. zone.ownerGang .. " territory. Proceed with caution.",
                        type = "inform",
                        position = "top",
                        duration = 7000
                    })
                end
                break
            end
        end

        if not inAnyZone and lastZone ~= nil then
            exports.ox_lib:notify({
                title = "Zone Left",
                description = "You’ve left gang territory.",
                type = "inform",
                position = "top",
                duration = 5000
            })
            lastZone = nil
        end
    end
end)

RegisterNetEvent('mnc:showKillNotify', function(kills)
    exports.ox_lib:notify({
        title = "Gang Wars Kills",
        description = "You now have " .. kills .. " zone kills.",
        type = "success",
        position = "top",
        duration = 5000
    })
end)

RegisterNetEvent('mnc:showDeathNotify', function(deaths)
    exports.ox_lib:notify({
        title = "Deaths",
        description = "You are now - " .. deaths .. " deaths.",
        type = "error",
        position = "top",
        duration = 5000
    })
end)

local aiKillCounts = {
    ballas = 0,
    families = 0
}

local function NotifyAIKill(gang)
    aiKillCounts[gang] = aiKillCounts[gang] + 1
end

-- Helper to check if an entity is inside a zone polygon
local function IsEntityInZone(entity, zone)
    if not DoesEntityExist(entity) then return false end
    local pos = GetEntityCoords(entity)
    return IsPointInPolygon(vector2(pos.x, pos.y), zone.points)
end

-- Player shooting detection in zone to enable hostility
local playerShotInZone = {
    ballas = false,
    families = false
}

-- Detect if player shot inside a zone and flag that zone hostile to player
CreateThread(function()
    while true do
        Wait(100)
        local playerPed = PlayerPedId()
        if IsPedShooting(playerPed) then
            local pos = GetEntityCoords(playerPed)
            for _, zone in ipairs(Zones) do
                if IsPointInPolygon(vector2(pos.x, pos.y), zone.points) then
                    playerShotInZone[zone.ownerGang] = true
                end
            end
        end
    end
end)

-- Gang War between Ballas and Families every 2 hours
CreateThread(function()
    while true do
        Wait(2 * 60 * 60 * 1000) -- 2 hours "Wait(2 * 60 * 60 * 1000)"

        local warDuration = 600000 -- 10 minutes or use this for 20 mins "1200000" peds dont enjoy and start having manic episodes
        local warEndTime = GetGameTimer() + warDuration

        print("[MnC] Starting gang war event")
        while GetGameTimer() < warEndTime do
            for zoneIndex, zone in ipairs(Zones) do
                local rivalZoneIndex = zone.ownerGang == "ballas" and 2 or 1
                local myGang = zone.ownerGang
                local rivalGang = Zones[rivalZoneIndex].ownerGang
                local myVehicles = zoneVehicles[zoneIndex] or {}
                local rivalVehicles = zoneVehicles[rivalZoneIndex] or {}
                local rivalGuards = zoneGuards[rivalZoneIndex] or {}
                local rivalZone = Zones[rivalZoneIndex]

                for _, data in ipairs(myVehicles) do
                    local allDead = true
                    for _, ped in ipairs(data.peds) do
                        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped) then
                            allDead = false
                            if GetPedInVehicleSeat(data.vehicle, -1) == ped then
                                -- Driver drives non-aggressively inside rival zone
                                local center = CalculateCentroid(rivalZone.points)
                                TaskVehicleDriveToCoordLongrange(ped, data.vehicle, center.x, center.y, center.z, 20.0, 786603, 10.0)
                            else
                                -- Non-driver attacks rival peds and vehicles only inside rival zone
                                for _, target in ipairs(rivalGuards) do
                                    if DoesEntityExist(target) and not IsPedDeadOrDying(target) and IsEntityInZone(target, rivalZone) then
                                        TaskCombatPed(ped, target, 0, 16)
                                    end
                                end
                                for _, rivalData in ipairs(rivalVehicles) do
                                    if DoesEntityExist(rivalData.vehicle) and IsEntityInZone(rivalData.vehicle, rivalZone) then
                                        for _, rvPed in ipairs(rivalData.peds) do
                                            if DoesEntityExist(rvPed) and not IsPedDeadOrDying(rvPed) and IsEntityInZone(rvPed, rivalZone) then
                                                TaskCombatPed(ped, rvPed, 0, 16)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                -- Guards hostile to player ONLY if player shot in their zone
                if playerShotInZone[zone.ownerGang] then
                    local playerPed = PlayerPedId()
                    for _, guardPed in ipairs(zoneGuards[zoneIndex]) do
                        if DoesEntityExist(guardPed) and not IsPedDeadOrDying(guardPed) then
                            local playerPos = GetEntityCoords(playerPed)
                            local guardPos = GetEntityCoords(guardPed)
                            local dist = #(playerPos - guardPos)
                            if dist < 40.0 then
                                ClearPedTasksImmediately(guardPed)
                                SetPedAsEnemy(guardPed, true)
                                TaskCombatPed(guardPed, playerPed, 0, 16)
                                PlayAmbientSpeech1(guardPed, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
                            end
                        end
                    end
                end
            end

            -- Detect AI kills and notify
            for zoneIndex, zoneList in pairs(zoneGuards) do
                local zone = Zones[zoneIndex]
                for i = #zoneList, 1, -1 do
                    local ped = zoneList[i]
                    if DoesEntityExist(ped) and IsEntityDead(ped) then
                        local killer = GetPedSourceOfDeath(ped)
                        if killer and not IsPedAPlayer(killer) then
                            -- Find which gang the killer belongs to
                            for killerZoneIndex, killerZone in ipairs(Zones) do
                                for _, vehicleData in ipairs(zoneVehicles[killerZoneIndex] or {}) do
                                    for _, aiPed in ipairs(vehicleData.peds) do
                                        if aiPed == killer then
                                            NotifyAIKill(killerZone.ownerGang)
                                            TriggerServerEvent('mnc:registerAIKill', killerZone.ownerGang)
                                            goto killer_found
                                        end
                                    end
                                end
                                for _, guardPed in ipairs(zoneGuards[killerZoneIndex] or {}) do
                                    if guardPed == killer then
                                        NotifyAIKill(killerZone.ownerGang)
                                        TriggerServerEvent('mnc:registerAIKill', killerZone.ownerGang)
                                        goto killer_found
                                    end
                                end
                            end
                        end
                        ::killer_found::
                        table.remove(zoneList, i)
                        DeleteEntity(ped)
                    end
                end
            end

            Wait(5000)
        end

        -- Reset player shot flags after war ends
        playerShotInZone.ballas = false
        playerShotInZone.families = false
        print("[MnC] Gang war event ended")
		SpawnZoneVehicles()
	    SpawnZoneGuards()
    end

end)

-- Thread to manage drive-by driver and passenger status
CreateThread(function()
    while true do
        Wait(120000) -- Check every 5 seconds to avoid performance impact
        
        local isGangWarActive = false
        local currentTime = GetGameTimer()
        local warEndTime = 0 -- Will be updated during gang war
        
        -- Check if gang war is active by inspecting the gang war loop
        for zoneIndex, _ in ipairs(Zones) do
            if zoneVehicles[zoneIndex] then
                for _, data in ipairs(zoneVehicles[zoneIndex]) do
                    local driver = GetPedInVehicleSeat(data.vehicle, -1)
                    if driver and DoesEntityExist(driver) and not IsPedDeadOrDying(driver) then
                        local scriptTaskStatus = GetScriptTaskStatus(driver, 0x93A5526E) -- TaskVehicleDriveToCoordLongrange
                        if scriptTaskStatus == 0 or scriptTaskStatus == 1 then
                            isGangWarActive = true
                            warEndTime = currentTime + 600000 -- Assume 10 minutes remaining if active
                            break
                        end
                    end
                end
            end
            if isGangWarActive then break end
        end

        for zoneIndex, vehicles in pairs(zoneVehicles) do
            local zone = Zones[zoneIndex]
            local rivalZoneIndex = zone.ownerGang == "ballas" and 2 or 1
            local rivalZone = Zones[rivalZoneIndex]

            for _, data in ipairs(vehicles) do
                if DoesEntityExist(data.vehicle) then
                    local driver = GetPedInVehicleSeat(data.vehicle, -1)
                    
                    -- Check if driver is alive
                    if not driver or not DoesEntityExist(driver) or IsPedDeadOrDying(driver) then
                        print(string.format("[MnC] Driver missing or dead in %s vehicle, replacing...", zone.name))
                        
                        -- Delete old driver if exists
                        if driver and DoesEntityExist(driver) then
                            DeleteEntity(driver)
                        end
                        
                        -- Create new driver
                        local gangModel = GetPedModelFromGroup(zone.gangPedGroup)
                        RequestModel(gangModel)
                        while not HasModelLoaded(gangModel) do Wait(50) end
                        
                        local newDriver = CreatePedInsideVehicle(data.vehicle, 4, gangModel, -1, true, false)
                        SetEntityAsMissionEntity(newDriver, true, true)
                        SetPedRelationshipGroupHash(newDriver, zone.gangPedGroup)
                        SetPedArmour(newDriver, 50)
                        SetPedCanRagdollFromPlayerImpact(newDriver, false)
                        GiveWeaponToPed(newDriver, `WEAPON_PISTOL`, 100, false, true)
                        
                        -- Add new driver to peds table
                        for i, ped in ipairs(data.peds) do
                            if ped == driver then
                                data.peds[i] = newDriver
                                break
                            end
                        end
                        
                        driver = newDriver
                    end

                    -- Check passengers
                    local passengers = {}
                    for _, ped in ipairs(data.peds) do
                        if ped ~= driver then
                            table.insert(passengers, ped)
                        end
                    end

                    -- Check and replace passengers if needed
                    for seat = 0, 2 do
                        local ped = GetPedInVehicleSeat(data.vehicle, seat)
                        local shouldReplace = false
                        
                        if not ped or not DoesEntityExist(ped) or IsPedDeadOrDying(ped) or not IsPedInVehicle(ped, data.vehicle, false) then
                            shouldReplace = true
                        end

                        if shouldReplace then
                            print(string.format("[MnC] Passenger missing or dead in %s vehicle, seat %d, replacing...", zone.name, seat))
                            
                            -- Delete old passenger if exists
                            if ped and DoesEntityExist(ped) then
                                DeleteEntity(ped)
                                for i, p in ipairs(data.peds) do
                                    if p == ped then
                                        table.remove(data.peds, i)
                                        break
                                    end
                                end
                            end

                            -- Create new passenger
                            local gangModel = GetPedModelFromGroup(zone.gangPedGroup)
                            RequestModel(gangModel)
                            while not HasModelLoaded(gangModel) do Wait(50) end
                            
                            local newPassenger = CreatePedInsideVehicle(data.vehicle, 4, gangModel, seat, true, false)
                            SetEntityAsMissionEntity(newPassenger, true, true)
                            SetPedRelationshipGroupHash(newPassenger, zone.gangPedGroup)
                            SetPedArmour(newPassenger, 50)
                            SetPedCanRagdollFromPlayerImpact(newPassenger, false)
                            GiveWeaponToPed(newPassenger, `WEAPON_PISTOL`, 100, false, true)
                            table.insert(data.peds, newPassenger)
                        end
                    end

                    -- Assign tasks based on gang war state
                    if driver and DoesEntityExist(driver) and not IsPedDeadOrDying(driver) then
                        ClearPedTasks(driver)
                        if isGangWarActive then
                            -- Drive to rival zone during gang war
                            local center = CalculateCentroid(rivalZone.points)
                            TaskVehicleDriveToCoordLongrange(driver, data.vehicle, center.x, center.y, center.z, 20.0, 786603, 10.0)
                            print(string.format("[MnC] %s vehicle driver assigned to gang war, heading to rival zone", zone.name))
                        else
                            -- Resume patrol
                            local patrolPoints = {}
                            local fixedSpawns = zone.ownerGang == "ballas" and {
                                vector4(111.81, -1945.56, 20.75, 343.5),
                                vector4(-51.95, -1801.7, 27.01, 52.51),
                                vector4(155.27, -1880.69, 23.62, 244.65),
                                vector4(4.87, -1680.6, 29.16, 115.9)
                            } or {
                                vector4(-179.0, -1648.73, 33.22, 0.16),
                                vector4(-150.53, -1554.34, 34.73, 318.26),
                                vector4(-31.86, -1469.49, 31.07, 276.76),
                                vector4(17.12, -1532.85, 29.27, 195.56)
                            }
                            for _, spawn in ipairs(fixedSpawns) do
                                table.insert(patrolPoints, vector3(spawn.x, spawn.y, spawn.z))
                            end
                            local wp = patrolPoints[math.random(1, #patrolPoints)]
                            TaskVehicleDriveToCoordLongrange(driver, data.vehicle, wp.x, wp.y, wp.z, 17.0, 786603, 10.0)
                            print(string.format("[MnC] %s vehicle driver assigned to patrol", zone.name))
                        end
                    end
                end
            end
        end
    end
end)

-- Thread to handle drive-by passengers fleeing when player dies
CreateThread(function()
    local wasDead = false
    while true do
        Wait(200)
        local playerPed = PlayerPedId()
        local isDead = IsEntityDead(playerPed)

        if isDead and not wasDead then
            wasDead = true
            local deathPos = GetEntityCoords(playerPed)
            
            -- Check all vehicles in all zones
            for zoneIndex, vehicles in pairs(zoneVehicles) do
                for _, vehicleData in ipairs(vehicles) do
                    local passengersToRemove = {}
                    
                    -- Check each ped in the vehicle
                    for _, ped in ipairs(vehicleData.peds) do
                        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped) then
                            -- Check if ped is outside the vehicle (not in any seat)
                            local isInVehicle = IsPedInVehicle(ped, vehicleData.vehicle, false)
                            if not isInVehicle then
                                -- Make ped flee from death position
                                ClearPedTasksImmediately(ped)
                                TaskSmartFleeCoord(ped, deathPos.x, deathPos.y, deathPos.z, 100.0, 25000, false)
                                table.insert(passengersToRemove, ped)
                            end
                        end
                    end

                    -- Schedule removal of fleeing passengers after 25 seconds
                    if #passengersToRemove > 0 then
                        CreateThread(function()
                            Wait(400000) -- Wait for flee duration
                            for _, ped in ipairs(passengersToRemove) do
                                if DoesEntityExist(ped) then
                                    DeleteEntity(ped)
                                    print("[MnC] Removed fleeing passenger ped")
                                end
                            end
                            -- Update vehicleData.peds to remove deleted peds
                            for i = #vehicleData.peds, 1, -1 do
                                if not DoesEntityExist(vehicleData.peds[i]) then
                                    table.remove(vehicleData.peds, i)
                                end
                            end
                        end)
                    end
                end
            end
        elseif not isDead then
            wasDead = false
        end
    end
end)

-- Command to check current AI kill counts
RegisterCommand("aigangwarscore", function()
    exports.ox_lib:notify({
        title = "MnC Gang War Score",
        description = ("Ballas AI kills: %d\nFamilies AI kills: %d"):format(aiKillCounts.ballas, aiKillCounts.families),
        type = "inform",
        position = "top",
        duration = 7000
    })
end)

-- Startup
CreateThread(function()
    SpawnZoneVehicles()
    CreateZoneBlips()
    SpawnZoneGuards()
end)

CreateThread(function()
    Wait(3000) -- wait for resource to load fully
    SetLeaderboardVisible(false)
end)