-- Make ESX optional with fallback
local ESX = nil
local hasESX = false

-- Try to get ESX with error handling
local status, result = pcall(function()
    return exports["es_extended"]:getSharedObject()
end)

if status and result then
    ESX = result
    hasESX = true
    print("Modern Glory Killfeed loaded with ESX support")
else
    print("Modern Glory Killfeed loaded without ESX (standalone mode)")
end

local lastDeathTime = 0
local deathCooldown = 1000
local processedPeds = {}
local damageEvents = {}

-- Simplified damage detection system
local damageTracker = {
    myLastHealth = 200,
    myLastArmor = 0,
    lastDamageTime = 0,
    targets = {},  -- Track entities we're shooting
    maxTargets = 10
}

-- Thread to continuously track nearby targets' health (for pre-capture)
CreateThread(function()
    while true do
        Wait(500) -- Check every 500ms to pre-capture health
        
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        
        -- Track all nearby peds for potential targeting
        for _, ped in ipairs(GetGamePool('CPed')) do
            if DoesEntityExist(ped) and ped ~= playerPed and not IsPedDeadOrDying(ped, true) then
                local pedCoords = GetEntityCoords(ped)
                local distance = #(playerCoords - pedCoords)
                
                -- Only track nearby entities (within 100m)
                if distance <= 100.0 then
                    local pedId = tostring(ped)
                    if not damageTracker.targets[pedId] then
                        damageTracker.targets[pedId] = {
                            entity = ped,
                            lastHealth = GetEntityHealth(ped),  -- Real game value (0-200)
                            lastArmor = IsPedAPlayer(ped) and GetPedArmour(ped) or 0,  -- Real game value (0-100)
                            lastCheck = GetGameTimer()
                        }
                    end
                end
            end
        end
    end
end)



-- Enhanced damage detection using CEventNetworkEntityDamage
AddEventHandler('gameEventTriggered', function(event, data)
    if event == 'CEventNetworkEntityDamage' then
        local victim, attacker = data[1], data[2]
        local localPlayerPed = PlayerPedId()
        
        -- Only process when local player is the attacker
        if attacker == localPlayerPed and victim ~= localPlayerPed and victim then
            if DoesEntityExist(victim) and not IsPedDeadOrDying(victim, true) then
                local victimId = tostring(victim)
                
                -- Check if we have previous health data for this target
                local previousData = damageTracker.targets[victimId]
                
                if previousData then
                    -- Add small delay to ensure we get the latest health values after damage applies
                    CreateThread(function()
                        Wait(50) -- 50ms delay to ensure damage has been processed
                        
                        if DoesEntityExist(victim) then
                            -- Get current health and armor values after damage
                            local currentHealth = GetEntityHealth(victim)
                            local currentArmor = IsPedAPlayer(victim) and GetPedArmour(victim) or 0
                            
                            -- Calculate actual damage dealt (using real game values)
                            -- Health: 0-200 scale, Armor: 0-100 scale
                            local healthLoss = math.max(0, previousData.lastHealth - currentHealth)
                            local armorLoss = math.max(0, previousData.lastArmor - currentArmor)
                            
                            -- Calculate total effective health lost
                            local totalRawDamage = healthLoss + armorLoss
                            
                            if totalRawDamage > 0 then
                                -- Normalize damage to 0-100 scale for display clarity
                                -- Total possible health = 200 (health) + 100 (armor) = 300
                                local displayDamage = math.floor((totalRawDamage / 300) * 100)
                                
                                -- Cap damage at 100 for UI display (instant kill weapons)
                                displayDamage = math.min(100, displayDamage)
                                
                                -- Ensure minimum damage of 1 for display if any damage occurred
                                displayDamage = math.max(1, displayDamage)
                                
                                -- Show damage notification with normalized display value
                                SendNUIMessage({
                                    action = "showdamage",
                                    damage = displayDamage,
                                    rawDamage = totalRawDamage, -- Keep raw damage for internal use
                                    healthLoss = healthLoss,
                                    armorLoss = armorLoss
                                })
                                
                                -- Debug output for testing
                                print(string.format("💥 DAMAGE: Health: %d->%d (-%d), Armor: %d->%d (-%d), Total: %d, Display: %d", 
                                    previousData.lastHealth, currentHealth, healthLoss,
                                    previousData.lastArmor, currentArmor, armorLoss,
                                    totalRawDamage, displayDamage))
                            end
                            
                            -- Update stored health data for next hit
                            damageTracker.targets[victimId] = {
                                entity = victim,
                                lastHealth = currentHealth,
                                lastArmor = currentArmor,
                                lastCheck = GetGameTimer()
                            }
                        end
                    end)
                else
                    -- First time seeing this target, just store current values
                    local currentHealth = GetEntityHealth(victim)
                    local currentArmor = IsPedAPlayer(victim) and GetPedArmour(victim) or 0
                    
                    damageTracker.targets[victimId] = {
                        entity = victim,
                        lastHealth = currentHealth,
                        lastArmor = currentArmor,
                        lastCheck = GetGameTimer()
                    }
                end
            end
        end
        
        -- Keep original damage tracking for kill feed (using unreliable damage values)
        local hasDamageComponent, damageComponent = data[10], data[11]
        if victim and attacker and hasDamageComponent and damageComponent and damageComponent > 0 then
            local attackerServerId = NetworkGetPlayerIndexFromPed(attacker)
            local victimServerId = NetworkGetPlayerIndexFromPed(victim)
            
            if attackerServerId and attackerServerId ~= -1 then
                local key = attackerServerId .. "_" .. (victimServerId or "npc")
                if not damageEvents[key] then
                    damageEvents[key] = 0
                end
                damageEvents[key] = damageEvents[key] + math.max(1, damageComponent) -- Ensure at least 1 damage
                
                -- Enhanced headshot detection via damage analysis
                local victimId = tostring(victim)
                local currentTime = GetGameTimer()
                
                -- Only track headshots for local player
                if attacker == localPlayerPed then
                    local isHeadshotDamage = false
                    
                    if damageComponent >= 80 then
                        isHeadshotDamage = true
                    elseif damageComponent >= 50 then
                        isHeadshotDamage = true
                    elseif damageComponent >= 35 then
                        local weaponHash = GetSelectedPedWeapon(attacker)
                        local isSniper = weaponHash == GetHashKey("WEAPON_SNIPERRIFLE") or 
                                       weaponHash == GetHashKey("WEAPON_HEAVYSNIPER") or
                                       weaponHash == GetHashKey("WEAPON_MARKSMANRIFLE")
                        
                        if isSniper then
                            isHeadshotDamage = true
                        end
                    end
                    
                    if isHeadshotDamage then
                        recentDamage[victimId] = {
                            isHeadshot = true,
                            damage = damageComponent,
                            timestamp = currentTime
                        }
                    end
                end
            end
        end
    end
end)

