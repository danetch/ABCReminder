-- =========================
-- SavedVariables
-- =========================
ABCReminderDB = ABCReminderDB or {
    enabled = true,
    soundInterval = 1.0,
    enabledInstances = {
        party = true,
        raid = true,
        scenario = true,
        arena = false,
        pvp = false,
        none = false,
        neighborhood = false,
        interior = false,
    },
    statistics = {
        totalCombatTime = 0,
        remindersPlayed = 0,
    },
    soundChannel = "Master",
    soundFile = "WaterDrop",
}
-- =========================
-- sound files
-- =========================
local soundFiles = {
        ["WaterDrop"]="Interface\\AddOns\\ABCReminder\\sound\\WaterDrop.ogg",
        ["SharpPunch"]="Interface\\AddOns\\ABCReminder\\sound\\SharpPunch.ogg",
    }

-- =========================
-- Helpers
-- =========================
local function IsPlayerCasting()
    return UnitCastingInfo("player") or UnitChannelInfo("player")
end

local function IsGCDBlocking()
    local cd = C_Spell.GetSpellCooldown(61304)
    if not cd or cd.startTime == 0 then
        return false
    else
        return true
    end
-- spell queue window cannot be used ./ commenting

    -- local now = GetTime()
    -- local remaining = (cd.startTime + cd.duration) - now
    -- local queueWindow = tonumber(GetCVar("SpellQueueWindow")) / 1000

    -- return remaining > queueWindow
end

local function IsInstanceEnabled()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return false end
    return ABCReminderDB.enabledInstances[instanceType]
end

-- =========================
-- Combat tracking
-- =========================
local inCombat = false
local frame = CreateFrame("Frame")

frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
    end
end)

-- =========================
-- Core logic (OnUpdate)
-- =========================
local CHECK_INTERVAL = 0.1
local checkElapsed = 0
local soundElapsed = 0
local wasEligible = false

frame:SetScript("OnUpdate", function(_, delta)
    if not ABCReminderDB.enabled then return end

    checkElapsed = checkElapsed + delta
    if checkElapsed < CHECK_INTERVAL then return end
    checkElapsed = 0

    local eligible = inCombat
        and IsInstanceEnabled()
        and not IsPlayerCasting()
        and not IsGCDBlocking()
    if not eligible then
        wasEligible = false    
        soundElapsed = 0
        return
    end

    if not wasEligible then
        PlaySoundFile(soundFiles[ABCReminderDB.soundFile], ABCReminderDB.soundChannel)
        wasEligible = true
        soundElapsed = 0
        return
    end
-- This part runs every CHECK_INTERVAL while eligible, so we accumulate time and play sound when it exceeds the interval
    soundElapsed = soundElapsed + CHECK_INTERVAL
    if soundElapsed >= ABCReminderDB.soundInterval then
        PlaySoundFile(soundFiles[ABCReminderDB.soundFile], ABCReminderDB.soundChannel)
        soundElapsed = 0
    end
end)

-- =========================
-- Slash Commands
-- =========================
SLASH_ABCREMINDER1 = "/abcreminder"
SLASH_ABCREMINDER2 = "/ar"


SlashCmdList.ABCREMINDER = function(msg)
    msg = msg:lower()

    if msg == "on" then
        ABCReminderDB.enabled = true
        print("ABCReminder enabled")
    elseif msg == "off" then
        ABCReminderDB.enabled = false
        print("ABCReminder disabled")
    elseif msg:match("^interval") then
        local value = tonumber(msg:match("%d+%.?%d*"))
        if value then
            ABCReminderDB.soundInterval = value
            print("ABCReminder sound interval set to", value)
        end
    elseif msg:match("^toggle") then
        local inst = msg:match("toggle%s+(%S+)")
        if inst and ABCReminderDB.enabledInstances[inst] ~= nil then
            ABCReminderDB.enabledInstances[inst] = not ABCReminderDB.enabledInstances[inst]
            print(inst, "set to", ABCReminderDB.enabledInstances[inst])
        end
    else
        print("ABCReminder commands:")
        print("/ar on | off")
        print("/ar interval <seconds>")
        print("/ar toggle party|raid|arena|pvp|scenario")
    end
