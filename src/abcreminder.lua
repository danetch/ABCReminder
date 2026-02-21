-- =========================
-- SavedVariables
-- =========================
ABCReminderDB = ABCReminderDB or {
    clipSound = true,
    soundInterval = 1.0,
    showSQW = true,
    alwaysShowSQW = true,
    enabledInstances = {
        party = true, raid = true, scenario = true,
        arena = false, pvp = false, none = false,
    },
    soundChannel = "Master",
    soundFile = "WaterDrop",
    sqwPosition = { point = "CENTER", x = 0, y = -150 },
    statsPosition = { point = "LEFT",   x = 40, y = 0    },
    bossStatsPosition = { point = "RIGHT", x = -40, y = 0 },
    intervalStatsDisplay = 15,
}

CharABCRDB = CharABCRDB or {
    enabled = true,
    statistics = { perInstance = {} },
    sessionTrivial = { totalTime = 0, idleTime = 0 },
}

local isMovingSQW = false

-- =========================
-- Helpers & Logic
-- =========================
local soundFiles = {
    ["WaterDrop"] = "Interface\\AddOns\\ABCReminder\\sound\\WaterDrop.ogg",
    ["SharpPunch"] = "Interface\\AddOns\\ABCReminder\\sound\\SharpPunch.ogg",
}

local function GetSQW()
    return (tonumber(GetCVar("SpellQueueWindow")) or 400) / 1000
end

local function GetCurrentActionProgress()
    local name, _, _, startTimeMS, endTimeMS = UnitCastingInfo("player")
    if not name then name, _, _, startTimeMS, endTimeMS = UnitChannelInfo("player") end
    if name then return (endTimeMS / 1000) - GetTime() end

    local cd = C_Spell.GetSpellCooldown(61304)
    if cd and cd.startTime > 0 and cd.duration > 0 then
        return (cd.startTime + cd.duration) - GetTime()
    end
    return nil
end

local function ValidatePosition(pos, default)
    if not pos or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
        return default
    end
    return pos
end

-- ==========================================
-- UI Factory: Create Stats Frame
-- ==========================================
local historyKeys = {}
local currentIndex = 0

local function UpdateHistoryKeys()
    wipe(historyKeys)
    for name in pairs(CharABCRDB.statistics.perInstance) do
        table.insert(historyKeys, name)
    end
    -- Tri : Raid Bosses d'abord (commencent par "Boss:"), puis le reste (Donjons)
    table.sort(historyKeys, function(a, b)
        local aIsBoss = a:find("Boss:") and 1 or 0
        local bIsBoss = b:find("Boss:") and 1 or 0
        if aIsBoss ~= bIsBoss then return aIsBoss > bIsBoss end
        return a < b
    end)
end

local function CreateBaseStatsFrame(name, globalPosKey)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(220, 150)
    f:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0, 0, 0, 0.85)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    f:Hide()
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        ABCReminderDB[globalPosKey] = { point = point, x = x, y = y }
    end)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -10)

    f.separator = f:CreateTexture(nil, "ARTWORK")
    f.separator:SetSize(200, 1)
    f.separator:SetPoint("TOP", f.title, "BOTTOM", 0, -6)
    f.separator:SetColorTexture(0.4, 0.4, 0.4, 0.8)

    f.content = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.content:SetPoint("TOPLEFT", f.separator, "BOTTOMLEFT", 4, -10)
    f.content:SetWidth(196)
    f.content:SetJustifyH("LEFT")

    return f
end

local statsTable = CreateBaseStatsFrame("ABCReminderStatsTable", "statsPosition")
local bossStatsTable = CreateBaseStatsFrame("ABCReminderBossStatsTable", "bossStatsPosition")

-- Bouton Reset Session (sur la table Trivial)
statsTable.resetBtn = CreateFrame("Button", nil, statsTable, "UIPanelButtonTemplate")
statsTable.resetBtn:SetSize(120, 20)
statsTable.resetBtn:SetPoint("BOTTOM", 0, 12)
statsTable.resetBtn:SetText("Reset Session")
statsTable.resetBtn:SetScript("OnClick", function()
    CharABCRDB.sessionTrivial = { totalTime = 0, idleTime = 0 }
    statsTable.content:SetText("|cff00ff00Session Statistics Reset!|r")
end)

