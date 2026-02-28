-- =========================
-- SavedVariables
-- =========================
ABCReminderDB = ABCReminderDB or {
    clipSound = true,
    soundInterval = 1.0,
    showSQW = false,
    alwaysShowSQW = false,
    enabledInstances = {
        party = true, raid = true, scenario = true,
        arena = false, pvp = false, none = false,
    },
    soundChannel = "Master",
    soundFile = "WaterDrop",
    sqwPosition      = { point = "CENTER", x = 0,   y = -150 },
    statsPosition    = { point = "LEFT",   x = 40,  y = 0    },
    bossStatsPosition= { point = "RIGHT",  x = -40, y = 0    },
    intervalStatsDisplay = 15,
    showSessionResults   = true,
    sessionDisplay       = "chat",
    minRaidBossDuration  = 40,
}

CharABCRDB = CharABCRDB or {
    enabled = true,
    disabledSpecs = {},  -- specID (number) => true si désactivé
    statistics = { perInstance = {}, perBoss = {} },
    sessionTrivial = { totalTime = 0, idleTime = 0, outsideOnly = true },
}

local isMovingSQW = false

-- =========================
-- Helpers & Logic
-- =========================
local soundFiles = {
    ["WaterDrop"]  = "Interface\\AddOns\\ABCReminder\\sound\\WaterDrop.ogg",
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

local function GetTimestamp()
    return date("%d/%m %H:%M")
end

-- =========================
-- IsEnabled : perso + spec courante
-- =========================
local function IsEnabledForCurrentSpec()
    if not CharABCRDB.enabled then return false end
    local specIndex = GetSpecialization()
    if not specIndex then return true end
    local specID = GetSpecializationInfo(specIndex)
    if not specID then return true end
    return not (CharABCRDB.disabledSpecs and CharABCRDB.disabledSpecs[specID])
end

-- =========================
-- Chat dédié
-- =========================
local abcChatFrame = nil

local function EnsureChatTab()
    for i = 1, NUM_CHAT_WINDOWS do
        local name = GetChatWindowInfo(i)
        if name == "ABCReminder" then
            abcChatFrame = _G["ChatFrame" .. i]
            return
        end
    end
    if not abcChatFrame then
        FCF_OpenNewWindow("ABCReminder")
        for i = 1, NUM_CHAT_WINDOWS do
            local name = GetChatWindowInfo(i)
            if name == "ABCReminder" then
                abcChatFrame = _G["ChatFrame" .. i]
                break
            end
        end
    end
end

local function ABCPrint(msg)
    if not ABCReminderDB.showSessionResults then return end
    local mode = ABCReminderDB.sessionDisplay
    if mode == "chat" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffABC|r " .. msg)
    elseif mode == "tab" then
        EnsureChatTab()
        if abcChatFrame then
            abcChatFrame:AddMessage("|cff00ccffABC|r " .. msg)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffABC|r " .. msg)
        end
    end
end

-- =========================
-- Session M+
-- =========================
local mPlusActive = false
local mPlusCombatTime, mPlusIdleTime = 0, 0
local mPlusBossData = {}
local currentMPlusName = nil

local function StartMPlusSession(mapName)
    mPlusActive = true
    mPlusCombatTime, mPlusIdleTime = 0, 0
    mPlusBossData = {}
    currentMPlusName = mapName
end

local function EndMPlusSession(completed)
    if not mPlusActive then return end
    mPlusActive = false
    if not completed then currentMPlusName = nil; return end

    local name  = currentMPlusName or "M+ Unknown"
    local ratio = mPlusCombatTime > 0 and (mPlusIdleTime / mPlusCombatTime) * 100 or 0

    if not CharABCRDB.statistics.perInstance[name] then
        CharABCRDB.statistics.perInstance[name] = { totalTime=0, idleTime=0, bestRatio=100, bestDate=nil, bosses={} }
    end
    local data = CharABCRDB.statistics.perInstance[name]
    local isNewRecord = false

    if ratio < (data.bestRatio or 100) then
        data.bestRatio = ratio
        data.bestDate  = GetTimestamp()
        isNewRecord    = true
        PlaySound(888, ABCReminderDB.soundChannel)
    end
    data.totalTime = data.totalTime + mPlusCombatTime
    data.idleTime  = data.idleTime  + mPlusIdleTime
    data.bosses    = mPlusBossData

    ShowResultFrame(name, ratio, data.bestRatio, isNewRecord, data.bestDate, true)
    currentMPlusName = nil
end

-- =========================
-- Engine vars
-- =========================
local inCombat, sessionCombatTime, sessionIdleTime = false, 0, 0
local checkElapsed, soundElapsed, wasEligible, soundHandle = 0, 0, false, nil
local lastCombatTime, lastCombatIdle = 0, 0

-- =========================
-- UI Factory: Base Frame
-- =========================
local function CreateBaseFrame(name, w, h, posKey)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(w, h)
    f:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=16,
        insets={ left=4, right=4, top=4, bottom=4 }
    })
    f:SetBackdropColor(0, 0, 0, 0.85)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    f:Hide()
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        ABCReminderDB[posKey] = { point=point, x=x, y=y }
    end)
    return f
end

-- =========================
-- UI: Result Frame
-- =========================
local resultFrame = CreateBaseFrame("ABCReminderResult", 260, 160, "bossStatsPosition")

resultFrame.title = resultFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
resultFrame.title:SetPoint("TOP", 0, -10)
resultFrame.title:SetWidth(230); resultFrame.title:SetMaxLines(2)

resultFrame.sep = resultFrame:CreateTexture(nil, "ARTWORK")
resultFrame.sep:SetSize(230, 1)
resultFrame.sep:SetPoint("TOP", resultFrame.title, "BOTTOM", 0, -6)
resultFrame.sep:SetColorTexture(0.4, 0.4, 0.4, 0.8)

resultFrame.content = resultFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
resultFrame.content:SetPoint("TOPLEFT", resultFrame.sep, "BOTTOMLEFT", 8, -10)
resultFrame.content:SetWidth(226); resultFrame.content:SetJustifyH("LEFT")

resultFrame.closeBtn = CreateFrame("Button", nil, resultFrame, "UIPanelCloseButton")
resultFrame.closeBtn:SetPoint("TOPRIGHT", -3, -4)
resultFrame.closeBtn:SetScript("OnClick", function() resultFrame:Hide() end)