-- Cleanup thread for old tracked targets (much simpler now)
CreateThread(function()
    while true do
        Wait(5000) -- Clean up every 5 seconds
        
        local currentTime = GetGameTimer()
        
        -- Clean up old/invalid targets
        for targetId, targetData in pairs(damageTracker.targets) do
            if not DoesEntityExist(targetData.entity) or 
               IsPedDeadOrDying(targetData.entity, true) or
               (currentTime - targetData.lastCheck) > 10000 then -- 10 second timeout
                damageTracker.targets[targetId] = nil
            end
        end
        
        -- Limit tracked targets if too many
        local count = 0
        for _ in pairs(damageTracker.targets) do count = count + 1 end
        if count > damageTracker.maxTargets then
            local oldest = nil
            local oldestTime = currentTime
            for id, data in pairs(damageTracker.targets) do
                if data.lastCheck < oldestTime then
                    oldestTime = data.lastCheck
                    oldest = id
                end
            end
            if oldest then
                damageTracker.targets[oldest] = nil
            end
        end
    end
end)


-- Main death event handler
AddEventHandler('gameEventTriggered', function(event, data)
    if event ~= 'CEventNetworkEntityDamage' then
        return
    end

    local currentTime = GetGameTimer()
    if currentTime - lastDeathTime < deathCooldown then
        return
    end

    local victim, victimDied = data[1], data[4]
    if not IsPedAPlayer(victim) then
        return
    end

    local player = PlayerId()
    local playerPed = PlayerPedId()

    if victimDied and NetworkGetPlayerIndexFromPed(victim) == player and
        (IsPedDeadOrDying(victim, true) or IsPedFatallyInjured(victim)) then
        lastDeathTime = currentTime
        local killerEntity = GetPedSourceOfDeath(playerPed)
        local deathCause = GetPedCauseOfDeath(playerPed)
        local killerClientId = killerEntity and NetworkGetPlayerIndexFromPed(killerEntity) or -1

        if killerEntity and killerEntity ~= playerPed and killerClientId ~= -1 and NetworkIsPlayerActive(killerClientId) then
            PlayerKilledByPlayer(GetPlayerServerId(killerClientId), killerClientId, deathCause)
        else
            TriggerSuicide()
        end
    end
end)