-- Ajustements spécifiques pour la fenêtre de Boss
bossStatsTable:SetSize(280, 160) -- Plus large et un peu plus haute
bossStatsTable.title:SetWidth(250) -- Permet au titre de prendre presque toute la largeur
bossStatsTable.title:SetMaxLines(2) -- Autorise le passage à la ligne
bossStatsTable.separator:SetSize(250, 1) -- Séparateur plus long
bossStatsTable.content:SetWidth(250)    -- Contenu plus large
bossStatsTable.title:SetJustifyV("MIDDLE")

-- Bouton Fermer (X) pour la fenêtre Boss
bossStatsTable.closeBtn = CreateFrame("Button", nil, bossStatsTable, "UIPanelCloseButton")
bossStatsTable.closeBtn:SetPoint("TOPRIGHT", bossStatsTable, "TOPRIGHT", -3, -4)
bossStatsTable.closeBtn:SetScript("OnClick", function() bossStatsTable:Hide() end)

-- Navigation Historique (ajustée pour la nouvelle largeur)
local function DisplayHistory(index)
    if index == 0 or #historyKeys == 0 then
        bossStatsTable.title:SetText("No History")
        bossStatsTable.content:SetText("No data saved yet.")
        return
    end
    local name = historyKeys[index]
    local data = CharABCRDB.statistics.perInstance[name]
    
    -- Formatage du titre avec couleur et retour à la ligne géré par SetMaxLines
    bossStatsTable.title:SetText("|cff00ccff" .. name .. "|r")
    
    bossStatsTable.content:SetText(string.format(
        "Personal Best: |cff00ff00%.1f%%|r\n\nTotal Time: %dm %ds\nTotal Idle: %dm %ds",
        data.bestRatio or 0,
        math.floor(data.totalTime / 60), data.totalTime % 60,
        math.floor(data.idleTime / 60), data.idleTime % 60
    ))
end

bossStatsTable.prevBtn = CreateFrame("Button", nil, bossStatsTable, "UIPanelButtonTemplate")
bossStatsTable.prevBtn:SetSize(30, 22); bossStatsTable.prevBtn:SetText("<")
bossStatsTable.prevBtn:SetPoint("BOTTOMLEFT", 12, 12)
bossStatsTable.prevBtn:SetScript("OnClick", function()
    UpdateHistoryKeys()
    if #historyKeys == 0 then return end
    currentIndex = (currentIndex <= 1) and #historyKeys or currentIndex - 1
    DisplayHistory(currentIndex)
end)

bossStatsTable.nextBtn = CreateFrame("Button", nil, bossStatsTable, "UIPanelButtonTemplate")
bossStatsTable.nextBtn:SetSize(30, 22); bossStatsTable.nextBtn:SetText(">")
bossStatsTable.nextBtn:SetPoint("BOTTOMRIGHT", -12, 12)
bossStatsTable.nextBtn:SetScript("OnClick", function()
    UpdateHistoryKeys()
    if #historyKeys == 0 then return end
    currentIndex = (currentIndex >= #historyKeys) and 1 or currentIndex + 1
    DisplayHistory(currentIndex)
end)
-- =========================
-- UI: SQW Circular Visual
-- =========================
local sqwFrame = CreateFrame("Frame", "ABCReminderSQW", UIParent)
sqwFrame:SetSize(50, 50)
sqwFrame:SetMovable(true)
sqwFrame:EnableMouse(false)
sqwFrame:RegisterForDrag("LeftButton")
sqwFrame:SetScript("OnDragStart", sqwFrame.StartMoving)
sqwFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    ABCReminderDB.sqwPosition = { point = point, x = x, y = y }
end)

sqwFrame.fill = sqwFrame:CreateTexture(nil, "BORDER")
sqwFrame.fill:SetAllPoints()
sqwFrame.fill:SetTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")

sqwFrame.cd = CreateFrame("Cooldown", nil, sqwFrame, "CooldownFrameTemplate")
sqwFrame.cd:SetAllPoints()
sqwFrame.cd:SetDrawEdge(false)
sqwFrame.cd:SetDrawSwipe(true)
sqwFrame.cd:SetSwipeColor(0, 0, 0, 1)
sqwFrame.cd:SetReverse(false)
sqwFrame.cd:SetHideCountdownNumbers(true)
sqwFrame.cd:SetSwipeTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
sqwFrame.cd:SetDrawBling(false)

sqwFrame.moveTex = sqwFrame:CreateTexture(nil, "OVERLAY")
sqwFrame.moveTex:SetAllPoints()
sqwFrame.moveTex:SetTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
sqwFrame.moveTex:SetVertexColor(0, 0.5, 1, 0.5)
sqwFrame.moveTex:Hide()