function ShowResultFrame(name, ratio, bestRatio, isNewRecord, bestDate, isPersist)
    local activeRatio     = 100 - ratio
    local bestActiveRatio = bestRatio and (100 - bestRatio) or nil
    if isPersist then
        resultFrame.title:SetText(
            isNewRecord and ("|cffFFD700★ "..name.." ★|r") or ("|cff00ccff"..name.."|r"))
        local dateStr = bestDate and (" |cff888888["..bestDate.."]|r") or ""
        resultFrame.content:SetText(string.format(
            "Active this run: |cffffffff%.1f%%|r\n\nPersonal Best: |cff00ff00%.1f%%|r%s%s",
            activeRatio, bestActiveRatio or 0, dateStr,
            isNewRecord and "\n\n|cffFFD700★ New Personal Record! ★|r" or ""))
    else
        local st = CharABCRDB.sessionTrivial
        local sessionActive = st.totalTime>0 and (1 - st.idleTime/st.totalTime)*100 or 0
        resultFrame.title:SetText("|cffffd100"..name.."|r")
        resultFrame.content:SetText(string.format(
            "Active this run: |cffffffff%.1f%%|r\n\nSession avg: |cffaaaaaa%.1f%%|r",
            activeRatio, sessionActive))
    end
    resultFrame:Show()
    if ABCReminderDB.intervalStatsDisplay and ABCReminderDB.intervalStatsDisplay > 0 then
        C_Timer.After(ABCReminderDB.intervalStatsDisplay, function()
            if resultFrame:IsShown() then resultFrame:Hide() end
        end)
    end
end

-- =========================
-- UI: Session Frame
-- =========================
local statsTable = CreateBaseFrame("ABCReminderStatsTable", 210, 120, "statsPosition")

statsTable.title = statsTable:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statsTable.title:SetPoint("TOP", 0, -10); statsTable.title:SetText("|cffffd100Session|r")

statsTable.sep = statsTable:CreateTexture(nil, "ARTWORK")
statsTable.sep:SetSize(190, 1)
statsTable.sep:SetPoint("TOP", statsTable.title, "BOTTOM", 0, -5)
statsTable.sep:SetColorTexture(0.4, 0.4, 0.4, 0.8)

statsTable.content = statsTable:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statsTable.content:SetPoint("TOPLEFT", statsTable.sep, "BOTTOMLEFT", 8, -8)
statsTable.content:SetWidth(186); statsTable.content:SetJustifyH("LEFT")

statsTable.resetBtn = CreateFrame("Button", nil, statsTable, "UIPanelButtonTemplate")
statsTable.resetBtn:SetSize(110, 18); statsTable.resetBtn:SetPoint("BOTTOM", 0, 8)
statsTable.resetBtn:SetText("Reset Session")
statsTable.resetBtn:SetScript("OnClick", function()
    CharABCRDB.sessionTrivial = { totalTime=0, idleTime=0, outsideOnly=true }
    lastCombatTime, lastCombatIdle = 0, 0
    statsTable.content:SetText("|cff00ff00Reset!|r")
end)

local function UpdateSessionFrame()
    local st         = CharABCRDB.sessionTrivial
    local sessActive = st.totalTime > 0    and (1 - st.idleTime / st.totalTime)     * 100 or 0
    local lastActive = lastCombatTime > 0  and (1 - lastCombatIdle / lastCombatTime) * 100 or 0

    statsTable.content:SetText(string.format(
        "Last:    |cffffffff%.1f%%|r  %dm%ds / %dm%ds\nSession: |cffaaaaaa%.1f%%|r  %dm%ds / %dm%ds",
        lastActive,
        math.floor(lastCombatIdle/60), lastCombatIdle%60,
        math.floor(lastCombatTime/60), lastCombatTime%60,
        sessActive,
        math.floor(st.idleTime/60),    st.idleTime%60,
        math.floor(st.totalTime/60),   st.totalTime%60
    ))

    if not ABCReminderDB.showSessionResults then return end
    local mode = ABCReminderDB.sessionDisplay
    if mode == "window" then
        statsTable:Show()
        if ABCReminderDB.intervalStatsDisplay and ABCReminderDB.intervalStatsDisplay > 0 then
            C_Timer.After(ABCReminderDB.intervalStatsDisplay, function()
                if statsTable:IsShown() then statsTable:Hide() end
            end)
        end
    else
        ABCPrint(string.format(
            "Session: %.1f%% active  %dm%ds / %dm%ds | Last: %.1f%%",
            sessActive,
            math.floor(st.idleTime/60), st.idleTime%60,
            math.floor(st.totalTime/60), st.totalTime%60,
            lastActive
        ))
    end
end

-- =========================
-- UI: History Frame
-- =========================
local HISTORY_W, HISTORY_H = 370, 320
local historyFrame = CreateBaseFrame("ABCReminderHistory", HISTORY_W, HISTORY_H, "historyPosition")

historyFrame.closeBtn = CreateFrame("Button", nil, historyFrame, "UIPanelCloseButton")
historyFrame.closeBtn:SetPoint("TOPRIGHT", -3, -4)
historyFrame.closeBtn:SetScript("OnClick", function() historyFrame:Hide() end)

historyFrame.titleText = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
historyFrame.titleText:SetPoint("TOP", 0, -10)
historyFrame.titleText:SetText("|cff00ccffABCReminder History|r")

historyFrame.tabRaid = CreateFrame("Button", nil, historyFrame, "UIPanelButtonTemplate")
historyFrame.tabRaid:SetSize(70, 22); historyFrame.tabRaid:SetPoint("TOPLEFT", 12, -32)
historyFrame.tabRaid:SetText("Raid")

historyFrame.tabMythic = CreateFrame("Button", nil, historyFrame, "UIPanelButtonTemplate")
historyFrame.tabMythic:SetSize(70, 22)
historyFrame.tabMythic:SetPoint("LEFT", historyFrame.tabRaid, "RIGHT", 6, 0)
historyFrame.tabMythic:SetText("Mythic+")

local diffFilterDrop = CreateFrame("Frame", "ABCReminderDiffDrop", historyFrame, "UIDropDownMenuTemplate")
diffFilterDrop:SetPoint("LEFT", historyFrame.tabMythic, "RIGHT", 2, 0)
historyFrame.currentDiffFilter = "All"

local DIFF_OPTIONS = { "All", "Normal", "Heroic", "Mythic", "LFR" }
UIDropDownMenu_Initialize(diffFilterDrop, function(_, level)
    for _, d in ipairs(DIFF_OPTIONS) do
        local info = UIDropDownMenu_CreateInfo()
        info.text, info.arg1, info.checked = d, d, (historyFrame.currentDiffFilter == d)
        info.func = function(_, a1)
            historyFrame.currentDiffFilter = a1
            UIDropDownMenu_SetText(diffFilterDrop, a1)
            RefreshHistoryFrame()
        end
        UIDropDownMenu_AddButton(info, level)
    end
end)
UIDropDownMenu_SetWidth(diffFilterDrop, 75); UIDropDownMenu_SetText(diffFilterDrop, "All")

historyFrame.sep = historyFrame:CreateTexture(nil, "ARTWORK")
historyFrame.sep:SetHeight(1)
historyFrame.sep:SetPoint("TOPLEFT",  historyFrame.tabRaid, "BOTTOMLEFT",   0, -6)
historyFrame.sep:SetPoint("TOPRIGHT", historyFrame,         "TOPRIGHT",    -12, 0)
historyFrame.sep:SetColorTexture(0.4, 0.4, 0.4, 0.8)

