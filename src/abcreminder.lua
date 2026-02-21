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

-- =========================
-- UI: Stats Table
-- =========================
local statsTable = CreateFrame("Frame", "ABCReminderStatsTable", UIParent, "BackdropTemplate")
statsTable:SetSize(220, 140)
statsTable:SetPoint("LEFT", 40, 0)
statsTable:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
statsTable:SetBackdropColor(0, 0, 0, 0.85)
statsTable:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
statsTable:Hide()
statsTable:SetMovable(true)
statsTable:EnableMouse(true)
statsTable:RegisterForDrag("LeftButton")
statsTable:SetScript("OnDragStart", statsTable.StartMoving)
statsTable:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    ABCReminderDB.statsPosition = { point = point, x = x, y = y }
end)

-- Titre
statsTable.title = statsTable:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statsTable.title:SetPoint("TOP", 0, -10)

-- Séparateur
statsTable.separator = statsTable:CreateTexture(nil, "ARTWORK")
statsTable.separator:SetSize(200, 1)
statsTable.separator:SetPoint("TOP", 0, -24)
statsTable.separator:SetColorTexture(0.4, 0.4, 0.4, 0.8)

-- Contenu
statsTable.content = statsTable:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statsTable.content:SetPoint("TOPLEFT", 12, -32)
statsTable.content:SetWidth(196)
statsTable.content:SetJustifyH("LEFT")

-- =========================
-- Logic: ShowPerformanceTable
-- =========================
local function ShowPerformanceTable(name, currentIdle, currentTotal, shouldPersist)
    local ratio   = currentTotal > 0 and (currentIdle / currentTotal) * 100 or 0
    local bestStr = "|cffaaaaaan/a (trivial)|r"
    local isNewRecord = false

    if shouldPersist then
        if not CharABCRDB.statistics.perInstance[name] then
            CharABCRDB.statistics.perInstance[name] = { totalTime = 0, idleTime = 0, bestRatio = 100 }
        end
        local data = CharABCRDB.statistics.perInstance[name]

        if ratio < (data.bestRatio or 100) then
            data.bestRatio = ratio
            isNewRecord    = true
            PlaySound(SOUNDKIT.UI_GARRISON_GUEST_GREETING, ABCReminderDB.soundChannel)
        end

        data.totalTime = data.totalTime + currentTotal
        data.idleTime  = data.idleTime  + currentIdle
        bestStr = string.format("|cff00ff00%.1f%%|r", data.bestRatio)
        statsTable.content:SetText(string.format(
        "Idle this run:  |cffffffff%.1f%%|r\n\nPersonal Best:  %s%s",
        ratio,
        bestStr,
        isNewRecord and "\n\n|cffFFD700New Personal Record!|r" or ""
    ))
    else
         -- Contenu trivial : on accumule dans la session persistante
        local st = CharABCRDB.sessionTrivial
        st.totalTime = st.totalTime + currentTotal
        st.idleTime  = st.idleTime  + currentIdle

        local sessionRatio = st.totalTime > 0 and (st.idleTime / st.totalTime) * 100 or 0
        bestStr = string.format("|cffaaaaaa%.1f%% (session)|r", sessionRatio)
        statsTable.content:SetText(string.format(
        "Idle this run:  |cffffffff%.1f%%|r\n\nSession avg:  %s",
        ratio, bestStr
    ))
    end

    -- Titre : doré si record, blanc sinon
    statsTable.title:SetText(isNewRecord
        and "|cffFFD700★ " .. name .. " ★|r"
        or  name)

    -- Ajuster la hauteur si record (ligne supplémentaire)
    statsTable:SetHeight(isNewRecord and 165 or 140)

    statsTable:Show()
    if ABCReminderDB.intervalStatsDisplay and ABCReminderDB.intervalStatsDisplay > 0 then
        C_Timer.After(ABCReminderDB.intervalStatsDisplay, function() statsTable:Hide() end)
    end