function TriggerSuicide()
    local weapon = nil
    if hasESX and ESX then
        weapon = ESX.GetWeaponFromHash(741814745)
    end
    
    local data = {
        killedByPlayer = true,
        deathCause = 'Suicide',
        killerServerId = GetPlayerServerId(PlayerId()),
        killerClientId = PlayerId(),
        weapon = weapon and weapon.name or "unknown",
        damage = 100,
        distance = 0
    }
    TriggerServerEvent('glory_killfeed:onPlayerDead', data)
end

function PlayerKilledByPlayer(killerServerId, killerClientId, deathCause)
    local weapon = nil
    if hasESX and ESX then
        weapon = ESX.GetWeaponFromHash(deathCause)
    end
    local playerPed = PlayerPedId()
    local killerPed = GetPlayerPed(killerClientId)
    
    -- Calculate distance
    local distance = 0
    if killerPed and DoesEntityExist(killerPed) then
        distance = #(GetEntityCoords(killerPed) - GetEntityCoords(playerPed))
    end
    
    -- Enhanced headshot detection
    local isHeadshot = DetectHeadshot(playerPed, killerPed)
    
    -- Enhanced wallbang detection
    local isWallbang = DetectWallbang(killerPed, playerPed)
    
    -- Get damage data
    local totalDamage = GetDamageForKill(killerServerId, GetPlayerServerId(PlayerId()))
    
    local data = {
        killedByPlayer = true,
        deathCause = deathCause,
        killerServerId = killerServerId,
        killerClientId = killerClientId,
        weapon = weapon and weapon.name or "unknown",
        isHeadshot = isHeadshot,
        isWallbang = isWallbang,
        damage = totalDamage,
        distance = distance
    }
    
    TriggerServerEvent('glory_killfeed:onPlayerDead', data)
end

-- Store recent damage data for headshot detection
local recentDamage = {}

function DetectHeadshot(victim, attacker)
    if not victim or not DoesEntityExist(victim) then 
        return false 
    end
    
    -- Method 1: Check recent high damage (most reliable)
    local victimId = tostring(victim)
    if recentDamage[victimId] and recentDamage[victimId].isHeadshot then
        recentDamage[victimId] = nil
        return true
    end
    
    -- Method 2: Bone detection with improved logic
    local boneId = 0
    local hasBone, actualBone = GetPedLastDamageBone(victim, boneId)
    
    if hasBone then
        -- More comprehensive head bone list
        local headBones = {
            31086,  -- SKEL_HEAD (primary head bone)
            65068,  -- HEAD (secondary)
            58271,  -- FACIAL_facialRoot
            17188,  -- HEAD_1 
            45750,  -- IK_HEAD
            28252,  -- BONETAG_HEAD
            21550,  -- Head variant
            12844,  -- Additional head bone
            57597   -- Head top
        }
        
        for _, bone in ipairs(headBones) do
            if actualBone == bone then
                return true
            end
        end
    end
    
    return false
end