local function UpdateSQWVisual(remaining)
    if not ABCReminderDB.showSQW or isMovingSQW then return end
    local threshold = GetSQW()
    local inWindow   = remaining and remaining > 0 and remaining <= threshold
    local showGray   = ABCReminderDB.alwaysShowSQW and remaining and remaining > threshold

    if inWindow then
        sqwFrame.fill:SetVertexColor(0, 1, 0, 0.85)
        sqwFrame.cd:SetSwipeColor(0, 0, 0, 0.85)
        sqwFrame.cd:SetCooldown(GetTime() - (threshold - remaining), threshold)
        sqwFrame:Show()
    elseif showGray then
        sqwFrame.fill:SetVertexColor(0.3, 0.3, 0.3, 0.4)
        sqwFrame.cd:SetCooldown(0, 0)
        sqwFrame:Show()
    else sqwFrame:Hide() end
end

-- =========================
-- Engine & Events
-- =========================
local frame = CreateFrame("Frame")
local inCombat, sessionCombatTime, sessionIdleTime = false, 0, 0
local checkElapsed, soundElapsed, wasEligible, soundHandle = 0, 0, false, nil

local function ProcessCombatEnd(encounterName)
    local name, instanceType, diffID = GetInstanceInfo()
    local isPersist = (instanceType == "raid" and encounterName ~= nil ) or (diffID == 8)
    local diffName = GetDifficultyInfo(diffID) or tostring(diffID)
    local key = encounterName and ("Boss: " .. encounterName .. " [" .. diffName .. "]") or name    
    ShowPerformanceTable(key, sessionIdleTime, sessionCombatTime, isPersist)
    sessionCombatTime, sessionIdleTime = 0, 0
end

frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        CharABCRDB.sessionTrivial = CharABCRDB.sessionTrivial or { totalTime = 0, idleTime = 0 }
        ABCReminderDB.intervalStatsDisplay = ABCReminderDB.intervalStatsDisplay or 15
        
        ABCReminderDB.sqwPosition = ValidatePosition(ABCReminderDB.sqwPosition, { point = "CENTER", x = 0, y = -150 })
        ABCReminderDB.statsPosition = ValidatePosition(ABCReminderDB.statsPosition, { point = "LEFT", x = 40, y = 0 })
        ABCReminderDB.bossStatsPosition = ValidatePosition(ABCReminderDB.bossStatsPosition, { point = "RIGHT", x = -40, y = 0 })

        sqwFrame:ClearAllPoints()
        local p = ABCReminderDB.sqwPosition
        sqwFrame:SetPoint(p.point, UIParent, p.point, p.x, p.y)
        
        statsTable:ClearAllPoints()
        local s = ABCReminderDB.statsPosition
        statsTable:SetPoint(s.point, UIParent, s.point, s.x, s.y)

        bossStatsTable:ClearAllPoints()
        local b = ABCReminderDB.bossStatsPosition
        bossStatsTable:SetPoint(b.point, UIParent, b.point, b.x, b.y)
    elseif event == "PLAYER_REGEN_DISABLED" then inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then inCombat = false; ProcessCombatEnd()
    elseif event == "ENCOUNTER_END" then ProcessCombatEnd(select(2, ...)) end
end)

frame:SetScript("OnUpdate", function(_, delta)
    if not CharABCRDB.enabled then sqwFrame:Hide() return end
    if isMovingSQW then
        sqwFrame:Show(); sqwFrame.moveTex:Show()
        sqwFrame.fill:SetVertexColor(0, 0.5, 1, 0.7); sqwFrame.cd:SetCooldown(0, 0)
    else
        sqwFrame.moveTex:Hide(); UpdateSQWVisual(GetCurrentActionProgress())
    end

    if inCombat then
        sessionCombatTime = sessionCombatTime + delta
        local isBusy = UnitCastingInfo("player") or UnitChannelInfo("player")
        local cd = C_Spell.GetSpellCooldown(61304)
        if not isBusy and not (cd and cd.startTime > 0) then sessionIdleTime = sessionIdleTime + delta end

        checkElapsed = checkElapsed + delta
        if checkElapsed >= 0.1 then
            checkElapsed = 0
            local _, it = IsInInstance()
            if ABCReminderDB.enabledInstances[it or "none"] and not isBusy and not (cd and cd.startTime > 0) then
                if not wasEligible or soundElapsed >= ABCReminderDB.soundInterval then
                    _, soundHandle = PlaySoundFile(soundFiles[ABCReminderDB.soundFile], ABCReminderDB.soundChannel)
                    wasEligible, soundElapsed = true, 0
                else soundElapsed = soundElapsed + 0.1 end
            else
                if ABCReminderDB.clipSound and soundHandle and (isBusy or (cd and cd.startTime > 0)) then StopSound(soundHandle); soundHandle = nil end
                wasEligible, soundElapsed = false, 0
            end
        end
    end
end)