end


-- =========================
-- UI: SQW Circular Visual (Arc / Cooldown sweep)
-- =========================

-- Frame conteneur
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

-- Texture de fond (cercle plein, couleur de base)
--sqwFrame.bg = sqwFrame:CreateTexture(nil, "BACKGROUND")
--sqwFrame.bg:SetAllPoints()
--sqwFrame.bg:SetTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
--sqwFrame.bg:SetVertexColor(0.15, 0.15, 0.15, 0.6) -- gris foncé quasi transparent

-- Texture overlay colorée (visible en dehors du sweep)
sqwFrame.fill = sqwFrame:CreateTexture(nil, "BORDER")
sqwFrame.fill:SetAllPoints()
sqwFrame.fill:SetTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
sqwFrame.fill:SetVertexColor(0, 1, 0, 0.85) -- vert

-- Frame Cooldown : c'est lui qui fait le "sweep" (masque le fill au fur et à mesure)
sqwFrame.cd = CreateFrame("Cooldown", nil, sqwFrame, "CooldownFrameTemplate")
sqwFrame.cd:SetAllPoints()
sqwFrame.cd:SetDrawEdge(false)
sqwFrame.cd:SetDrawSwipe(true)
sqwFrame.cd:SetSwipeColor(0, 0, 0, 1)    -- noir opaque = masque le fill
sqwFrame.cd:SetReverse(false)             -- false = le sweep part de 360° et se réduit
sqwFrame.cd:SetHideCountdownNumbers(true)
sqwFrame.cd:SetSwipeTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
sqwFrame.cd:SetDrawBling(false)

-- Highlight mode déplacement
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
        -- Arc vert qui se réduit proportionnellement au temps restant
        local ratio = remaining / threshold          -- 1.0 → 0.0
        local fakeDuration = threshold              -- durée "totale" fictive
        local fakeStart = GetTime() - (threshold - remaining)  -- start fictif cohérent

        sqwFrame.fill:SetVertexColor(0, 1, 0, 0.85)
        sqwFrame.cd:SetSwipeColor(0, 0, 0, 0.85)
        sqwFrame.cd:SetCooldown(fakeStart, fakeDuration)
        sqwFrame:Show()

    elseif showGray then
        -- Cercle complet grisé (hors fenêtre SQW mais alwaysShow actif)
        sqwFrame.fill:SetVertexColor(0.3, 0.3, 0.3, 0.4)
        sqwFrame.cd:SetCooldown(0, 0)   -- pas de sweep = cercle plein
        sqwFrame:Show()

    else
        sqwFrame:Hide()
    end
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
        local pos = ABCReminderDB.sqwPosition or { point = "CENTER", x = 0, y = -150 }
        sqwFrame:ClearAllPoints()
        sqwFrame:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
        local spos = ABCReminderDB.statsPosition or { point = "LEFT",   x = 40, y = 0    }
        if spos then
            statsTable:ClearAllPoints()
            statsTable:SetPoint(spos.point, UIParent, spos.point, spos.x, spos.y)
        end
    elseif event == "PLAYER_REGEN_DISABLED" then inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then inCombat = false; ProcessCombatEnd()
    elseif event == "ENCOUNTER_END" then ProcessCombatEnd(select(2, ...)) end
end)

