local QBCore = exports['qb-core']:GetCoreObject()

-- Reward logic for gang ped kills
RegisterNetEvent('mnc:rewardForPedKill', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        Player.Functions.AddMoney('bank', 1000, "Gang Ped Kill Reward")
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'MnC',
            description = 'You received $1000 for eliminating a gang member.',
            type = 'success',
            position = 'top',
            duration = 5000
        })
    end
end)

-- Sends all leaderboard data to client on request
RegisterNetEvent('gangs:getLeaderboardData', function()
    local src = source

    -- Placeholder/mock data
    local leaderboard = {
        daily = {
            { player_name = "PlayerDaily1", kills = 3, deaths = 1 },
            { player_name = "PlayerDaily2", kills = 2, deaths = 0 },
        },
        weekly = {
            { player_name = "PlayerWeekly1", kills = 7, deaths = 2 },
            { player_name = "PlayerWeekly2", kills = 4, deaths = 1 },
        },
        overall = {
            { player_name = "PlayerMain1", kills = 20, deaths = 5 },
            { player_name = "PlayerMain2", kills = 15, deaths = 8 },
        },
        ai = {
            { player_name = "AI_Enforcer1", kills = 12, deaths = 3 },
            { player_name = "AI_Enforcer2", kills = 10, deaths = 4 },
        }
    }

    TriggerClientEvent('gangs:sendLeaderboardData', src, leaderboard)
end)