local SCROLL_W    = HISTORY_W - 34
local COL_NAME_W  = SCROLL_W - 118
local COL_RATIO_W = 54
local COL_DATE_W  = 56

local colHeaderFrame = CreateFrame("Frame", nil, historyFrame)
colHeaderFrame:SetSize(SCROLL_W, 18)
colHeaderFrame:SetPoint("TOPLEFT", historyFrame.sep, "BOTTOMLEFT", 0, -2)

local colHeaderBg = colHeaderFrame:CreateTexture(nil, "BACKGROUND")
colHeaderBg:SetAllPoints(); colHeaderBg:SetColorTexture(0.18, 0.18, 0.18, 0.8)

local colHdrName = colHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
colHdrName:SetPoint("LEFT", colHeaderFrame, "LEFT", 6, 0)
colHdrName:SetWidth(COL_NAME_W); colHdrName:SetJustifyH("LEFT"); colHdrName:SetText("|cffaaaaaaName|r")

local colHdrRatio = colHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
colHdrRatio:SetPoint("RIGHT", colHeaderFrame, "RIGHT", -(COL_DATE_W + 4), 0)
colHdrRatio:SetWidth(COL_RATIO_W); colHdrRatio:SetJustifyH("RIGHT"); colHdrRatio:SetText("|cffaaaaaaBest|r")

local colHdrDate = colHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
colHdrDate:SetPoint("RIGHT", colHeaderFrame, "RIGHT", -2, 0)
colHdrDate:SetWidth(COL_DATE_W); colHdrDate:SetJustifyH("RIGHT"); colHdrDate:SetText("|cffaaaaaaDate|r")