frame:SetScript("OnUpdate", function(_, delta)
    if not CharABCRDB.enabled then sqwFrame:Hide() return end

    if isMovingSQW then
        sqwFrame:Show()
        sqwFrame.moveTex:Show()
        sqwFrame.fill:SetVertexColor(0, 0.5, 1, 0.7)
        sqwFrame.cd:SetCooldown(0, 0)
    else
        sqwFrame.moveTex:Hide()
        --sqwFrame.bg:Hide()   -- le bg de l'ancien code, on le laisse masqué
        UpdateSQWVisual(GetCurrentActionProgress())
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

    -- Slider corrigé (1.0 à 10.0)
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
    UIDropDownMenu_SetWidth(chanDrop, 100); UIDropDownMenu_SetText(chanDrop, ABCReminderDB.soundChannel)
    UIDropDownMenu_Initialize(chanDrop, function(self, level)
        for _, c in ipairs({"Master", "SFX", "Music", "Ambience"}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.arg1, info.checked = c, c, (ABCReminderDB.soundChannel == c)
            info.func = function(_, a1) ABCReminderDB.soundChannel = a1; UIDropDownMenu_SetText(chanDrop, a1) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    local sndDrop = CreateFrame("Frame", "ABCReminderSndDrop", self, "UIDropDownMenuTemplate")
    sndDrop:SetPoint("TOPLEFT", chanDrop, "BOTTOMLEFT", 0, -10)
    UIDropDownMenu_SetWidth(sndDrop, 100); UIDropDownMenu_SetText(sndDrop, ABCReminderDB.soundFile)
    UIDropDownMenu_Initialize(sndDrop, function(self, level)
        for name in pairs(soundFiles) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.arg1, info.checked = name, name, (ABCReminderDB.soundFile == name)
            info.func = function(_, a1) ABCReminderDB.soundFile = a1; UIDropDownMenu_SetText(sndDrop, a1) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

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
    alwaysCb:SetPoint("TOPLEFT", sqwCb, "BOTTOMLEFT", 20, -4); alwaysCb.Text:SetText("Always show (Grayed in combat)")
    alwaysCb:SetChecked(ABCReminderDB.alwaysShowSQW); 
    alwaysCb:SetScript("OnClick", function(cb) ABCReminderDB.alwaysShowSQW = cb:GetChecked() end)

     -- Slider de durée pour l'affichage des stats après combat, avec incréments 5 s de 0 à 30
    local statsDisplay = CreateFrame("Slider", "ABCReminderStatsSlider", self, "OptionsSliderTemplate")
    statsDisplay:SetPoint("TOPLEFT", alwaysCb, "BOTTOMLEFT", -20, -30)
    statsDisplay:SetMinMaxValues(0, 30); statsDisplay:SetValueStep(5); statsDisplay:SetObeyStepOnDrag(true)
    statsDisplay:SetValue(ABCReminderDB.intervalStatsDisplay)
    statsDisplay.Text:SetJustifyH("LEFT")
    statsDisplay.Text:ClearAllPoints()
    statsDisplay.Text:SetPoint("TOPLEFT", statsDisplay, "TOPLEFT", 0, 20)
    statsDisplay.Text:SetText("Stats display duration : 0 means permanent")
    statsDisplay.Low:SetText("0"); statsDisplay.High:SetText("30")
    local valTxt = statsDisplay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valTxt:SetPoint("TOP", statsDisplay, "BOTTOM", 0, -2); valTxt:SetText(string.format("%.1f s", ABCReminderDB.intervalStatsDisplay))
    statsDisplay:SetScript("OnValueChanged", function(_, v) ABCReminderDB.intervalStatsDisplay = v; valTxt:SetText(string.format("%.1f s", v)) end)

end)

local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
Settings.RegisterAddOnCategory(category)

-- Slash Commands
SLASH_ABCREMINDER1 = "/ar"
SlashCmdList.ABCREMINDER = function(msg)
    if msg == "move" then
        isMovingSQW = not isMovingSQW
        sqwFrame:EnableMouse(isMovingSQW)
        sqwFrame:SetMovable(isMovingSQW)
        print("ABC: Move Mode "..(isMovingSQW and "|cff00ff00ON|r (Drag the blue box)" or "|cffff0000OFF|r"))
    elseif msg == "reset session" then
        CharABCRDB.sessionTrivial = { totalTime = 0, idleTime = 0 }
        print("ABC: Session reset.")
    else Settings.OpenToCategory(panel.name) end
end