-- =========================
-- Options Panel
-- =========================
local panel = CreateFrame("Frame", "ABCReminderOptions")
panel.name = "ABCReminder"

panel:SetScript("OnShow", function(self)
    if self.init then return end
    self.init = true
    
    local title = self:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16); title:SetText("ABCReminder")

    local decor = self:CreateTexture(nil, "BACKGROUND")
    decor:SetTexture("Interface\\AddOns\\ABCReminder\\img\\drops.tga")
    decor:SetPoint("BOTTOMRIGHT", -16, 16); decor:SetSize(128, 128); decor:SetAlpha(0.3)

    local charEnable = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
    charEnable:SetPoint("TOPLEFT", 16, -50); charEnable.Text:SetText("Enable for this character")
    charEnable:SetChecked(CharABCRDB.enabled); charEnable:SetScript("OnClick", function(cb) CharABCRDB.enabled = cb:GetChecked() end)

    local y = -85
    local i = 1
    for inst in pairs(ABCReminderDB.enabledInstances) do
        local cb = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
        if i % 2 ~= 0 then cb:SetPoint("TOPLEFT", 16, y) else cb:SetPoint("TOPLEFT", 180, y) y = y - 28 end
        i = i + 1
        cb.Text:SetText(inst == "none" and "open world" or inst)
        cb:SetChecked(ABCReminderDB.enabledInstances[inst])
        cb:SetScript("OnClick", function(btn) ABCReminderDB.enabledInstances[inst] = btn:GetChecked() end)
    end

    local slider = CreateFrame("Slider", "ABCReminderSlider", self, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 16, y - 30)
    slider:SetMinMaxValues(1.0, 10.0); slider:SetValueStep(0.5); slider:SetObeyStepOnDrag(true)
    slider:SetValue(ABCReminderDB.soundInterval)
    slider.Text:SetText("Sound Interval (seconds)")
    slider.Low:SetText("1"); slider.High:SetText("10")
    local valTxt = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valTxt:SetPoint("TOP", slider, "BOTTOM", 0, -2); valTxt:SetText(string.format("%.1f s", ABCReminderDB.soundInterval))
    slider:SetScript("OnValueChanged", function(_, v) ABCReminderDB.soundInterval = v; valTxt:SetText(string.format("%.1f s", v)) end)

    local clipCb = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
    clipCb:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", -8, -25); clipCb.Text:SetText("Stop sound when casting resumes")
    clipCb:SetChecked(ABCReminderDB.clipSound); clipCb:SetScript("OnClick", function(cb) ABCReminderDB.clipSound = cb:GetChecked() end)

    local chanDrop = CreateFrame("Frame", "ABCReminderChanDrop", self, "UIDropDownMenuTemplate")
    chanDrop:SetPoint("TOPLEFT", clipCb, "BOTTOMLEFT", -15, -15)
    UIDropDownMenu_Initialize(chanDrop, function(self, level)
        for _, c in ipairs({"Master", "SFX", "Music", "Ambience"}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.arg1, info.checked = c, c, (ABCReminderDB.soundChannel == c)
            info.func = function(_, a1) ABCReminderDB.soundChannel = a1; UIDropDownMenu_SetText(chanDrop, a1) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(chanDrop, 100); UIDropDownMenu_SetText(chanDrop, ABCReminderDB.soundChannel)

    local sndDrop = CreateFrame("Frame", "ABCReminderSndDrop", self, "UIDropDownMenuTemplate")
    sndDrop:SetPoint("TOPLEFT", chanDrop, "BOTTOMLEFT", 0, -10)
    UIDropDownMenu_Initialize(sndDrop, function(self, level)
        for name in pairs(soundFiles) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.arg1, info.checked = name, name, (ABCReminderDB.soundFile == name)
            info.func = function(_, a1) ABCReminderDB.soundFile = a1; UIDropDownMenu_SetText(sndDrop, a1) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(sndDrop, 100); UIDropDownMenu_SetText(sndDrop, ABCReminderDB.soundFile)

    local testBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    testBtn:SetPoint("LEFT", sndDrop, "RIGHT", 10, 2); testBtn:SetSize(80, 22); testBtn:SetText("Test Sound")
    testBtn:SetScript("OnClick", function() PlaySoundFile(soundFiles[ABCReminderDB.soundFile], ABCReminderDB.soundChannel) end)

    local sqwCb = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
    sqwCb:SetPoint("TOPLEFT", sndDrop, "BOTTOMLEFT", 15, -15); sqwCb.Text:SetText("Show Spell Queue Window visual")
    sqwCb:SetChecked(ABCReminderDB.showSQW); sqwCb:SetScript("OnClick", function(cb) ABCReminderDB.showSQW = cb:GetChecked() end)

    local sqwMiniIcon = sqwCb:CreateTexture(nil, "OVERLAY")
    sqwMiniIcon:SetTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
    sqwMiniIcon:SetSize(12, 12)
    sqwMiniIcon:SetPoint("LEFT", sqwCb.Text, "RIGHT", 6, 0)
    sqwMiniIcon:SetVertexColor(0, 1, 0, 1)

    local resetPosBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    resetPosBtn:SetPoint("TOPLEFT", sqwMiniIcon, "TOPRIGHT", 6, -10)
    resetPosBtn:SetSize(130, 22)
    resetPosBtn:SetText("Reset SQW Position")
    resetPosBtn:SetScript("OnClick", function()
        ABCReminderDB.sqwPosition = { point = "CENTER", x = 0, y = -150 }
        sqwFrame:ClearAllPoints()
        sqwFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)end)

    local alwaysCb = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
    alwaysCb:SetPoint("TOPLEFT", sqwCb, "BOTTOMLEFT", 20, -4); alwaysCb.Text:SetText("Always show (in combat - Grayed)")
    alwaysCb:SetChecked(ABCReminderDB.alwaysShowSQW);
    alwaysCb:SetScript("OnClick", function(cb) ABCReminderDB.alwaysShowSQW = cb:GetChecked() end)

    -- Slider Stats (Nom original : statsDisplay)
    local statsDisplay = CreateFrame("Slider", "ABCRStatsDur", self, "OptionsSliderTemplate")
    statsDisplay:SetPoint("TOPLEFT", alwaysCb, "BOTTOMLEFT", -20, -30)
    statsDisplay:SetMinMaxValues(0, 30); statsDisplay:SetValueStep(5); statsDisplay:SetObeyStepOnDrag(true)
    statsDisplay:SetValue(ABCReminderDB.intervalStatsDisplay)
    statsDisplay.Text:SetJustifyH("LEFT")
    statsDisplay.Text:ClearAllPoints()
    statsDisplay.Text:SetPoint("TOPLEFT", statsDisplay, "TOPLEFT", 0, 20)
    statsDisplay.Text:SetText("Stats display duration : 0 means permanent")
    statsDisplay.Low:SetText("0"); statsDisplay.High:SetText("30")
    local statsValTxt = statsDisplay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statsValTxt:SetPoint("TOP", statsDisplay, "BOTTOM", 0, -2); statsValTxt:SetText(string.format("%.1f s", ABCReminderDB.intervalStatsDisplay))
    statsDisplay:SetScript("OnValueChanged", function(_, v) ABCReminderDB.intervalStatsDisplay = v; statsValTxt:SetText(string.format("%.1f s", v)) end)
end)

local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
Settings.RegisterAddOnCategory(category)

SLASH_ABCREMINDER1 = "/ar"
SlashCmdList.ABCREMINDER = function(msg)
    if msg == "move" then
        isMovingSQW = not isMovingSQW
        sqwFrame:EnableMouse(isMovingSQW)
        sqwFrame:SetMovable(isMovingSQW)
        print("ABC: Move Mode "..(isMovingSQW and "|cff00ff00ON|r (Drag the blue box)" or "|cffff0000OFF|r"))
    elseif msg == "stats" or msg == "history" then
        UpdateHistoryKeys() -- Rafraîchit la liste des boss/donjons
        if #historyKeys > 0 then
            if currentIndex == 0 then currentIndex = 1 end -- Initialise l'index si besoin
            DisplayHistory(currentIndex)
            ABCReminderBossStatsTable:Show()
            print("ABC: Showing recorded statistics.")
        else
        print("ABC: No records found yet.")
        end
    elseif msg == "reset session" then
        CharABCRDB.sessionTrivial = { totalTime = 0, idleTime = 0 }
        print("ABC: Session reset.")
    elseif msg == "session" then
        ShowPerformanceTable("Last Session", 0, 0, false)
    else Settings.OpenToCategory(panel.name) end
end