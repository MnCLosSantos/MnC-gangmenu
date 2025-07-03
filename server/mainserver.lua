local QBCore = exports['qb-core']:GetCoreObject()

local killTracker = {}
local deathTracker = {}
local aiKillTracker = {
    ballas = 0,
    families = 0
}

-- Reward for killing ped
RegisterNetEvent('mnc:rewardForPedKill', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        Player.Functions.AddMoney('bank', 250, "Gang Ped Kill Reward")
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Gang Wars Payout',
            description = 'You received $250 for eliminating a gang member.',
            type = 'inform',
            position = 'topright',
            duration = 5000
        })
    end
end)

RegisterNetEvent('mnc:registerZoneKill', function()
    local src = source
    killTracker[src] = (killTracker[src] or 0) + 1
    TriggerClientEvent('mnc:showKillNotify', src, killTracker[src])
end)

RegisterNetEvent('mnc:registerZoneDeath', function()
    local src = source
    deathTracker[src] = (deathTracker[src] or 0) + 1
    TriggerClientEvent('mnc:showDeathNotify', src, deathTracker[src])
end)

-- Register AI kill
RegisterNetEvent('mnc:registerAIKill', function(gang)
    if gang == "ballas" or gang == "families" then
        aiKillTracker[gang] = (aiKillTracker[gang] or 0) + 1
        TriggerClientEvent('ox_lib:notify', -1, {
            title = 'Gang Wars AI Update',
            description = ('%s AI has %d zone kills.'):format(gang:sub(1,1):upper()..gang:sub(2), aiKillTracker[gang]),
            type = 'inform',
            position = 'top',
            duration = 5000
        })
    end
end)

-- Get leaderboard with real ID card name (charinfo.firstname + lastname)
RegisterNetEvent('gangs:getLeaderboardData', function()
    local src = source
    local leaderboard = {
        daily = {},
        weekly = {},
        overall = {},
        ai = {}
    }

    for id, kills in pairs(killTracker) do
        local Player = QBCore.Functions.GetPlayer(id)
        if Player then
            local charInfo = Player.PlayerData.charinfo
            local fullName = (charInfo.firstname or "Unknown") .. " " .. (charInfo.lastname or "")
            table.insert(leaderboard.daily, {
                player_name = fullName,
                kills = kills,
                deaths = deathTracker[id] or 0
            })
            table.insert(leaderboard.weekly, {
                player_name = fullName,
                kills = kills,
                deaths = deathTracker[id] or 0
            })
            table.insert(leaderboard.overall, {
                player_name = fullName,
                kills = kills,
                deaths = deathTracker[id] or 0
            })
        end
    end

    -- Real AI kill data
    table.insert(leaderboard.ai, {
        player_name = "AI_Ballas",
        kills = aiKillTracker.ballas,
        deaths = 0 -- AI deaths not tracked in this version
    })
    table.insert(leaderboard.ai, {
        player_name = "AI_Families",
        kills = aiKillTracker.families,
        deaths = 0 -- AI deaths not tracked in this version
    })

    TriggerClientEvent('gangs:sendLeaderboardData', src, leaderboard)
end)