local QBCore = exports['qb-core']:GetCoreObject()
local displayLeaderboard = false

local Config = {
    DespawnTime = 5 * 60 * 1000,
    PatrolRadius = 80,
    PatrolSpeed = 1.0,
    PatrolWait = 100000,
    NumberOfGuards = 30,
}

local zoneGuards = {}
local zoneBlips = {}

local Zones = {
    {
        name = "Ballas Turf",
        points = {
            vector2(-155.81, -1788.56),
            vector2(42.12, -1685.72),
            vector2(247.81, -1858.94),
            vector2(126.01, -2041.45),
        },
        gangPedGroup = GetHashKey("AMBIENT_GANG_BALLAS"),
        ownerGang = "ballas"
    },
    {
        name = "Families Turf",
        points = {
            vector2(-178.76, -1769.37),
            vector2(87.4, -1441.99),
            vector2(-68.88, -1351.91),
            vector2(-319.2, -1642.4),
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

-- (Rest of your existing code unchanged...)

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

CreateThread(function()
    while true do
        Wait(1000)
        for zoneIndex, guards in pairs(zoneGuards) do
            for i = #guards, 1, -1 do
                local ped = guards[i]
                if DoesEntityExist(ped) and IsEntityDead(ped) then
                    local killer = GetPedSourceOfDeath(ped)
                    if killer == PlayerPedId() then
                        TriggerServerEvent('mnc:rewardForPedKill')
                    end
                    table.remove(guards, i)
                    DeleteEntity(ped)
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

local function CreateZoneBlips()
    for _, blip in ipairs(zoneBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    zoneBlips = {}

    for _, zone in ipairs(Zones) do
        local center = CalculateCentroid(zone.points)
        local radiusBlip = AddBlipForRadius(center.x, center.y, center.z, 120.0)
        SetBlipHighDetail(radiusBlip, true)
        SetBlipColour(radiusBlip, zone.gangPedGroup == GetHashKey("AMBIENT_GANG_BALLAS") and 27 or 2)
        SetBlipAlpha(radiusBlip, 80)
        table.insert(zoneBlips, radiusBlip)

        local nameBlip = AddBlipForCoord(center.x, center.y, center.z)
        SetBlipSprite(nameBlip, 1)
        SetBlipScale(nameBlip, 0.7)
        SetBlipDisplay(nameBlip, 4)
        SetBlipAsShortRange(nameBlip, true)
        SetBlipColour(nameBlip, zone.gangPedGroup == GetHashKey("AMBIENT_GANG_BALLAS") and 27 or 2)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(zone.name)
        EndTextCommandSetBlipName(nameBlip)
        table.insert(zoneBlips, nameBlip)
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
                                        TaskSmartFleeCoord(ped, deathPos.x, deathPos.y, deathPos.z, 150.0, 15000, false)
                                    end
                                end
                                Wait(15000) -- After 15s, resume patrols
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
    while true do
        Wait(300)
        local ped = PlayerPedId()
        if IsPedShooting(ped) then
            local pos = GetEntityCoords(ped)
            local gang = GetPlayerGang()
            for zoneIndex, zone in pairs(Zones) do
                if IsPointInPolygon(vector2(pos.x, pos.y), zone.points) and gang ~= zone.ownerGang then
                    for _, guardPed in ipairs(zoneGuards[zoneIndex]) do
                        if DoesEntityExist(guardPed) and not IsPedDeadOrDying(guardPed) then
                            ClearPedTasksImmediately(guardPed)
                            SetPedAsEnemy(guardPed, true)
                            TaskCombatPed(guardPed, ped, 0, 16)
                            PlayAmbientSpeech1(guardPed, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
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

-- Startup
CreateThread(function()
    SpawnZoneGuards()
    CreateZoneBlips()
end)

CreateThread(function()
    Wait(3000) -- wait for resource to load fully
    SetLeaderboardVisible(false)
end)