function DetectWallbang(attacker, victim)
    if not attacker or not victim or not DoesEntityExist(attacker) or not DoesEntityExist(victim) then
        print("❌ WALLBANG CHECK FAILED: Invalid entities")
        return false
    end

    local attackerCoords = GetPedBoneCoords(attacker, 0x796e, 0, 0, 0) -- attacker head
    local victimCoords = GetPedBoneCoords(victim, 0x796e, 0, 0, 0) -- victim head

    local distance = #(attackerCoords - victimCoords)
    local victimVehicle = GetVehiclePedIsIn(victim, false)

    print("🧱 WALLBANG CHECK - Distance:", distance)

    local raycastFlags = 87 -- world + vehicles + glass + peds

    if victimVehicle ~= 0 then
        -- Conservative assumption: any shot on victim in vehicle counts as wallbang
        print("✅ WALLBANG DETECTED: Victim in vehicle (glass assumed)")
        return true
    end

    local raycast = StartShapeTestRay(
        attackerCoords.x, attackerCoords.y, attackerCoords.z,
        victimCoords.x, victimCoords.y, victimCoords.z,
        -1, attacker, raycastFlags
    )
    local _, hit, _, _, hitEntity = GetShapeTestResult(raycast)

    print("Raycast hit status:", hit, "Entity hit:", hitEntity)

    local function IsEntityPartOfVictim(entity)
        if entity == victim then return true end
        if victimVehicle ~= 0 and entity == victimVehicle then return true end
        return false
    end

    if hit == 1 then
        if not IsEntityPartOfVictim(hitEntity) and hitEntity ~= attacker then
            print("✅ WALLBANG DETECTED: Obstruction by entity", hitEntity)
            return true
        end
    end

    -- Additional capsule test
    local capsuleRaycast = StartShapeTestCapsule(
        attackerCoords.x, attackerCoords.y, attackerCoords.z,
        victimCoords.x, victimCoords.y, victimCoords.z,
        0.3,
        -1, attacker, raycastFlags
    )
    local _, cHit, _, _, cHitEntity = GetShapeTestResult(capsuleRaycast)
    print("Capsule raycast hit status:", cHit, "Entity hit:", cHitEntity)
    if cHit == 1 then
        if not IsEntityPartOfVictim(cHitEntity) and cHitEntity ~= attacker then
            print("✅ WALLBANG DETECTED (Capsule): Obstruction by entity", cHitEntity)
            return true
        end
    end

    print("❌ WALLBANG NOT DETECTED: Clear line of sight")
    return false
end


function GetDamageForKill(attackerServerId, victimServerId)
    local key = GetPlayerFromServerId(attackerServerId) .. "_" .. (victimServerId or "npc")
    local rawDamage = damageEvents[key] or 0
    
    -- Clean up the damage event
    damageEvents[key] = nil
    
    -- If no damage recorded, estimate based on weapon type
    if rawDamage == 0 then
        rawDamage = 200 -- Default full health (raw game scale)
    end
    
    -- Normalize damage to 0-100 scale for kill feed display
    -- Assuming max possible damage is 300 (200 health + 100 armor)
    local displayDamage = math.floor((rawDamage / 300) * 100)
    
    -- Cap at 100 for instant kill weapons and ensure minimum of 1
    displayDamage = math.min(100, math.max(1, displayDamage))
    
    return displayDamage
end

-- NPC Kill Detection Thread
CreateThread(function()
    while true do
        Wait(100)

        local playerPed = PlayerPedId()
        local playerServerId = GetPlayerServerId(PlayerId())

        for _, ped in ipairs(GetGamePool('CPed')) do
            if DoesEntityExist(ped) and not IsPedAPlayer(ped) and IsPedDeadOrDying(ped, true) then
                if not processedPeds[ped] then
                    local killer = GetPedSourceOfDeath(ped)

                    if killer == playerPed then
                        local weaponHash = GetPedCauseOfDeath(ped)
                        local weapon = nil
                        if hasESX and ESX then
                            weapon = ESX.GetWeaponFromHash(weaponHash)
                        end
                        if not weapon then
                            weapon = { name = "pistol" }
                        end

                        -- Calculate distance to NPC
                        local distance = #(GetEntityCoords(playerPed) - GetEntityCoords(ped))
                        
                        -- Enhanced headshot detection for NPCs
                        local isHeadshot = DetectHeadshot(ped, playerPed)
                        
                        -- Enhanced wallbang detection for NPCs
                        local isWallbang = DetectWallbang(playerPed, ped)
                        
                        -- Get damage for NPC kill
                        local totalDamage = GetDamageForKill(playerServerId, "npc_" .. ped)

                        TriggerServerEvent('glory_killfeed:onPlayerDead', {
                            killerServerId = playerServerId,
                            killerClientId = PlayerId(),
                            killedByPlayer = true,
                            victim = "NPC",
                            weapon = weapon.name,
                            isHeadshot = isHeadshot,
                            isWallbang = isWallbang,
                            damage = totalDamage,
                            distance = distance
                        })

                        processedPeds[ped] = true
                    end
                end
            else
                if processedPeds[ped] then
                    processedPeds[ped] = nil
                end
            end
        end
    end
end)

-- UI Display Event
local function showUI(data)
    local victim = data.victim
    local killer = data.killerServerId
    local weapon = data.weapon
    local isHeadshot = data.isHeadshot
    local isWallbang = data.isWallbang
    local damage = data.damage or 0
    local distance = data.distance or 0
    
    
    SendNUIMessage({
        action = "showui",
        victim = victim,
        killer = killer,
        weapon = weapon,
        isHeadshot = isHeadshot,
        isWallbang = isWallbang,
        damage = damage,
        distance = distance,
        killerServerId = killer
    })
