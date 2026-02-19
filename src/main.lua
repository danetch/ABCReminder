-- main.lua
local abcReminder, abcReminderTable= ...
local globalCooldownMax = 750
local function initialize()
-- read saved variables or set defaults
    if not ABCReminderDB then   
        ABCReminderDB = {
            -- Default settings can be defined here
            enabled = true,
            soundFile = "Interface\\AddOns\\ABCReminder\\sound\\WaterDrop.ogg",
            soundChannel = "Master",
        }
    end
end

abcReminderTable.dump = function (o)
    if type(o) == 'table' then
       local s = '{ '
       for k,v in pairs(o) do
          if type(k) ~= 'number' then k = '"'..k..'"' end
          s = s .. '['..k..'] = ' .. abcReminderTable.dump(v) .. ','
       end
       return s .. '} '
    else
       return tostring(o)
    end
end

-- Initialize the addon
local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        initialize()
    end
    if event == "ACTIONBAR_UPDATE_COOLDOWN" then
        globalCooldownMax = C_Spell.GetSpellCooldown(61304).duration * 1000
    end
    -- Handle events here
    if event == "PLAYER_REGEN_DISABLED" then
        -- check that we are in an instance 
        if IsInInstance() and not UnitIsDeadOrGhost("player") then
            -- if the player is not actively casting, and the gcd is ready :
            -- we note the time elapsed to gather statistics, and play the sound
            local initialTime = GetTime()*1000
            while UnitAffectingCombat("player") do
                local currentTime = GetTime()*1000
                local info = C_Spell.GetSpellCooldown(61304)
                local gcd = info.duration * 1000
                local castTime = 0
                local spell, _,_,_, endTimeMs = UnitChannelInfo("player")
                if spell then
                    castTime = endTimeMs - currentTime
                end
                local waitTime = math.max(gcd, castTime)
                -- checking if the sufficient time has elapsed to play the sound
                if  currentTime - initialTime > globalCooldownMax then
                    initialTime = currentTime
                    if not UnitIsCasting("player") and C_Spell.GetSpellCooldown(61304) == 0 then
                    playSound()
                end
                else
                    C_Timer.After(waitTime/1000, function() end) -- wait a bit before checking again
                end

                
            end
        end
    end
end



local function playSound()
    PlaySoundFile(ABCReminderDB.soundFile, ABCReminderDB.soundChannel)
end

-- Register events
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("ADDON_LOADED")
--frame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
frame:SetScript("OnEvent", OnEvent)
