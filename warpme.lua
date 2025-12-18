addon.name      = 'WarpMe';
addon.author    = 'ai';
addon.version   = '1.1';
addon.desc      = 'Warps using spell, equipment, or scroll - whatever is fastest.';
addon.link      = 'https://github.com/kchang4/warpme';

require('common');
local chat = require('chat');
local timePointer = ashita.memory.find('FFXiMain.dll', 0, '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0);
local vanaOffset = 0x3C307D70;

-- State tracking for auto-use
local pendingWarp = nil;

-- Warp spell ID (Black Magic)
local WARP_SPELL_ID = 262;

-- Warp scroll item ID (Instant Warp)
local WARP_SCROLL_ID = 4181;

-- List of warp items to check for (equipment only - no scrolls here)
local warpItems = T{
    17040,  -- Warp Cudgel
    28540,  -- Warp Ring
    14672,  -- Tavnazian Ring
    15212,  -- Stars Cap
    15194,  -- Maat's Cap
    17587,  -- Trick Staff II
    17588,  -- Treat Staff II
};

local function GetTimeUTC()
    local ptr = ashita.memory.read_uint32(timePointer);
    ptr = ashita.memory.read_uint32(ptr);
    return ashita.memory.read_uint32(ptr + 0x0C);
end

local function TimerToString(timer)
    if (timer >= 3600) then
        local h = math.floor(timer / (3600));
        local m = math.floor(math.fmod(timer, 3600) / 60);
        return string.format('%ih %02im', h, m);
    elseif (timer >= 60) then
        local m = math.floor(timer / 60);
        local s = math.fmod(timer, 60);
        return string.format('%im %02is', m, s);
    else
        if (timer < 1) then
            return 'Ready';
        else
            return string.format('%is', timer);
        end
    end
end

local function GetEquipSlotFromBitfield(slots)
    -- Equipment slot mapping (0-indexed for packet)
    -- Slots bitfield can indicate multiple valid slots, we check each bit
    local slotMap = T{
        [0x0001] = 0,  -- Main
        [0x0002] = 1,  -- Sub
        [0x0004] = 2,  -- Range
        [0x0008] = 3,  -- Ammo
        [0x0010] = 4,  -- Head
        [0x0020] = 5,  -- Body
        [0x0040] = 6,  -- Hands
        [0x0080] = 7,  -- Legs
        [0x0100] = 8,  -- Feet
        [0x0200] = 9,  -- Neck
        [0x0400] = 10, -- Waist
        [0x0800] = 11, -- Ear1
        [0x1000] = 12, -- Ear2
        [0x2000] = 13, -- Ring1
        [0x4000] = 14, -- Ring2
        [0x8000] = 15, -- Back
    };
    
    -- Find first available slot from the bitfield
    for bitflag, slot in pairs(slotMap) do
        if bit.band(slots, bitflag) ~= 0 then
            return slot;
        end
    end
    
    return nil;
end

-- Check if player can cast Warp spell and get its recast time
local function CheckWarpSpell()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local recast = AshitaCore:GetMemoryManager():GetRecast();
    local resMgr = AshitaCore:GetResourceManager();
    
    -- Check if player has Warp spell learned
    if not player:HasSpell(WARP_SPELL_ID) then
        return nil;
    end
    
    -- Get spell resource to check level requirements
    local spell = resMgr:GetSpellById(WARP_SPELL_ID);
    if not spell then
        return nil;
    end
    
    -- Get player's current jobs and levels
    local mainJob = player:GetMainJob();
    local mainJobLevel = player:GetMainJobLevel();
    local subJob = player:GetSubJob();
    local subJobLevel = player:GetSubJobLevel();
    
    -- Check if main job can cast at current level (Job IDs are 0-indexed, Lua tables are 1-indexed)
    local mainJobReq = spell.LevelRequired[mainJob + 1];
    local subJobReq = spell.LevelRequired[subJob + 1];
    
    local canCastMain = mainJobReq and mainJobReq > 0 and mainJobReq <= mainJobLevel;
    local canCastSub = subJobReq and subJobReq > 0 and subJobReq <= subJobLevel;
    
    if not canCastMain and not canCastSub then
        return nil;  -- Current job combo cannot cast Warp
    end
    
    -- Get spell recast timer (returns value in 60ths of a second, 0 if ready)
    local timer = recast:GetSpellTimer(WARP_SPELL_ID);
    local recastSeconds = timer / 60;
    
    return {
        Type = 'spell',
        Name = 'Warp',
        TimeUntilUse = recastSeconds,
        Ready = (recastSeconds < 1)
    };
end

-- Check for Warp Scroll in inventory (rare/ex item, max 1)
local function CheckWarpScroll()
    local invMgr = AshitaCore:GetMemoryManager():GetInventory();
    local resMgr = AshitaCore:GetResourceManager();
    
    -- Only check main inventory (container 0) for usable scrolls
    for index = 1, 80 do
        local item = invMgr:GetContainerItem(0, index);
        if item.Id == WARP_SCROLL_ID and item.Count > 0 then
            local itemRes = resMgr:GetItemById(WARP_SCROLL_ID);
            return {
                Type = 'scroll',
                Name = itemRes and itemRes.Name[1] or 'Instant Warp',
                TimeUntilUse = 0,  -- Scrolls are instant (no recast)
                Ready = true,
                Container = 0,
                Index = index
            };
        end
    end
    
    return nil;
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if #args == 0 or string.lower(args[1]) ~= '/warpme' then
        return;
    end

    e.blocked = true;

    -- Debug subcommand
    if #args > 1 and string.lower(args[2]) == 'debug' then
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local resMgr = AshitaCore:GetResourceManager();
        local spell = resMgr:GetSpellById(WARP_SPELL_ID);
        
        print(chat.header('WarpMe-Debug') .. chat.message('Main Job: ') .. chat.color1(2, tostring(player:GetMainJob())) .. chat.message(' Level: ') .. chat.color1(2, tostring(player:GetMainJobLevel())));
        print(chat.header('WarpMe-Debug') .. chat.message('Sub Job: ') .. chat.color1(2, tostring(player:GetSubJob())) .. chat.message(' Level: ') .. chat.color1(2, tostring(player:GetSubJobLevel())));
        
        if spell then
            local mReq = spell.LevelRequired[player:GetMainJob() + 1];
            local sReq = spell.LevelRequired[player:GetSubJob() + 1];
            print(chat.header('WarpMe-Debug') .. chat.message('Spell Req: Main=') .. chat.color1(2, tostring(mReq)) .. chat.message(' Sub=') .. chat.color1(2, tostring(sReq)));
        end
        
        local warpSpell = CheckWarpSpell();
        if warpSpell then
            print(chat.header('WarpMe-Debug') .. chat.message('CheckWarpSpell result: ') .. chat.success('Available'));
        else
            print(chat.header('WarpMe-Debug') .. chat.message('CheckWarpSpell result: ') .. chat.error('Not Available'));
        end
        return;
    end

    local bestWarpItem = nil;
        local foundAnyItem = false;

        local time = GetTimeUTC();
        local containers = T{0,8,10,11,12,13,14,15,16};
        local invMgr = AshitaCore:GetMemoryManager():GetInventory();
        local resMgr = AshitaCore:GetResourceManager();
        
        for _,container in ipairs(containers) do
            for index = 1,80 do
                local item = invMgr:GetContainerItem(container, index);
                
                -- Check if this item is in our warp items list
                if warpItems:contains(item.Id) then
                    foundAnyItem = true;
                    local charges = struct.unpack('B', item.Extra, 2);
                    local useTime = (struct.unpack('L', item.Extra, 5) + vanaOffset) - time;
                    if (useTime < 3) then useTime = 0; end

                    -- Check equip delay timer (offset 9 in Extra data when item is equipped)
                    local equipTime = 0;
                    if (item.Flags == 5) then
                        equipTime = (struct.unpack('L', item.Extra, 9) + vanaOffset) - time;
                        if (equipTime < 0) then
                            equipTime = 0;
                        end
                    else
                        -- Item not equipped, will need to use CastDelay from resource
                        local itemResource = resMgr:GetItemById(item.Id);
                        equipTime = itemResource.CastDelay or 0;
                    end
                    
                    -- Add 1 second safety buffer to equip time
                    equipTime = equipTime + 1.0;

                    -- Total cooldown is the max of recast timer and equip timer
                    local totalCooldown = math.max(useTime, equipTime);

                    -- Priority: 1) Lowest total cooldown, 2) Lowest equip time, 3) Most charges
                    if (bestWarpItem == nil) or 
                       (totalCooldown < bestWarpItem.TimeUntilUse) or 
                       ((totalCooldown == bestWarpItem.TimeUntilUse) and (equipTime < bestWarpItem.EquipTime)) or
                       ((totalCooldown == bestWarpItem.TimeUntilUse) and (equipTime == bestWarpItem.EquipTime) and (charges > bestWarpItem.Charges)) then
                        local itemRes = resMgr:GetItemById(item.Id);
                        bestWarpItem = { 
                            Container = container, 
                            Index = index, 
                            TimeUntilUse = totalCooldown, 
                            UseTime = useTime,
                            EquipTime = equipTime,
                            Charges = charges, 
                            ItemId = item.Id, 
                            ItemName = itemRes and itemRes.Name[1] or 'Unknown',
                            IsEquipped = (item.Flags == 5)
                        };
                    end
                end
            end
        end

        -- Check for warp spell
        local warpSpell = CheckWarpSpell();
        
        -- Check for warp scroll
        local warpScroll = CheckWarpScroll();
        
        -- Determine the best warp option based on priority:
        -- 1. Warp spell (if ready)
        -- 2. Equipment items (if ready)
        -- 3. Warp scroll (always ready, consumed)
        
        local chosenOption = nil;
        local chosenType = nil;
        
        -- Priority 1: Warp spell if ready
        if warpSpell and warpSpell.Ready then
            chosenOption = warpSpell;
            chosenType = 'spell';
            print(chat.header('WarpMe') .. chat.message('Using ') .. chat.color1(2, 'Warp spell') .. chat.message(' (ready to cast)'));
        -- Priority 2: Equipment if ready
        elseif bestWarpItem and bestWarpItem.UseTime <= bestWarpItem.EquipTime then
            chosenOption = bestWarpItem;
            chosenType = 'equipment';
        -- Priority 3: Warp scroll as fallback
        elseif warpScroll and warpScroll.Ready then
            chosenOption = warpScroll;
            chosenType = 'scroll';
            print(chat.header('WarpMe') .. chat.message('Using ') .. chat.color1(2, warpScroll.Name));
        -- Nothing ready - report what's coming up
        else
            -- Build status message about what's on cooldown
            local statusParts = T{};
            
            if warpSpell and not warpSpell.Ready then
                statusParts:append(chat.color1(2, 'Warp spell') .. chat.message(': ') .. chat.color1(2, TimerToString(warpSpell.TimeUntilUse)));
            elseif not warpSpell then
                statusParts:append(chat.message('Warp spell: ') .. chat.error('not learned'));
            end
            
            if bestWarpItem then
                statusParts:append(chat.color1(2, bestWarpItem.ItemName) .. chat.message(': ') .. chat.color1(2, TimerToString(bestWarpItem.TimeUntilUse)));
            else
                statusParts:append(chat.message('Equipment: ') .. chat.error('none found'));
            end
            
            if not warpScroll then
                statusParts:append(chat.message('Warp scroll: ') .. chat.error('none in inventory'));
            end
            
            print(chat.header('WarpMe') .. chat.error('No warp method available!'));
            for _, part in ipairs(statusParts) do
                print(chat.header('WarpMe') .. part);
            end
            return;
        end
        
        -- Execute the chosen option
        if chosenType == 'spell' then
            AshitaCore:GetChatManager():QueueCommand(1, '/ma "Warp" <me>');
            return;
            
        elseif chosenType == 'scroll' then
            local itemRes = resMgr:GetItemById(WARP_SCROLL_ID);
            AshitaCore:GetChatManager():QueueCommand(1, '/item "' .. itemRes.Name[1] .. '" <me>');
            return;
            
        elseif chosenType == 'equipment' then
            -- Print found item info
            print(chat.header('WarpMe') .. chat.message('Found: ') .. chat.color1(2, bestWarpItem.ItemName) .. 
                  chat.message(' - Recast: ') .. chat.color1(2, TimerToString(bestWarpItem.UseTime)) .. 
                  chat.message(', Equip Delay: ') .. chat.color1(2, TimerToString(bestWarpItem.EquipTime)) .. 
                  chat.message(', Total Wait: ') .. chat.color1(2, TimerToString(bestWarpItem.TimeUntilUse)));
            
            local itemRes = resMgr:GetItemById(bestWarpItem.ItemId);
            local equipSlot = GetEquipSlotFromBitfield(itemRes.Slots);
            
            if equipSlot == nil then
                print(chat.header('WarpMe') .. chat.error('Could not determine equipment slot for item.'));
                return;
            end
            
            local packet = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
            packet[5] = bestWarpItem.Index;
            packet[6] = equipSlot;
            packet[7] = bestWarpItem.Container;
            AshitaCore:GetPacketManager():AddOutgoingPacket(0x50, packet);

            local outString = chat.header('WarpMe');
            outString = outString .. chat.message('Equipping ');
            outString = outString .. chat.color1(2, bestWarpItem.ItemName);
            outString = outString .. chat.message('.  Charges:');
            outString = outString .. chat.color1(2, tostring(bestWarpItem.Charges));
            outString = outString .. chat.message(' Cooldown:');
            outString = outString .. chat.color1(2, TimerToString(bestWarpItem.TimeUntilUse));
            print(outString);
            
            -- Store pending warp info to use after cooldown
            pendingWarp = {
                Type = 'item',
                ItemId = bestWarpItem.ItemId,
                ItemName = bestWarpItem.ItemName,
                EquipSlot = equipSlot,
                Cooldown = bestWarpItem.TimeUntilUse,
                StartTime = os.clock()
            };
            
            return;
        end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    if pendingWarp == nil then
        return;
    end
    
    -- Check if cooldown has elapsed
    local currentTime = os.clock();
    local elapsed = currentTime - pendingWarp.StartTime;
    local remaining = pendingWarp.Cooldown - elapsed;
    
    -- Show countdown every second (throttled)
    if pendingWarp.lastDebug == nil or (currentTime - pendingWarp.lastDebug) >= 1.0 then
        print(chat.header('WarpMe') .. chat.message('Waiting... ') .. chat.color1(2, TimerToString(math.ceil(remaining))));
        pendingWarp.lastDebug = currentTime;
    end
    
    if elapsed < pendingWarp.Cooldown then
        return;
    end
    
    -- Use the item via command
    AshitaCore:GetChatManager():QueueCommand(1, '/item "' .. AshitaCore:GetResourceManager():GetItemById(pendingWarp.ItemId).Name[1] .. '" <me>');
    
    print(chat.header('WarpMe') .. chat.message('Using ') .. chat.color1(2, pendingWarp.ItemName) .. chat.message('...'));
    
    -- Clear pending warp
    pendingWarp = nil;
end);