end


RegisterNetEvent('glory_killfeed:ShowUi')
AddEventHandler('glory_killfeed:ShowUi', function(data)
    -- Remove problematic hex_ffa dependency - show UI directly
    showUI(data)
end)

-- Player ID system (keeping existing functionality)
local config = {
    dist = 5,
    idScale = 2,
    zOffset = 0.5
}

local show = false

RegisterCommand("+showids", function()
    show = true
    CreateThread(function()
        while show do
            Wait(0)
            local ply = PlayerPedId()
            local plyCoord = GetEntityCoords(ply)
            for _, id in ipairs(GetActivePlayers()) do
                local otherPly = GetPlayerPed(id)
                local otherCoord = GetEntityCoords(otherPly)
                if (#(plyCoord - otherCoord) <= config.dist) then
                    local pos = GetPedBoneCoords(otherPly, 31086, 0, 0, 0)
                    local getId = GetPlayerServerId(id)
                    DrawText3D(pos, getId, 255, 255, 255)
                end
            end
        end
    end)
end)

RegisterCommand("-showids", function()
    show = false
end)

RegisterKeyMapping("+showids", "Za prikaz ID-a Drugih igraca DRZI", "keyboard", "PERIOD")

function DrawText3D(position, text, r, g, b)
    local onScreen, _x, _y = World3dToScreen2d(position.x, position.y, position.z + config.zOffset)
    local dist = #(GetGameplayCamCoords() - position)

    local scale = (1 / dist) * config.idScale
    local fov = (1 / GetGameplayCamFov()) * 100
    local scale = scale * fov

    if onScreen then
        SetTextScale(0.0 * scale, 0.55 * scale)
        SetTextFont(0)
        SetTextProportional(1)
        SetTextColour(r, g, b, 255)
        SetTextDropshadow(0, 0, 0, 0, 255)
        SetTextEdge(2, 0, 0, 0, 150)
        SetTextDropShadow()
        SetTextOutline()
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(text)
        DrawText(_x, _y)
    end
end

-- Test command for kill feed
RegisterCommand("testkillfeed", function()
    local weapon = nil
    if hasESX and ESX then
        weapon = ESX.GetWeaponFromHash(741814745)
    end
    local playerId = PlayerId()
    local serverId = GetPlayerServerId(playerId)

    TriggerServerEvent('glory_killfeed:onPlayerDead', {
        killerServerId = serverId,
        killedByPlayer = true,
        weapon = weapon and weapon.name or "pistol",
        isHeadshot = true,
        damage = 87,
        distance = 25.5
    })
end)

-- Test command for damage numbers
RegisterCommand("testdamage", function(source, args)
    local actualDamage = tonumber(args[1]) or 90  -- Default to 90 (real game scale)
    local displayDamage = math.floor((actualDamage / 200) * 100)  -- Convert to 0-100 scale for display
    
    SendNUIMessage({
        action = "showdamage",
        damage = displayDamage
    })
end)



-- Test command for headshot kill feed
RegisterCommand("testheadshot", function()
    local weapon = nil
    if hasESX and ESX then
        weapon = ESX.GetWeaponFromHash(453432689) -- pistol
    end
    local playerId = PlayerId()
    local serverId = GetPlayerServerId(playerId)

    TriggerServerEvent('glory_killfeed:onPlayerDead', {
        killerServerId = serverId,
        killedByPlayer = true,
        victim = "Test NPC",
        weapon = weapon and weapon.name or "pistol",
        isHeadshot = true,
        isWallbang = false,
        damage = 100,
        distance = 15.2
    })
end)

-- Debug command to test current bone detection
RegisterCommand("debugbone", function()
    local playerPed = PlayerPedId()
    print("=== BONE DEBUG ===")
    print("Player ped:", playerPed)
    
    local headBone = GetEntityBoneIndexByName(playerPed, "head")
    print("Head bone index:", headBone)
    
    local skelHead = GetEntityBoneIndexByName(playerPed, "SKEL_HEAD")
    print("SKEL_HEAD bone index:", skelHead)
    
    -- Test last damage bone
    local lastBone = 0
    local hasBone = GetPedLastDamageBone(playerPed, lastBone)
    print("Has last damage bone:", hasBone, "Bone:", lastBone)
    print("=== END BONE DEBUG ===")
end)

-- Test command for wallbang kill feed
RegisterCommand("testwallbang", function()
    local weapon = nil
    if hasESX and ESX then
        weapon = ESX.GetWeaponFromHash(453432689) -- pistol
    end
    local playerId = PlayerId()
    local serverId = GetPlayerServerId(playerId)

    TriggerServerEvent('glory_killfeed:onPlayerDead', {
        killerServerId = serverId,
        killedByPlayer = true,
        victim = "Test NPC",
        weapon = weapon and weapon.name or "pistol",
        isHeadshot = false,
        isWallbang = true,
        damage = 85,
        distance = 22.7
    })
end)

-- Test command for both headshot and wallbang
RegisterCommand("testboth", function()
    local weapon = nil
    if hasESX and ESX then
        weapon = ESX.GetWeaponFromHash(453432689) -- pistol
    end
    local playerId = PlayerId()
    local serverId = GetPlayerServerId(playerId)

    TriggerServerEvent('glory_killfeed:onPlayerDead', {
        killerServerId = serverId,
        killedByPlayer = true,
        victim = "Test NPC",
        weapon = weapon and weapon.name or "pistol",
        isHeadshot = true,
        isWallbang = true,
        damage = 95,
        distance = 18.4
    })
end)

-- Test command to force both icons (backup method)
RegisterCommand("forceboth", function()
    local weapon = nil
    if hasESX and ESX then
        weapon = ESX.GetWeaponFromHash(453432689) -- pistol
    end
    local playerId = PlayerId()
    local serverId = GetPlayerServerId(playerId)

    -- Send directly to NUI to bypass server processing
    SendNUIMessage({
        action = "showui",
        victim = "Test Victim",
        killer = GetPlayerName(PlayerId()),
        weapon = weapon and weapon.name or "pistol",
        isHeadshot = true,
        isWallbang = true,
        damage = 100,
        distance = 25.5,
        killerServerId = GetPlayerName(PlayerId())
    })
end)

-- Debug command to test wallbang detection logic
RegisterCommand("debugwallbang", function()
    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    
    print("=== WALLBANG DEBUG TEST ===")
    print("Player position:", coords)
    
    -- Create a fake target position in front of player
    local forwardVector = GetEntityForwardVector(playerPed)
    local targetCoords = coords + forwardVector * 10.0
    
    print("Target position:", targetCoords)
    
    -- Test HasEntityClearLosToEntity with world coordinates
    local hasLOS = HasEntityClearLosToEntityInWorld(coords.x, coords.y, coords.z + 1.0, targetCoords.x, targetCoords.y, targetCoords.z + 1.0, 17)
    print("HasEntityClearLosToEntityInWorld result:", hasLOS)
    
    -- Test raycast
    local raycast = StartShapeTestRay(
        coords.x, coords.y, coords.z + 1.0,
        targetCoords.x, targetCoords.y, targetCoords.z + 1.0,
        1, -- World collision
        0, 7
    )
    local _, hit, hitCoords, _, hitEntity = GetShapeTestResult(raycast)
    print("Raycast result - Hit:", hit, "Entity:", hitEntity)
    
    if hit == 1 then
        print("Hit coordinates:", hitCoords)
        print("Distance to hit:", #(coords - hitCoords))
    end
    
    print("=== END WALLBANG DEBUG ===")
end)




-- Clean up damage events periodically
CreateThread(function()
    while true do
        Wait(30000) -- Clean up every 30 seconds
        local currentTime = GetGameTimer()
        
        -- Clean up damage events
        for key, timestamp in pairs(damageEvents) do
            if type(timestamp) == "number" and currentTime - timestamp > 10000 then
                damageEvents[key] = nil
            end
        end
        
        -- Clean up recent damage tracking
        for victimId, data in pairs(recentDamage) do
            if currentTime - data.timestamp > 5000 then -- 5 seconds
                recentDamage[victimId] = nil
            end
        end
        
        -- Clean up tracked targets for damage dealt  
        for targetId, targetData in pairs(damageTracker.targets) do
            if not DoesEntityExist(targetData.entity) or 
               (currentTime - targetData.lastCheck) > 10000 then -- 10 seconds
                damageTracker.targets[targetId] = nil
            end
        end
        
    end
end)