end

-- =========================
-- Options Panel
-- =========================
local panel = CreateFrame("Frame", "ABCReminderOptions", InterfaceOptionsFramePanelContainer)
panel.name = "ABCReminder"

panel:SetScript("OnShow", function(self)
    if self.init then return end
    self.init = true

    local title = self:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ABCReminder")

    local enable = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
    enable:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    enable.Text:SetText("Enable addon")
    enable:SetChecked(ABCReminderDB.enabled)
    enable:SetScript("OnClick", function(cb)
        ABCReminderDB.enabled = cb:GetChecked()
    end)

    local separator = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    separator:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 0, -16)
    separator:SetText("Enable in instances:")

    local y = -108
    for inst in pairs(ABCReminderDB.enabledInstances) do
        local cb = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 16, y)
        cb.Text:SetText("Enable in " .. inst)
        cb:SetChecked(ABCReminderDB.enabledInstances[inst])
        cb:SetScript("OnClick", function(btn)
            ABCReminderDB.enabledInstances[inst] = btn:GetChecked()
        end)
        y = y - 30
    end

    local slider = CreateFrame("Slider", nil, self, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 16, y - 16)
    slider:SetMinMaxValues(1, 10)
    slider:SetValueStep(0.5)
    slider:SetValue(ABCReminderDB.soundInterval)
    slider:SetObeyStepOnDrag(true)
    slider.Text:SetText("Sound Interval (seconds)")
    slider.Low:SetText("1")
    slider.High:SetText("10")
    slider:SetScript("OnValueChanged", function(_, val)
        ABCReminderDB.soundInterval = val
    end)

    local channelLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    channelLabel:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -16)
    channelLabel:SetText("Sound Channel:")


    local soundChannels = {"Master", "SFX", "Music", "Ambience"}
    local channelDropdown = CreateFrame("Frame", "ABCReminderChannelDropdown", self, "UIDropDownMenuTemplate")
    channelDropdown:SetPoint("TOPLEFT", channelLabel, "BOTTOMLEFT", 0, -16)
    channelDropdown.initialize = function(self, level)
        local info = UIDropDownMenu_CreateInfo()
        info.func = function(_, arg1)
            ABCReminderDB.soundChannel = arg1
            UIDropDownMenu_SetSelectedValue(channelDropdown, arg1)
        end
        for _, channel in ipairs(soundChannels) do
            info.text = channel
            info.arg1 = channel
            info.checked = (ABCReminderDB.soundChannel == channel)
            UIDropDownMenu_AddButton(info, level)
        end
    end
    UIDropDownMenu_SetText(channelDropdown, ABCReminderDB.soundChannel)

    local soundLabel = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    soundLabel:SetPoint("TOPLEFT", channelDropdown, "BOTTOMLEFT", 0, -16)
    soundLabel:SetText("Sound File:")
    
    local soundDropdown = CreateFrame("Frame", "ABCReminderSoundDropdown", self, "UIDropDownMenuTemplate")
    soundDropdown:SetPoint("TOPLEFT", soundLabel, "BOTTOMLEFT", 0, -16)
    soundDropdown.initialize = function(self, level)
        local info = UIDropDownMenu_CreateInfo()
        info.func = function(_, arg1)
            ABCReminderDB.soundFile = arg1
            UIDropDownMenu_SetSelectedValue(soundDropdown, arg1)
        end
        for name, file in pairs(soundFiles) do
            info.text = name
            info.arg1 = name
            info.checked = (ABCReminderDB.soundFile == name)
            UIDropDownMenu_AddButton(info, level)
        end
    end
    UIDropDownMenu_SetText(soundDropdown, ABCReminderDB.soundFile)
 


end)
local category, layout = Settings.RegisterCanvasLayoutCategory(panel, panel.name, panel.name);
category.ID = panel.name;
Settings.RegisterAddOnCategory(category);

--InterfaceOptions_AddCategory(panel)
