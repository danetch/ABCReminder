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
    soundFile = "Interface\\AddOns\\ABCReminder\\sound\\WaterDrop.ogg",
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
    end

    local now = GetTime()
    local remaining = (cd.startTime + cd.duration) - now
    local queueWindow = tonumber(GetCVar("SpellQueueWindow")) / 1000

    return remaining > queueWindow
end

local function IsInstanceEnabled()
    local inInstance, instanceType = IsInInstance()
    print("Instance check:", inInstance, instanceType)
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

frame:SetScript("OnUpdate", function(_, delta)
    if not ABCReminderDB.enabled then return end

    checkElapsed = checkElapsed + delta
    if checkElapsed < CHECK_INTERVAL then return end
    checkElapsed = 0

    if not inCombat
        or not IsInstanceEnabled()
        or IsPlayerCasting()
        or IsGCDBlocking()
    then
        soundElapsed = 0
        return
    end

    soundElapsed = soundElapsed + CHECK_INTERVAL
    if soundElapsed >= ABCReminderDB.soundInterval then
        PlaySoundFile(ABCReminderDB.soundFile, ABCReminderDB.soundChannel)
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

    local y = -60
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
    slider:SetPoint("TOPLEFT", 16, y - 10)
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
end)
local category, layout = Settings.RegisterCanvasLayoutCategory(panel, panel.name, panel.name);
category.ID = panel.name;
Settings.RegisterAddOnCategory(category);

--InterfaceOptions_AddCategory(panel)