local scrollFrame = CreateFrame("ScrollFrame", nil, historyFrame, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT",     colHeaderFrame, "BOTTOMLEFT",  0,   -2)
scrollFrame:SetPoint("BOTTOMRIGHT", historyFrame,   "BOTTOMRIGHT", -26, 12)

local scrollChild = CreateFrame("Frame", nil, scrollFrame)
scrollChild:SetSize(SCROLL_W, 1)
scrollFrame:SetScrollChild(scrollChild)

historyFrame.currentFilter = "raid"

local function GetRatioColor(activeRatio)
    if activeRatio >= 98 then return "E6CC80" end
    if activeRatio >= 95 then return "ff8000" end
    if activeRatio >= 85 then return "A335EE" end
    if activeRatio >= 75 then return "0070DD" end
    if activeRatio >= 60 then return "1EFF00" end
    if activeRatio >= 50 then return "FFFFFF" end
    return "9D9D9D"
end

local rowPool = {}
local NUM_ROWS = 60

for i = 1, NUM_ROWS do
    local row = CreateFrame("Frame", nil, scrollChild)
    row:SetSize(SCROLL_W, 22)
    row:SetPoint("TOPLEFT", 0, -(i-1)*22)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(i%2==0 and 0.06 or 0.12, i%2==0 and 0.06 or 0.12, i%2==0 and 0.06 or 0.12, 0.5)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.nameText:SetWidth(COL_NAME_W); row.nameText:SetJustifyH("LEFT"); row.nameText:SetWordWrap(false)

    row.ratioText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ratioText:SetPoint("RIGHT", row, "RIGHT", -(COL_DATE_W + 4), 0)
    row.ratioText:SetWidth(COL_RATIO_W); row.ratioText:SetJustifyH("RIGHT")

    row.dateText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.dateText:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.dateText:SetWidth(COL_DATE_W); row.dateText:SetJustifyH("RIGHT")

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self.data then return end
        local d = self.data
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(d.name, 1, 1, 1)
        GameTooltip:AddLine(string.format("Total:  %dm %ds", math.floor(d.totalTime/60), d.totalTime%60), 0.8, 0.8, 0.8)
        GameTooltip:AddLine(string.format("Idle:   %dm %ds", math.floor(d.idleTime/60),  d.idleTime%60),  0.8, 0.8, 0.8)
        local bestActive = 100 - (d.bestRatio or 0)
        GameTooltip:AddLine(string.format("Best:   %.1f%% active", bestActive), 0, 1, 0)
        if d.bestDate then GameTooltip:AddLine("Record: "..d.bestDate, 0.6, 0.6, 0.6) end
        if d.bosses and #d.bosses > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Bosses (info):", 1, 0.8, 0)
            for _, b in ipairs(d.bosses) do
                GameTooltip:AddLine(string.format("  %s: %.1f%% active", b.name, 100 - b.ratio), 0.8, 0.8, 0.8)
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rowPool[i] = row; row:Hide()
end

local function MatchesDiffFilter(name, diff)
    if diff == "All" then return true end
    return name:find("%["..diff.."%]") ~= nil
end

local function GetHistoryEntries(filter, diffFilter)
    local entries = {}
    if filter == "raid" then
        for name, data in pairs(CharABCRDB.statistics.perBoss) do
            if MatchesDiffFilter(name, diffFilter) then
                table.insert(entries, { name=name, totalTime=data.totalTime, idleTime=data.idleTime,
                    bestRatio=data.bestRatio, bestDate=data.bestDate })
            end
        end
    else
        for name, data in pairs(CharABCRDB.statistics.perInstance) do
            table.insert(entries, { name=name, totalTime=data.totalTime, idleTime=data.idleTime,
                bestRatio=data.bestRatio, bestDate=data.bestDate, bosses=data.bosses })
        end
    end
    table.sort(entries, function(a,b) return (a.bestRatio or 100) < (b.bestRatio or 100) end)
    return entries
end

function RefreshHistoryFrame()
    local entries  = GetHistoryEntries(historyFrame.currentFilter, historyFrame.currentDiffFilter)
    local isRaid   = historyFrame.currentFilter == "raid"
    local activeC  = {1, 0.8, 0}
    local inactC   = {0.8, 0.8, 0.8}

    historyFrame.tabRaid:GetFontString():SetTextColor(
        isRaid and activeC[1] or inactC[1], isRaid and activeC[2] or inactC[2], isRaid and activeC[3] or inactC[3])
    historyFrame.tabMythic:GetFontString():SetTextColor(
        (not isRaid) and activeC[1] or inactC[1], (not isRaid) and activeC[2] or inactC[2], (not isRaid) and activeC[3] or inactC[3])

    if isRaid then
        diffFilterDrop:Show()
    else
        diffFilterDrop:Hide()
        historyFrame.currentDiffFilter = "All"
        UIDropDownMenu_SetText(diffFilterDrop, "All")
    end

    for i = 1, NUM_ROWS do
        local row, entry = rowPool[i], entries[i]
        if entry then
            row.data = entry
            row.nameText:SetText(entry.name)
            local activeRatio = 100 - (entry.bestRatio or 0)
            local col = GetRatioColor(activeRatio)
            row.ratioText:SetText(string.format("|cff%s%.1f%%|r", col, activeRatio))
            row.dateText:SetText(entry.bestDate and ("|cff888888"..entry.bestDate.."|r") or "")
            row:Show()
        else
            row.data = nil; row:Hide()
        end
    end
    scrollChild:SetHeight(math.max(#entries, 1) * 22)
end

historyFrame.tabRaid:SetScript("OnClick",   function() historyFrame.currentFilter="raid";   RefreshHistoryFrame() end)
historyFrame.tabMythic:SetScript("OnClick", function() historyFrame.currentFilter="mythic"; RefreshHistoryFrame() end)

local function ShowHistoryFrame(filter)
    historyFrame.currentFilter = filter or historyFrame.currentFilter or "raid"
    RefreshHistoryFrame()
    historyFrame:Show()
end

-- =========================
-- Logic: ProcessCombatEnd
-- =========================
local function ProcessCombatEnd(encounterName)
    local instanceName, instanceType, diffID = GetInstanceInfo()
    local diffName = GetDifficultyInfo(diffID) or tostring(diffID)

    if mPlusActive and encounterName then
        local bossRatio = sessionCombatTime > 0 and (sessionIdleTime/sessionCombatTime)*100 or 0
        mPlusCombatTime = mPlusCombatTime + sessionCombatTime
        mPlusIdleTime   = mPlusIdleTime   + sessionIdleTime
        table.insert(mPlusBossData, { name=encounterName, ratio=bossRatio })
        ShowResultFrame(encounterName.." (M+)", bossRatio, bossRatio, false, nil, false)
        sessionCombatTime, sessionIdleTime = 0, 0
        return
    end

    if instanceType == "raid" and encounterName then
        if sessionCombatTime < (ABCReminderDB.minRaidBossDuration or 40) then
            sessionCombatTime, sessionIdleTime = 0, 0
            return
        end
        local ratio = sessionCombatTime > 0 and (sessionIdleTime/sessionCombatTime)*100 or 0
        local key   = "Boss: "..encounterName.." ["..diffName.."]"

        if not CharABCRDB.statistics.perBoss[key] then
            CharABCRDB.statistics.perBoss[key] = { totalTime=0, idleTime=0, bestRatio=100, bestDate=nil }
        end
        local data = CharABCRDB.statistics.perBoss[key]
        local isNewRecord = false
        if ratio < (data.bestRatio or 100) then
            data.bestRatio = ratio; data.bestDate = GetTimestamp(); isNewRecord = true
            PlaySound(888, ABCReminderDB.soundChannel)
        end
        data.totalTime = data.totalTime + sessionCombatTime
        data.idleTime  = data.idleTime  + sessionIdleTime
        ShowResultFrame(key, ratio, data.bestRatio, isNewRecord, data.bestDate, true)
        sessionCombatTime, sessionIdleTime = 0, 0
        return
    end

    lastCombatTime = sessionCombatTime
    lastCombatIdle = sessionIdleTime

    local st = CharABCRDB.sessionTrivial
    local ratio = sessionCombatTime > 0 and (sessionIdleTime/sessionCombatTime)*100 or 0
    st.totalTime = st.totalTime + sessionCombatTime
    st.idleTime  = st.idleTime  + sessionIdleTime

    if ABCReminderDB.showSessionResults and ABCReminderDB.sessionDisplay == "window" then
        ShowResultFrame(instanceName or "Session", ratio, nil, false, nil, false)
    end
    UpdateSessionFrame()
    sessionCombatTime, sessionIdleTime = 0, 0
end

-- =========================
-- UI: SQW Circular Visual
-- =========================
local sqwFrame = CreateFrame("Frame", "ABCReminderSQW", UIParent)
sqwFrame:SetSize(50, 50); sqwFrame:SetMovable(true); sqwFrame:EnableMouse(false)
sqwFrame:RegisterForDrag("LeftButton")
sqwFrame:SetScript("OnDragStart", sqwFrame.StartMoving)
sqwFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    ABCReminderDB.sqwPosition = { point=point, x=x, y=y }
end)

sqwFrame.fill = sqwFrame:CreateTexture(nil, "BORDER")
sqwFrame.fill:SetAllPoints()
sqwFrame.fill:SetTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
sqwFrame.fill:SetVertexColor(0, 1, 0, 0.85)

sqwFrame.cd = CreateFrame("Cooldown", nil, sqwFrame, "CooldownFrameTemplate")
sqwFrame.cd:SetAllPoints(); sqwFrame.cd:SetDrawEdge(false); sqwFrame.cd:SetDrawSwipe(true)
sqwFrame.cd:SetSwipeColor(0, 0, 0, 1); sqwFrame.cd:SetReverse(false)
sqwFrame.cd:SetHideCountdownNumbers(true)
sqwFrame.cd:SetSwipeTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
sqwFrame.cd:SetDrawBling(false)

sqwFrame.moveTex = sqwFrame:CreateTexture(nil, "OVERLAY")
sqwFrame.moveTex:SetAllPoints()
sqwFrame.moveTex:SetTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
sqwFrame.moveTex:SetVertexColor(0, 0.5, 1, 0.5); sqwFrame.moveTex:Hide()

local function UpdateSQWVisual(remaining)
    if not ABCReminderDB.showSQW then
        if not isMovingSQW then sqwFrame:Hide() end; return
    end
    if isMovingSQW then return end
    local threshold = GetSQW()
    local inWindow  = remaining and remaining > 0 and remaining <= threshold
    local showGray  = ABCReminderDB.alwaysShowSQW and remaining and remaining > threshold
    if inWindow then
        sqwFrame.fill:SetVertexColor(0, 1, 0, 0.85); sqwFrame.cd:SetSwipeColor(0, 0, 0, 0.85)
        sqwFrame.cd:SetCooldown(GetTime() - (threshold-remaining), threshold); sqwFrame:Show()
    elseif showGray then
        sqwFrame.fill:SetVertexColor(0.3, 0.3, 0.3, 0.4); sqwFrame.cd:SetCooldown(0,0); sqwFrame:Show()
    else sqwFrame:Hide() end
end

-- =========================
-- Engine & Events
-- =========================
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")


frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        local _, instanceType = IsInInstance()
        if instanceType and instanceType ~= "none" then
            CharABCRDB.sessionTrivial = { totalTime=0, idleTime=0, outsideOnly=false }
            lastCombatTime, lastCombatIdle = 0, 0
        end
        CharABCRDB.statistics = CharABCRDB.statistics or {}
        if not CharABCRDB.statistics.perBoss then
            CharABCRDB.statistics = { perInstance={}, perBoss={} }
        end
        CharABCRDB.statistics.perInstance = CharABCRDB.statistics.perInstance or {}
        CharABCRDB.statistics.perBoss     = CharABCRDB.statistics.perBoss     or {}
        CharABCRDB.sessionTrivial = CharABCRDB.sessionTrivial or { totalTime=0, idleTime=0, outsideOnly=true }
        CharABCRDB.disabledSpecs  = CharABCRDB.disabledSpecs  or {}

        local db = ABCReminderDB
        db.intervalStatsDisplay  = db.intervalStatsDisplay  or 15
        if db.showSessionResults == nil then db.showSessionResults = true  end
        if db.sessionDisplay     == nil then db.sessionDisplay     = "window" end
        if db.sessionChatDedicated ~= nil then
            if db.sessionChatDedicated == true then db.sessionDisplay = "tab" end
            db.sessionChatDedicated = nil
        end
        db.minRaidBossDuration = db.minRaidBossDuration or 40

        db.sqwPosition       = ValidatePosition(db.sqwPosition,       { point="CENTER", x=0,   y=-150 })
        db.statsPosition     = ValidatePosition(db.statsPosition,     { point="LEFT",   x=40,  y=0    })
        db.bossStatsPosition = ValidatePosition(db.bossStatsPosition, { point="RIGHT",  x=-40, y=0    })
        db.historyPosition   = ValidatePosition(db.historyPosition,   { point="LEFT",   x=40,  y=200  })

        sqwFrame:ClearAllPoints()
        sqwFrame:SetPoint(db.sqwPosition.point, UIParent, db.sqwPosition.point, db.sqwPosition.x, db.sqwPosition.y)
        statsTable:ClearAllPoints()
        statsTable:SetPoint(db.statsPosition.point, UIParent, db.statsPosition.point, db.statsPosition.x, db.statsPosition.y)
        resultFrame:ClearAllPoints()
        resultFrame:SetPoint(db.bossStatsPosition.point, UIParent, db.bossStatsPosition.point, db.bossStatsPosition.x, db.bossStatsPosition.y)
        historyFrame:ClearAllPoints()
        historyFrame:SetPoint(db.historyPosition.point, UIParent, db.historyPosition.point, db.historyPosition.x, db.historyPosition.y)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Rafraîchir le panneau si ouvert pour refléter la nouvelle spec active
        if panel:IsShown() then
            RefreshPanelDynamic()
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        if mPlusActive then
            mPlusCombatTime = mPlusCombatTime + sessionCombatTime
            mPlusIdleTime   = mPlusIdleTime   + sessionIdleTime
            sessionCombatTime, sessionIdleTime = 0, 0
        else
            ProcessCombatEnd()
        end

    elseif event == "ENCOUNTER_END" then
        local _, encounterName, _, _, success = ...
        ProcessCombatEnd(encounterName, success == 1)

    elseif event == "CHALLENGE_MODE_START" then
        local mapName = C_ChallengeMode.GetActiveChallengeMapID and
            (C_Map.GetMapInfo(C_ChallengeMode.GetActiveChallengeMapID()) or {}).name or "M+ Unknown"
        StartMPlusSession(mapName)

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        EndMPlusSession(true)
    end
end)

frame:SetScript("OnUpdate", function(_, delta)
    if not IsEnabledForCurrentSpec() then sqwFrame:Hide() return end
    if isMovingSQW then
        sqwFrame:Show(); sqwFrame.moveTex:Show()
        sqwFrame.fill:SetVertexColor(0, 0.5, 1, 0.7); sqwFrame.cd:SetCooldown(0,0)
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
            local outsideBlocked = (not it or it=="none") and not ABCReminderDB.trackOutsideInstance
            if outsideBlocked then
                if ABCReminderDB.clipSound and soundHandle then StopSound(soundHandle); soundHandle=nil end
                wasEligible, soundElapsed = false, 0
                return
            end
            if ABCReminderDB.enabledInstances[it or "none"] and not isBusy and not (cd and cd.startTime>0) then
                if not wasEligible or soundElapsed >= ABCReminderDB.soundInterval then
                    _, soundHandle = PlaySoundFile(soundFiles[ABCReminderDB.soundFile], ABCReminderDB.soundChannel)
                    wasEligible, soundElapsed = true, 0
                else soundElapsed = soundElapsed + 0.1 end
            else
                if ABCReminderDB.clipSound and soundHandle and (isBusy or (cd and cd.startTime>0)) then
                    StopSound(soundHandle); soundHandle=nil
                end
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

-- Références aux widgets dynamiques, stockées après l'init
-- pour pouvoir les mettre à jour sans recréer le panneau.
local dynWidgets = {}

-- Appelé à chaque OnShow ET depuis PLAYER_SPECIALIZATION_CHANGED
-- Met à jour uniquement les valeurs qui peuvent changer en dehors du panneau.
local function RefreshPanelDynamic()
    -- 1. Sync charEnable (peut être togglé via clic minimap)
    if dynWidgets.charEnable then
        dynWidgets.charEnable:SetChecked(CharABCRDB.enabled)
    end

    -- 2. Sync specs : reconstruire les checkboxes (spec active peut avoir changé)
    if dynWidgets.BuildSpecCheckboxes then
        dynWidgets.BuildSpecCheckboxes()
    end
end

panel:SetScript("OnShow", function(self)
    if not self.init then
        self.init = true

        local optScroll = CreateFrame("ScrollFrame", "ABCReminderOptScroll", self, "UIPanelScrollFrameTemplate")
        optScroll:SetPoint("TOPLEFT",     self, "TOPLEFT",     4,  -4)
        optScroll:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -26, 4)

        local optContent = CreateFrame("Frame", nil, optScroll)
        optContent:SetSize(self:GetWidth() - 32, 900)
        optScroll:SetScrollChild(optContent)
        local C = optContent

        local decor = C:CreateTexture(nil, "BACKGROUND")
        decor:SetTexture("Interface\\AddOns\\ABCReminder\\img\\drops.tga")
        decor:SetPoint("TOPRIGHT", -8, 8); decor:SetSize(128, 128); decor:SetAlpha(0.3)

        local mainTitle = C:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        mainTitle:SetPoint("TOPLEFT", 16, -16); mainTitle:SetText("ABCReminder")

        -- ── Section : General ──────────────────────────────────────────────
        local hGen = C:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hGen:SetPoint("TOPLEFT", mainTitle, "BOTTOMLEFT", 0, -10)
        hGen:SetText("|cffffd100General|r")
        local lGen = C:CreateTexture(nil, "ARTWORK"); lGen:SetSize(460, 1)
        lGen:SetPoint("TOPLEFT", hGen, "BOTTOMLEFT", 0, -3); lGen:SetColorTexture(0.4, 0.4, 0.4, 0.6)

        local charEnable = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
        charEnable:SetPoint("TOPLEFT", hGen, "BOTTOMLEFT", 0, -14)
        charEnable.Text:SetText("Enable for this character")
        charEnable:SetChecked(CharABCRDB.enabled)
        charEnable:SetScript("OnClick", function(cb) CharABCRDB.enabled = cb:GetChecked() end)
        dynWidgets.charEnable = charEnable  -- référence pour refresh

        -- ── Section : Specializations ──────────────────────────────────────
        local hSpec = C:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hSpec:SetPoint("TOPLEFT", charEnable, "BOTTOMLEFT", 0, -12)
        hSpec:SetText("|cffffd100Specializations|r")
        local lSpec = C:CreateTexture(nil, "ARTWORK"); lSpec:SetSize(460, 1)
        lSpec:SetPoint("TOPLEFT", hSpec, "BOTTOMLEFT", 0, -3); lSpec:SetColorTexture(0.4, 0.4, 0.4, 0.6)

        local specNote = C:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        specNote:SetPoint("TOPLEFT", hSpec, "BOTTOMLEFT", 0, -16)
        specNote:SetText("|cffaaaaaaUncheck to disable ABCReminder for that specialization|r")

        -- Conteneur de hauteur fixe (4 specs max = 4×26 px)
        -- Les sections suivantes sont ancrées dessus, pas sur les specs elles-mêmes,
        -- ce qui évite de recalculer toute la chaîne d'ancres à chaque rebuild.
        local specContainer = CreateFrame("Frame", nil, C)
        specContainer:SetPoint("TOPLEFT", specNote, "BOTTOMLEFT", 0, -6)
        specContainer:SetSize(460, 52)

        local function BuildSpecCheckboxes()
            -- Nettoyer les anciens widgets du conteneur
            for _, child in ipairs({ specContainer:GetChildren() }) do
                child:Hide(); child:SetParent(nil)
            end

            local numSpecs = GetNumSpecializations()
            if numSpecs == 0 then return end

            local currentSpecIndex = GetSpecialization()
            local currentSpecID    = currentSpecIndex and select(1, GetSpecializationInfo(currentSpecIndex)) or nil

            local prevCb, prevCbR = nil,nil
            for i = 1, numSpecs do
                local specID, specName, _, specIcon = GetSpecializationInfo(i)
                if specID then
                    local cb = CreateFrame("CheckButton", nil, specContainer, "InterfaceOptionsCheckButtonTemplate")
                    if i%2 ~= 0 then
                         cb:SetPoint("TOPLEFT", prevCb or specContainer, prevCb and "BOTTOMLEFT" or "TOPLEFT", 0, prevCb and 2 or 0)
                         prevCb = cb
                    else
                         cb:SetPoint("TOPLEFT", prevCbR, "TOPLEFT", 200, 0)
                    end

                    -- Icône de spec à droite du label
                    local icon = cb:CreateTexture(nil, "OVERLAY")
                    icon:SetSize(16, 16)
                    icon:SetPoint("LEFT", cb.Text, "RIGHT", 4, 0)
                    icon:SetTexture(specIcon)
                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                    local isActive = (specID == currentSpecID)
                    cb.Text:SetText(specName .. (isActive and " |cffffd100(active)|r" or ""))
                    cb:SetChecked(not (CharABCRDB.disabledSpecs and CharABCRDB.disabledSpecs[specID]))

                    local capturedID = specID
                    cb:SetScript("OnClick", function(btn)
                        CharABCRDB.disabledSpecs = CharABCRDB.disabledSpecs or {}
                        if btn:GetChecked() then
                            CharABCRDB.disabledSpecs[capturedID] = nil
                        else
                            CharABCRDB.disabledSpecs[capturedID] = true
                        end
                    end)
                    if i%2 ~= 0 then prevCbR = cb end
                end
            end
        end

        BuildSpecCheckboxes()
        dynWidgets.BuildSpecCheckboxes = BuildSpecCheckboxes  -- référence pour refresh

        -- ── Section : Sound ────────────────────────────────────────────────
        local hSnd = C:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hSnd:SetPoint("TOPLEFT", specContainer, "BOTTOMLEFT", 0, -12)
        hSnd:SetText("|cffffd100Sound|r")
        local lSnd = C:CreateTexture(nil, "ARTWORK"); lSnd:SetSize(460, 1)
        lSnd:SetPoint("TOPLEFT", hSnd, "BOTTOMLEFT", 0, -3); lSnd:SetColorTexture(0.4, 0.4, 0.4, 0.6)

        local instKeys = {}
        for k in pairs(ABCReminderDB.enabledInstances) do table.insert(instKeys, k) end
        table.sort(instKeys)
        local lastInstCb, firstLeft
        for idx, inst in ipairs(instKeys) do
            local cb = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
            if idx % 2 ~= 0 then
                cb:SetPoint("TOPLEFT", idx == 1 and hSnd or lastInstCb, idx == 1 and "BOTTOMLEFT" or "BOTTOMLEFT", 0, idx == 1 and -14 or 2)
                firstLeft = cb
            else
                cb:SetPoint("TOPLEFT", firstLeft, "TOPLEFT", 200, 0)
            end
            cb.Text:SetText(inst == "none" and "open world" or inst)
            cb:SetChecked(ABCReminderDB.enabledInstances[inst])
            local instCapture = inst
            cb:SetScript("OnClick", function(btn)
                ABCReminderDB.enabledInstances[instCapture] = btn:GetChecked()
            end)
            if idx % 2 ~= 0 then lastInstCb = cb end
        end

        local slider = CreateFrame("Slider", "ABCReminderSlider", C, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", lastInstCb, "BOTTOMLEFT", 6, -22)
        slider:SetMinMaxValues(1.0, 10.0); slider:SetValueStep(0.5); slider:SetObeyStepOnDrag(true)
        slider:SetValue(ABCReminderDB.soundInterval)
        slider.Text:SetText("Sound Interval (s)"); slider.Low:SetText("1"); slider.High:SetText("10")
        local valTxt = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        valTxt:SetPoint("TOP", slider, "BOTTOM", 0, -2)
        valTxt:SetText(string.format("%.1f s", ABCReminderDB.soundInterval))
        slider:SetScript("OnValueChanged", function(_, v)
            ABCReminderDB.soundInterval = v; valTxt:SetText(string.format("%.1f s", v))
        end)

        local clipCb = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
        clipCb:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", -8, -18)
        clipCb.Text:SetText("Stop sound when casting resumes")
        clipCb:SetChecked(ABCReminderDB.clipSound)
        clipCb:SetScript("OnClick", function(cb) ABCReminderDB.clipSound = cb:GetChecked() end)

        local chanLabel = C:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        chanLabel:SetPoint("TOPLEFT", clipCb, "BOTTOMLEFT", 8, -8); chanLabel:SetText("Channel:")
        local chanDrop = CreateFrame("Frame", "ABCReminderChanDrop", C, "UIDropDownMenuTemplate")
        chanDrop:SetPoint("TOPLEFT", chanLabel, "TOPRIGHT", -10, 4)
        UIDropDownMenu_Initialize(chanDrop, function(_, level)
            for _, c in ipairs({"Master","SFX","Music","Ambience"}) do
                local info = UIDropDownMenu_CreateInfo()
                info.text, info.arg1, info.checked = c, c, (ABCReminderDB.soundChannel==c)
                info.func = function(_,a1) ABCReminderDB.soundChannel=a1; UIDropDownMenu_SetText(chanDrop,a1) end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetWidth(chanDrop, 90); UIDropDownMenu_SetText(chanDrop, ABCReminderDB.soundChannel)

        local sndLabel = C:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sndLabel:SetPoint("LEFT", chanLabel, "LEFT", 200, 0); sndLabel:SetText("File:")
        local sndDrop = CreateFrame("Frame", "ABCReminderSndDrop", C, "UIDropDownMenuTemplate")
        sndDrop:SetPoint("TOPLEFT", sndLabel, "TOPRIGHT", -10, 4)
        UIDropDownMenu_Initialize(sndDrop, function(_, level)
            for sname in pairs(soundFiles) do
                local info = UIDropDownMenu_CreateInfo()
                info.text, info.arg1, info.checked = sname, sname, (ABCReminderDB.soundFile==sname)
                info.func = function(_,a1) ABCReminderDB.soundFile=a1; UIDropDownMenu_SetText(sndDrop,a1) end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetWidth(sndDrop, 90); UIDropDownMenu_SetText(sndDrop, ABCReminderDB.soundFile)

        local testBtn = CreateFrame("Button", nil, C, "UIPanelButtonTemplate")
        testBtn:SetPoint("TOPLEFT", sndDrop, "TOPRIGHT", 6, -4); testBtn:SetSize(80, 22); testBtn:SetText("Test Sound")
        testBtn:SetScript("OnClick", function() PlaySoundFile(soundFiles[ABCReminderDB.soundFile], ABCReminderDB.soundChannel) end)

        -- ── Section : SQW ──────────────────────────────────────────────────
        local hSQW = C:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hSQW:SetPoint("TOPLEFT", chanLabel, "BOTTOMLEFT", 0, -22)
        hSQW:SetText("|cffffd100Spell Queue Window|r")
        local lSQW = C:CreateTexture(nil, "ARTWORK"); lSQW:SetSize(460, 1)
        lSQW:SetPoint("TOPLEFT", hSQW, "BOTTOMLEFT", 0, -3); lSQW:SetColorTexture(0.4, 0.4, 0.4, 0.6)

        local sqwCb = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
        sqwCb:SetPoint("TOPLEFT", hSQW, "BOTTOMLEFT", 0, -14)
        sqwCb.Text:SetText("Show Spell Queue Window visual")
        sqwCb:SetChecked(ABCReminderDB.showSQW)
        sqwCb:SetScript("OnClick", function(cb) ABCReminderDB.showSQW = cb:GetChecked() end)

        local sqwMiniIcon = sqwCb:CreateTexture(nil, "OVERLAY")
        sqwMiniIcon:SetTexture("Interface\\AddOns\\ABCReminder\\img\\circle.tga")
        sqwMiniIcon:SetSize(12, 12); sqwMiniIcon:SetPoint("LEFT", sqwCb.Text, "RIGHT", 6, 0)
        sqwMiniIcon:SetVertexColor(0, 1, 0, 1)

        local resetPosBtn = CreateFrame("Button", nil, C, "UIPanelButtonTemplate")
        resetPosBtn:SetPoint("LEFT", sqwMiniIcon, "RIGHT", 10, 0)
        resetPosBtn:SetSize(130, 22); resetPosBtn:SetText("Reset SQW Position")
        resetPosBtn:SetScript("OnClick", function()
            ABCReminderDB.sqwPosition = { point="CENTER", x=0, y=-150 }
            sqwFrame:ClearAllPoints(); sqwFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
        end)

        local alwaysCb = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
        alwaysCb:SetPoint("TOPLEFT", sqwCb, "BOTTOMLEFT", 20, -4)
        alwaysCb.Text:SetText("Always show (in combat - grayed when not in window)")
        alwaysCb:SetChecked(ABCReminderDB.alwaysShowSQW)
        alwaysCb:SetScript("OnClick", function(cb) ABCReminderDB.alwaysShowSQW = cb:GetChecked() end)

        -- ── Section : Statistics ───────────────────────────────────────────
        local hStat = C:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hStat:SetPoint("TOPLEFT", alwaysCb, "BOTTOMLEFT", -20, -14)
        hStat:SetText("|cffffd100Statistics|r")
        local lStat = C:CreateTexture(nil, "ARTWORK"); lStat:SetSize(460, 1)
        lStat:SetPoint("TOPLEFT", hStat, "BOTTOMLEFT", 0, -3); lStat:SetColorTexture(0.4, 0.4, 0.4, 0.6)

        local statsDisplay = CreateFrame("Slider", "ABCRStatsDur", C, "OptionsSliderTemplate")
        statsDisplay:SetPoint("TOPLEFT", hStat, "BOTTOMLEFT", 0, -22)
        statsDisplay:SetMinMaxValues(0, 30); statsDisplay:SetValueStep(5); statsDisplay:SetObeyStepOnDrag(true)
        statsDisplay:SetValue(ABCReminderDB.intervalStatsDisplay)
        statsDisplay.Text:SetJustifyH("LEFT"); statsDisplay.Text:ClearAllPoints()
        statsDisplay.Text:SetPoint("TOPLEFT", statsDisplay, "TOPLEFT", 0, 14)
        statsDisplay.Text:SetText("Floating window fade-out delay (o = disabled)")
        statsDisplay.Low:SetText("0"); statsDisplay.High:SetText("30s")
        local statsValTxt = statsDisplay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        statsValTxt:SetPoint("TOP", statsDisplay, "BOTTOM", 0, -2)
        statsValTxt:SetText(string.format("%ds", ABCReminderDB.intervalStatsDisplay))
        statsDisplay:SetScript("OnValueChanged", function(_, v)
            ABCReminderDB.intervalStatsDisplay = v; statsValTxt:SetText(string.format("%ds", v))
        end)

        local showResultsCb = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
        showResultsCb:SetPoint("TOPLEFT", statsDisplay, "BOTTOMLEFT", 0, -18)
        showResultsCb.Text:SetText("Show session results")
        showResultsCb:SetChecked(ABCReminderDB.showSessionResults)

        local radioLabels = { { key="window", label="Floating window" },
                              { key="chat",   label="General chat" },
                              { key="tab",    label="Dedicated ABCReminder chat tab" } }
        local radios = {}

        local function SetRadioDisplay(key)
            ABCReminderDB.sessionDisplay = key
            for _, r in ipairs(radios) do r.btn:SetChecked(r.key == key) end
            if key == "tab" then EnsureChatTab() end
        end

        local function UpdateRadioState()
            local enabled = ABCReminderDB.showSessionResults
            for _, r in ipairs(radios) do
                r.btn:SetEnabled(enabled)
                if r.lbl then r.lbl:SetTextColor(enabled and 1 or 0.5, enabled and 1 or 0.5, enabled and 1 or 0.5) end
            end
        end

        local prevAnchor = showResultsCb
        for i, opt in ipairs(radioLabels) do
            local btn = CreateFrame("CheckButton", nil, C, "UIRadioButtonTemplate")
            btn:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", i == 1 and 20 or 0, i == 1 and -4 or -2)
            local lbl = C:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetPoint("LEFT", btn, "RIGHT", 4, 0)
            lbl:SetText(opt.label)
            btn:SetScript("OnClick", function() SetRadioDisplay(opt.key) end)
            radios[i] = { btn = btn, key = opt.key, lbl = lbl }
            prevAnchor = btn
        end

        SetRadioDisplay(ABCReminderDB.sessionDisplay or "window")
        UpdateRadioState()

        showResultsCb:SetScript("OnClick", function(cb)
            ABCReminderDB.showSessionResults = cb:GetChecked()
            UpdateRadioState()
        end)

        local lastRadio = radios[#radios].btn

        local minDurSlider = CreateFrame("Slider", "ABCRMinBossDur", C, "OptionsSliderTemplate")
        minDurSlider:SetPoint("TOPLEFT", lastRadio, "BOTTOMLEFT", -20, -22)
        minDurSlider:SetMinMaxValues(0, 120); minDurSlider:SetValueStep(5); minDurSlider:SetObeyStepOnDrag(true)
        minDurSlider:SetValue(ABCReminderDB.minRaidBossDuration)
        minDurSlider.Text:SetJustifyH("LEFT"); minDurSlider.Text:ClearAllPoints()
        minDurSlider.Text:SetPoint("TOPLEFT", minDurSlider, "TOPLEFT", 0, 14)
        minDurSlider.Text:SetText("Min. raid boss duration to record (filters trivial/old content)")
        minDurSlider.Low:SetText("0"); minDurSlider.High:SetText("120s")
        local minDurTxt = minDurSlider:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        minDurTxt:SetPoint("TOP", minDurSlider, "BOTTOM", 0, -2)
        minDurTxt:SetText(string.format("%ds", ABCReminderDB.minRaidBossDuration))
        minDurSlider:SetScript("OnValueChanged", function(_, v)
            ABCReminderDB.minRaidBossDuration = v; minDurTxt:SetText(string.format("%ds", v))
        end)

        local resetStatsBtn = CreateFrame("Button", nil, C, "UIPanelButtonTemplate")
        resetStatsBtn:SetPoint("TOPLEFT", minDurSlider, "BOTTOMLEFT", -8, -20)
        resetStatsBtn:SetSize(160, 22); resetStatsBtn:SetText("Reset All Statistics")
        resetStatsBtn:SetScript("OnClick", function()
            CharABCRDB.statistics = { perInstance={}, perBoss={} }
            CharABCRDB.sessionTrivial = { totalTime=0, idleTime=0, outsideOnly=true }
            lastCombatTime, lastCombatIdle = 0, 0
            print("|cffff9900ABCReminder:|r All statistics reset.")
        end)
    end

    -- Refresh des valeurs dynamiques à chaque ouverture (pas seulement à l'init)
    RefreshPanelDynamic()
end)

local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
Settings.RegisterAddOnCategory(category)

-- =========================
-- Slash Commands
-- =========================
SLASH_ABCREMINDER1 = "/ar"
SlashCmdList.ABCREMINDER = function(msg)
    if msg == "move" then
        isMovingSQW = not isMovingSQW
        sqwFrame:EnableMouse(isMovingSQW); sqwFrame:SetMovable(isMovingSQW)
        print("ABC: Move Mode "..(isMovingSQW and "|cff00ff00ON|r (Drag the blue box)" or "|cffff0000OFF|r"))
    elseif msg == "stats" or msg == "history" then
        ShowHistoryFrame(); print("ABC: Showing history.")
    elseif msg == "raid" then
        ShowHistoryFrame("raid")
    elseif msg == "mythic" or msg == "m+" then
        ShowHistoryFrame("mythic")
    elseif msg == "session" then
        UpdateSessionFrame()
    elseif msg == "reset session" then
        CharABCRDB.sessionTrivial = { totalTime=0, idleTime=0, outsideOnly=true }
        lastCombatTime, lastCombatIdle = 0, 0
        print("ABC: Session reset.")
    else
        if category:GetID() then Settings.OpenToCategory(category:GetID())
        else Settings.OpenToCategory(panel.name) end
    end
end

-- =========================
-- Addon Compartment
-- =========================

local menuCompartment = CreateFrame("Frame", "ABCReminderCompartmentMenu", UIParent, "UIDropDownMenuTemplate")

function ABCReminder_OnAddonCompartmentClick(addonName, button)
    if button == "RightButton" then
        UIDropDownMenu_Initialize(menuCompartment, function(_, level)
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.func = "Open Options", function() Settings.OpenToCategory(category:GetID()) end
            UIDropDownMenu_AddButton(info, level)
            info.text, info.func = "History (Raid)",    function() ShowHistoryFrame("raid")   end
            UIDropDownMenu_AddButton(info, level)
            info.text, info.func = "History (Mythic+)", function() ShowHistoryFrame("mythic") end
            UIDropDownMenu_AddButton(info, level)
            info.text, info.func = "Session Stats", function() UpdateSessionFrame() end
            UIDropDownMenu_AddButton(info, level)
            info.text, info.func = "Reset Session Stats", function()
                CharABCRDB.sessionTrivial = { totalTime=0, idleTime=0, outsideOnly=true }
                lastCombatTime, lastCombatIdle = 0, 0
                print("ABC: Session statistics reset.")
            end
            UIDropDownMenu_AddButton(info, level)
        end)
        ToggleDropDownMenu(1, nil, menuCompartment, "cursor", 0, 0)
    else
        -- Toggle enable/disable + sync immédiat du panneau si ouvert
        CharABCRDB.enabled = not CharABCRDB.enabled
        if panel:IsShown() then RefreshPanelDynamic() end
        print("ABC: "..(CharABCRDB.enabled and "|cff00ff00Enabled|r for this character." or "|cffff0000Disabled|r for this character."))
    end
end

function ABCReminder_OnAddonCompartmentEnter(addonname, menuItem)
    GameTooltip:SetOwner(menuItem, "ANCHOR_RIGHT")
    GameTooltip:SetText("ABCReminder", 1, 1, 1)
    GameTooltip:AddLine("Left-click to enable or disable", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click for quick actions.", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function ABCReminder_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
