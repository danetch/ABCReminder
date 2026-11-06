-- =========================
-- Constants & defaults
-- =========================
local MAX_ATTEMPTS = 10   -- recent attempts kept per boss / per dungeon
local GAP_MIN      = 1.0  -- an idle stretch shorter than this (s) is not counted as a "gap"
local MIN_PULL     = 3.0  -- combats shorter than this (s) are noise (e.g. a stray debuff after a kill)
local GCD_SPELL    = 61304

local DB_DEFAULTS = {
    clipSound = true,
    soundInterval = 1.0,
    enabledInstances = {
        party = true, raid = true, scenario = true,
        arena = false, pvp = false, none = false,
    },
    soundChannel = "Master",
    soundFile = "WaterDrop",
    statsPosition     = { point = "LEFT",  x = 40,  y = 0   },
    bossStatsPosition = { point = "RIGHT", x = -40, y = 0   },
    historyPosition   = { point = "LEFT",  x = 40,  y = 200 },
    intervalStatsDisplay = 15,
    showSessionResults   = true,
    sessionDisplay       = "chat",
    minRaidBossDuration  = 40,
    recordWipes          = true,
}

local CHAR_DEFAULTS = {
    enabled = true,
    disabledSpecs = {},  -- specID (number) => true si désactivé
    statistics = { perInstance = {}, perBoss = {} },
    sessionTrivial = { totalTime = 0, idleTime = 0, idleMove = 0, idleCC = 0, outsideOnly = true },
}

-- Raid difficulty IDs per filter group (IDs are language-independent)
local DIFF_OPTIONS = { "All", "LFR", "Normal", "Heroic", "Mythic" }
local DIFF_GROUPS = {
    LFR    = { 7, 17 },
    Normal = { 3, 4, 14 },
    Heroic = { 5, 6, 15 },
    Mythic = { 16 },
}

local soundFiles = {
    ["WaterDrop"]  = "Interface\\AddOns\\ABCReminder\\sound\\WaterDrop.ogg",
    ["SharpPunch"] = "Interface\\AddOns\\ABCReminder\\sound\\SharpPunch.ogg",
}

-- Forward declarations (used before their definition)
local panel, RefreshPanelDynamic, ShowResultFrame, RefreshHistoryFrame, UpdateSessionFrame

-- =========================
-- Helpers
-- =========================
local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = DeepCopy(v) end
    return c
end

local function ApplyDefaults(defaults, target)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            target[k] = DeepCopy(v)
        elseif type(v) == "table" and type(target[k]) == "table" then
            ApplyDefaults(v, target[k])
        end
    end
end

local function ValidatePosition(pos, default)
    if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
        return DeepCopy(default)
    end
    return pos
end

local function GetTimestamp()
    return date("%d/%m %H:%M")
end

local function ActivePct(time, idle)
    if not time or time <= 0 then return 0 end
    return (1 - (idle or 0) / time) * 100
end

local function FormatDuration(sec)
    sec = math.floor((sec or 0) + 0.5)
    if sec < 60 then return sec .. "s" end
    return string.format("%dm%02ds", math.floor(sec / 60), sec % 60)
end

local function GetRatioColor(activeRatio)
    if activeRatio >= 98 then return "E6CC80" end
    if activeRatio >= 95 then return "ff8000" end
    if activeRatio >= 85 then return "A335EE" end
    if activeRatio >= 75 then return "0070DD" end
    if activeRatio >= 60 then return "1EFF00" end
    if activeRatio >= 50 then return "FFFFFF" end
    return "9D9D9D"
end

local function ColorPct(active)
    return string.format("|cff%s%.1f%%|r", GetRatioColor(active), active)
end

local function FormatDelta(delta, suffix)
    if not delta then return "" end
    local col = delta > 0.05 and "00ff00" or (delta < -0.05 and "ff4040" or "aaaaaa")
    return string.format(" |cff%s(%+.1f%s)|r", col, delta, suffix or "")
end

local function IsBusy()
    if UnitCastingInfo("player") or UnitChannelInfo("player") then return true end
    local cd = C_Spell.GetSpellCooldown(GCD_SPELL)
    return (cd and cd.startTime > 0) and true or false
end

-- =========================
-- Fight accumulator
-- =========================
local function NewFight()
    return { time = 0, idle = 0, idleMove = 0, idleCC = 0, gaps = 0, longestGap = 0, curGap = 0 }
end

-- Why is the player idle right now? "cc" (loss of control), "move", or "still"
local function IdleReason()
    if C_LossOfControl and C_LossOfControl.GetActiveLossOfControlDataCount then
        local ok, n = pcall(C_LossOfControl.GetActiveLossOfControlDataCount)
        if ok and type(n) == "number" and n > 0 then return "cc" end
    end
    if (GetUnitSpeed("player") or 0) > 0 or IsFalling() then return "move" end
    return "still"
end

-- Idle time split by reason; older records without the split count as "still"
local function IdleSplit(f)
    local move, cc = f.idleMove or 0, f.idleCC or 0
    return move, cc, math.max(0, (f.idle or 0) - move - cc)
end

local function CloseGap(f)
    if f.curGap >= GAP_MIN then
        f.gaps = f.gaps + 1
        if f.curGap > f.longestGap then f.longestGap = f.curGap end
    end
    f.curGap = 0
end

local function AddFight(dst, src)
    dst.time = dst.time + src.time
    dst.idle = dst.idle + src.idle
    dst.idleMove = (dst.idleMove or 0) + (src.idleMove or 0)
    dst.idleCC   = (dst.idleCC   or 0) + (src.idleCC   or 0)
    dst.gaps = dst.gaps + src.gaps
    if src.longestGap > dst.longestGap then dst.longestGap = src.longestGap end
end

local function MakeAttempt(f, success)
    return {
        date = GetTimestamp(), time = f.time, idle = f.idle,
        idleMove = f.idleMove, idleCC = f.idleCC, gaps = f.gaps, longestGap = f.longestGap, kill = success and true or false,
    }
end

local function PushAttempt(data, att)
    data.attempts = data.attempts or {}
    table.insert(data.attempts, att)
    while #data.attempts > MAX_ATTEMPTS do table.remove(data.attempts, 1) end
end

local function LastSuccess(data)
    if not data or not data.attempts then return nil end
    for i = #data.attempts, 1, -1 do
        if data.attempts[i].kill then return data.attempts[i] end
    end
    return nil
end

-- =========================
-- IsEnabled : perso + spec courante
-- =========================
local function IsEnabledForCurrentSpec()
    if not CharABCRDB or not CharABCRDB.enabled then return false end
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

local function FindChatTab()
    for i = 1, NUM_CHAT_WINDOWS do
        if GetChatWindowInfo(i) == "ABCReminder" then return _G["ChatFrame" .. i] end
    end
    return nil
end

local function EnsureChatTab()
    abcChatFrame = FindChatTab()
    if not abcChatFrame then
        FCF_OpenNewWindow("ABCReminder")
        abcChatFrame = FindChatTab()
    end
end

local function ABCPrint(msg)
    if not ABCReminderDB.showSessionResults then return end
    local mode = ABCReminderDB.sessionDisplay
    if mode == "chat" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffABC|r " .. msg)
    elseif mode == "tab" then
        EnsureChatTab()
        local target = abcChatFrame or DEFAULT_CHAT_FRAME
        target:AddMessage("|cff00ccffABC|r " .. msg)
    end
end

-- =========================
-- Engine state
-- =========================
local inCombat        = false
local encounterActive = false
local fight           = NewFight()  -- current pull (trash or boss)
local lastFight       = nil         -- last trivial pull, for the session window
local mplus           = nil         -- active M+ run: { name, level, fight, bosses, resumed }
local checkElapsed, soundElapsed, wasEligible, soundHandle = 0, 0, false, nil

local function StopReminderSound()
    if soundHandle then StopSound(soundHandle); soundHandle = nil end
    wasEligible, soundElapsed = false, 0
end

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

-- Shows a frame and (re)arms its auto-hide timer; a newer display cancels the older timer.
local function ShowWithAutoHide(f)
    f:Show()
    if f.hideTimer then f.hideTimer:Cancel(); f.hideTimer = nil end
    local delay = ABCReminderDB.intervalStatsDisplay
    if delay and delay > 0 then
        f.hideTimer = C_Timer.NewTimer(delay, function()
            f.hideTimer = nil
            f:Hide()
        end)
    end
end

-- =========================
-- UI: Result Frame (card)
-- =========================
local resultFrame = CreateBaseFrame("ABCReminderResult", 270, 160, "bossStatsPosition")

resultFrame.title = resultFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
resultFrame.title:SetPoint("TOP", 0, -10)
resultFrame.title:SetWidth(220); resultFrame.title:SetMaxLines(2)

resultFrame.sep = resultFrame:CreateTexture(nil, "ARTWORK")
resultFrame.sep:SetSize(240, 1)
resultFrame.sep:SetPoint("TOP", resultFrame.title, "BOTTOM", 0, -6)
resultFrame.sep:SetColorTexture(0.4, 0.4, 0.4, 0.8)

resultFrame.content = resultFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
resultFrame.content:SetPoint("TOPLEFT", resultFrame.sep, "BOTTOMLEFT", 4, -8)
resultFrame.content:SetWidth(236); resultFrame.content:SetJustifyH("LEFT")
resultFrame.content:SetSpacing(2)

resultFrame.closeBtn = CreateFrame("Button", nil, resultFrame, "UIPanelCloseButton")
resultFrame.closeBtn:SetPoint("TOPRIGHT", -3, -4)
resultFrame.closeBtn:SetScript("OnClick", function() resultFrame:Hide() end)

-- "3.1s moving, 1.9s standing still" (chat / tooltips)
local function IdleSplitText(f)
    local move, cc, still = IdleSplit(f)
    local parts = {}
    if move  >= 0.05 then parts[#parts+1] = string.format("%.1fs moving", move) end
    if cc    >= 0.05 then parts[#parts+1] = string.format("%.1fs CC", cc) end
    if still >= 0.05 then parts[#parts+1] = string.format("%.1fs standing still", still) end
    return table.concat(parts, ", ")
end

-- Common "how did this pull go" lines
local function FightLines(f, prev)
    local active = ActivePct(f.time, f.idle)
    local lines = {}
    local delta = prev and (active - ActivePct(prev.time, prev.idle)) or nil
    lines[#lines+1] = "Active: " .. ColorPct(active) .. FormatDelta(delta, " vs last")
    lines[#lines+1] = string.format("Combat: |cffffffff%s|r   Idle: |cffffffff%.1fs|r",
        FormatDuration(f.time), f.idle)
    if f.idle >= 0.05 then
        local move, cc, still = IdleSplit(f)
        local split = string.format("  |cff88ccffmoving %.1fs|r", move)
        if cc >= 0.05 then split = split .. string.format("  |cffcc88ffCC %.1fs|r", cc) end
        split = split .. string.format("  |cffffcc66standing still %.1fs|r", still)
        lines[#lines+1] = split
    end
    if f.gaps > 0 then
        lines[#lines+1] = string.format("Idle gaps (>%ds): |cffffffff%d|r   longest |cffffffff%.1fs|r",
            GAP_MIN, f.gaps, f.longestGap)
    else
        lines[#lines+1] = string.format("Idle gaps (>%ds): |cff00ff00none|r", GAP_MIN)
    end
    return lines
end

-- card = { title, lines }
ShowResultFrame = function(title, lines)
    resultFrame.title:SetText(title)
    resultFrame.content:SetText(table.concat(lines, "\n"))
    local h = 10 + resultFrame.title:GetStringHeight() + 7 + 8 + resultFrame.content:GetStringHeight() + 14
    resultFrame:SetHeight(math.max(h, 80))
    ShowWithAutoHide(resultFrame)
end

-- =========================
-- UI: Session Frame
-- =========================
local statsTable = CreateBaseFrame("ABCReminderStatsTable", 230, 120, "statsPosition")

statsTable.title = statsTable:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statsTable.title:SetPoint("TOP", 0, -10); statsTable.title:SetText("|cffffd100Session|r")

statsTable.sep = statsTable:CreateTexture(nil, "ARTWORK")
statsTable.sep:SetSize(210, 1)
statsTable.sep:SetPoint("TOP", statsTable.title, "BOTTOM", 0, -5)
statsTable.sep:SetColorTexture(0.4, 0.4, 0.4, 0.8)

statsTable.content = statsTable:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statsTable.content:SetPoint("TOPLEFT", statsTable.sep, "BOTTOMLEFT", 4, -8)
statsTable.content:SetWidth(206); statsTable.content:SetJustifyH("LEFT")
statsTable.content:SetSpacing(2)

local function ResetSession()
    CharABCRDB.sessionTrivial = { totalTime=0, idleTime=0, idleMove=0, idleCC=0, outsideOnly=true }
    lastFight = nil
end

statsTable.resetBtn = CreateFrame("Button", nil, statsTable, "UIPanelButtonTemplate")
statsTable.resetBtn:SetSize(110, 18); statsTable.resetBtn:SetPoint("BOTTOM", 0, 8)
statsTable.resetBtn:SetText("Reset Session")
statsTable.resetBtn:SetScript("OnClick", function()
    ResetSession()
    statsTable.content:SetText("|cff00ff00Reset!|r")
end)

UpdateSessionFrame = function()
    local st = CharABCRDB.sessionTrivial
    local sessActive = ActivePct(st.totalTime, st.idleTime)
    local lf = lastFight

    local lines = {}
    if lf then
        lines[#lines+1] = string.format("Last:     %s  idle %.1fs / %s",
            ColorPct(ActivePct(lf.time, lf.idle)), lf.idle, FormatDuration(lf.time))
        if lf.idle >= 0.05 then lines[#lines+1] = "   |cffaaaaaa" .. IdleSplitText(lf) .. "|r" end
    else
        lines[#lines+1] = "Last:     |cff888888-|r"
    end
    lines[#lines+1] = string.format("Session: %s  idle %s / %s",
        ColorPct(sessActive), FormatDuration(st.idleTime), FormatDuration(st.totalTime))
    if (st.idleTime or 0) >= 0.05 then
        lines[#lines+1] = "   |cffaaaaaa" .. IdleSplitText({ idle = st.idleTime, idleMove = st.idleMove, idleCC = st.idleCC }) .. "|r"
    end
    statsTable.content:SetText(table.concat(lines, "\n"))

    if not ABCReminderDB.showSessionResults then return end
    if ABCReminderDB.sessionDisplay == "window" then
        ShowWithAutoHide(statsTable)
    else
        local lastStr = ""
        if lf then
            lastStr = string.format(" | Last: %.1f%% (%s", ActivePct(lf.time, lf.idle), FormatDuration(lf.time))
            if lf.idle >= 0.05 then lastStr = lastStr .. ", idle " .. IdleSplitText(lf) end
            lastStr = lastStr .. ")"
        end
        ABCPrint(string.format("Session: %.1f%% active over %s%s",
            sessActive, FormatDuration(st.totalTime), lastStr))
    end
end

-- =========================
-- UI: History Frame
-- =========================
local HISTORY_W, HISTORY_H = 470, 340
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
local COL_DATE_W  = 70
local COL_BEST_W  = 86
local COL_LAST_W  = 62
local COL_COUNT_W = 40
local COL_NAME_W  = SCROLL_W - (COL_DATE_W + COL_BEST_W + COL_LAST_W + COL_COUNT_W) - 22

-- x offsets (from the right edge) of each right-aligned column
local OFF_DATE  = -2
local OFF_BEST  = OFF_DATE  - (COL_DATE_W + 4)
local OFF_LAST  = OFF_BEST  - (COL_BEST_W + 4)
local OFF_COUNT = OFF_LAST  - (COL_LAST_W + 4)

local function MakeColumn(parent, font, width, rightOffset)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("RIGHT", parent, "RIGHT", rightOffset, 0)
    fs:SetWidth(width); fs:SetJustifyH("RIGHT"); fs:SetWordWrap(false)
    return fs
end

local colHeaderFrame = CreateFrame("Frame", nil, historyFrame)
colHeaderFrame:SetSize(SCROLL_W, 18)
colHeaderFrame:SetPoint("TOPLEFT", historyFrame.sep, "BOTTOMLEFT", 0, -2)

local colHeaderBg = colHeaderFrame:CreateTexture(nil, "BACKGROUND")
colHeaderBg:SetAllPoints(); colHeaderBg:SetColorTexture(0.18, 0.18, 0.18, 0.8)

local colHdrName = colHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
colHdrName:SetPoint("LEFT", colHeaderFrame, "LEFT", 6, 0)
colHdrName:SetWidth(COL_NAME_W); colHdrName:SetJustifyH("LEFT")
local colHdrCount = MakeColumn(colHeaderFrame, "GameFontNormalSmall", COL_COUNT_W, OFF_COUNT)
local colHdrLast  = MakeColumn(colHeaderFrame, "GameFontNormalSmall", COL_LAST_W,  OFF_LAST)
local colHdrBest  = MakeColumn(colHeaderFrame, "GameFontNormalSmall", COL_BEST_W,  OFF_BEST)
local colHdrDate  = MakeColumn(colHeaderFrame, "GameFontNormalSmall", COL_DATE_W,  OFF_DATE)

local scrollFrame = CreateFrame("ScrollFrame", nil, historyFrame, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT",     colHeaderFrame, "BOTTOMLEFT",  0,   -2)
scrollFrame:SetPoint("BOTTOMRIGHT", historyFrame,   "BOTTOMRIGHT", -26, 12)

local scrollChild = CreateFrame("Frame", nil, scrollFrame)
scrollChild:SetSize(SCROLL_W, 1)
scrollFrame:SetScrollChild(scrollChild)

historyFrame.currentFilter = "raid"

local function AttemptTooltipLine(a, isMPlus)
    local active = ActivePct(a.time, a.idle)
    local status
    if isMPlus then
        if not a.kill then status = "|cffff4040abandoned|r"
        elseif a.onTime == true then status = "|cff00ff00timed|r"
        elseif a.onTime == false then status = "|cffff9900over time|r"
        else status = "|cff00ff00done|r" end
        local lvl = a.level and ("+" .. a.level .. " ") or ""
        return string.format("%s  %s%s  %s  %s", a.date or "?", lvl, FormatDuration(a.time),
            ColorPct(active), status)
    end
    status = a.kill and "|cff00ff00kill|r" or "|cffff4040wipe|r"
    local line = string.format("%s  %s  %s  %s", a.date or "?", FormatDuration(a.time), ColorPct(active), status)
    if a.idleMove then  -- older attempts have no split
        local move, cc, still = IdleSplit(a)
        line = line .. string.format("  |cff888888still %.1fs / moving %.1fs%s|r", still, move,
            cc >= 0.05 and string.format(" / CC %.1fs", cc) or "")
    end
    return line
end

local rowPool = {}

local function GetRow(i)
    if rowPool[i] then return rowPool[i] end
    local row = CreateFrame("Frame", nil, scrollChild)
    row:SetSize(SCROLL_W, 22)
    row:SetPoint("TOPLEFT", 0, -(i-1)*22)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    local shade = (i % 2 == 0) and 0.06 or 0.12
    row.bg:SetColorTexture(shade, shade, shade, 0.5)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.nameText:SetWidth(COL_NAME_W); row.nameText:SetJustifyH("LEFT"); row.nameText:SetWordWrap(false)
    row.countText = MakeColumn(row, "GameFontHighlightSmall", COL_COUNT_W, OFF_COUNT)
    row.lastText  = MakeColumn(row, "GameFontHighlightSmall", COL_LAST_W,  OFF_LAST)
    row.bestText  = MakeColumn(row, "GameFontHighlightSmall", COL_BEST_W,  OFF_BEST)
    row.dateText  = MakeColumn(row, "GameFontHighlightSmall", COL_DATE_W,  OFF_DATE)

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local e = self.entry
        if not e then return end
        local d, isMPlus = e.data, e.isMPlus
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(e.name, 1, 1, 1)
        if d.bestRatio and d.bestDate then
            local lvl = (isMPlus and d.bestLevel) and (" at +" .. d.bestLevel) or ""
            GameTooltip:AddLine(string.format("Best: %.1f%% active%s  (%s)", 100 - d.bestRatio, lvl, d.bestDate), 0, 1, 0)
        end
        if (d.totalTime or 0) > 0 then
            GameTooltip:AddLine(string.format("Average: %.1f%% active over %s",
                ActivePct(d.totalTime, d.idleTime), FormatDuration(d.totalTime)), 0.8, 0.8, 0.8)
        end
        if d.attempts and #d.attempts > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Recent attempts:", 1, 0.8, 0)
            for i = #d.attempts, 1, -1 do
                GameTooltip:AddLine("  " .. AttemptTooltipLine(d.attempts[i], isMPlus), 0.8, 0.8, 0.8)
            end
        end
        local last = isMPlus and LastSuccess(d)
        local bosses = (last and last.bosses) or d.bosses
        if isMPlus and bosses and #bosses > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Bosses (last completed run):", 1, 0.8, 0)
            for _, b in ipairs(bosses) do
                GameTooltip:AddLine(string.format("  %s: %.1f%% active", b.name, 100 - b.ratio), 0.8, 0.8, 0.8)
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rowPool[i] = row
    return row
end

local function MatchesDiffFilter(name, data, diff)
    if diff == "All" then return true end
    local group = DIFF_GROUPS[diff]
    if not group then return true end
    if data.difficultyID then
        for _, id in ipairs(group) do
            if id == data.difficultyID then return true end
        end
        return false
    end
    -- Older records only have the (localized) difficulty name in their key
    for _, id in ipairs(group) do
        local dName = GetDifficultyInfo(id)
        if dName and name:find("[" .. dName .. "]", 1, true) then return true end
    end
    return false
end

local function GetHistoryEntries(filter, diffFilter)
    local entries = {}
    if filter == "raid" then
        for name, data in pairs(CharABCRDB.statistics.perBoss) do
            if MatchesDiffFilter(name, data, diffFilter) then
                entries[#entries+1] = { name = name:gsub("^Boss: ", ""), data = data, isMPlus = false }
            end
        end
    else
        for name, data in pairs(CharABCRDB.statistics.perInstance) do
            entries[#entries+1] = { name = name, data = data, isMPlus = true }
        end
    end
    table.sort(entries, function(a, b)
        local ra, rb = a.data.bestRatio or 100, b.data.bestRatio or 100
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    return entries
end

RefreshHistoryFrame = function()
    local entries  = GetHistoryEntries(historyFrame.currentFilter, historyFrame.currentDiffFilter)
    local isRaid   = historyFrame.currentFilter == "raid"

    local function TabColor(btn, active)
        if active then btn:GetFontString():SetTextColor(1, 0.8, 0)
        else btn:GetFontString():SetTextColor(0.8, 0.8, 0.8) end
    end
    TabColor(historyFrame.tabRaid, isRaid)
    TabColor(historyFrame.tabMythic, not isRaid)

    if isRaid then
        diffFilterDrop:Show()
    else
        diffFilterDrop:Hide()
        historyFrame.currentDiffFilter = "All"
        UIDropDownMenu_SetText(diffFilterDrop, "All")
    end

    colHdrName:SetText(isRaid and "|cffaaaaaaBoss|r" or "|cffaaaaaaDungeon|r")
    colHdrCount:SetText(isRaid and "|cffaaaaaaKills|r" or "|cffaaaaaaRuns|r")
    colHdrLast:SetText("|cffaaaaaaLast|r")
    colHdrBest:SetText("|cffaaaaaaBest|r")
    colHdrDate:SetText("|cffaaaaaaBest on|r")

    for i, entry in ipairs(entries) do
        local row, d = GetRow(i), entry.data
        row.entry = entry
        row.nameText:SetText(entry.name)
        local count = isRaid and d.kills or d.runs
        row.countText:SetText(count and tostring(count) or "|cff888888-|r")

        local last = LastSuccess(d)
        row.lastText:SetText(last and ColorPct(ActivePct(last.time, last.idle)) or "|cff888888-|r")

        if d.bestRatio and d.bestDate then
            local best = ColorPct(100 - d.bestRatio)
            if not isRaid and d.bestLevel then best = best .. " |cffaaaaaa+" .. d.bestLevel .. "|r" end
            row.bestText:SetText(best)
        else
            row.bestText:SetText("|cff888888-|r")
        end
        row.dateText:SetText(d.bestDate and ("|cff888888" .. d.bestDate .. "|r") or "")
        row:Show()
    end
    for i = #entries + 1, #rowPool do
        rowPool[i].entry = nil; rowPool[i]:Hide()
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
-- Records helpers
-- =========================
-- Updates best on a successful attempt; returns isRecord, isFirst, improvement (active % points)
local function UpdateBest(data, f, level)
    local ratio = (f.time > 0) and (f.idle / f.time) * 100 or 0
    if not data.bestDate then
        data.bestRatio, data.bestDate, data.bestLevel = ratio, GetTimestamp(), level
        return false, true, nil
    end
    if ratio < (data.bestRatio or 100) then
        local gain = (data.bestRatio or 100) - ratio
        data.bestRatio, data.bestDate, data.bestLevel = ratio, GetTimestamp(), level
        PlaySound(888, ABCReminderDB.soundChannel)
        return true, false, gain
    end
    return false, false, nil
end

local function BestLines(data, isRecord, isFirst, gain, firstLabel)
    local lines = { " " }
    if isFirst then
        lines[#lines+1] = "|cff00ccff" .. firstLabel .. "|r"
    elseif isRecord then
        lines[#lines+1] = string.format("|cffFFD700New personal record!|r |cff00ff00(+%.1f)|r", gain)
    elseif data.bestRatio then
        lines[#lines+1] = string.format("Personal best: |cff00ff00%.1f%%|r |cff888888[%s]|r",
            100 - data.bestRatio, data.bestDate or "?")
    end
    return lines
end

local function Concat(a, b)
    for _, v in ipairs(b) do a[#a+1] = v end
    return a
end

-- =========================
-- Session M+
-- =========================
local function GetKeystoneLevel()
    if C_ChallengeMode.GetActiveKeystoneInfo then
        local level = C_ChallengeMode.GetActiveKeystoneInfo()
        if type(level) == "number" and level > 0 then return level end
    end
    return nil
end

local function GetCompletionDetails()
    if C_ChallengeMode.GetChallengeCompletionInfo then
        local ok, info = pcall(C_ChallengeMode.GetChallengeCompletionInfo)
        if ok and type(info) == "table" then return info.level, info.onTime end
    end
    return nil, nil
end

local function StartMPlusSession(resumed)
    local mapID = C_ChallengeMode.GetActiveChallengeMapID()
    local name  = mapID and C_ChallengeMode.GetMapUIInfo(mapID) or "M+ Unknown"
    mplus = { name = name, level = GetKeystoneLevel(), fight = NewFight(), bosses = {}, resumed = resumed }
end

local function EndMPlusSession(completed)
    if not mplus then return end
    local m = mplus
    mplus = nil
    -- pull still in progress when the key ends (e.g. leaving mid-combat)
    if fight.time > 0 and not encounterActive then
        CloseGap(fight); AddFight(m.fight, fight); fight = NewFight()
    end
    local f = m.fight
    CloseGap(f)
    if f.time <= 0 then return end
    if not completed and not ABCReminderDB.recordWipes then return end
    -- a session resumed after /reload can't tell "left the key" from "reloaded after finishing it"
    if not completed and m.resumed then return end

    local level, onTime = m.level, nil
    if completed then
        local cLevel, cOnTime = GetCompletionDetails()
        level, onTime = cLevel or level, cOnTime
    end

    local perInstance = CharABCRDB.statistics.perInstance
    perInstance[m.name] = perInstance[m.name] or { totalTime=0, idleTime=0 }
    local data = perInstance[m.name]
    local prev = LastSuccess(data)

    local att = MakeAttempt(f, completed)
    att.level, att.onTime, att.bosses = level, onTime, m.bosses

    local isRecord, isFirst, gain = false, false, nil
    if completed then
        data.runs      = (data.runs or 0) + 1
        data.totalTime = (data.totalTime or 0) + f.time
        data.idleTime  = (data.idleTime  or 0) + f.idle
        -- a run resumed after /reload is missing its start: keep it, but not as a record
        if not m.resumed then isRecord, isFirst, gain = UpdateBest(data, f, level) end
    else
        data.abandoned = (data.abandoned or 0) + 1
    end
    PushAttempt(data, att)

    local lvlStr = level and (" +" .. level) or ""
    local title
    if not completed then title = "|cff888888" .. m.name .. lvlStr .. " (abandoned)|r"
    elseif isRecord then title = "|cffFFD700" .. m.name .. lvlStr .. "|r"
    else title = "|cff00ccff" .. m.name .. lvlStr .. "|r" end

    local lines = FightLines(f, completed and prev or nil)
    if completed then
        local status = (onTime == true and "|cff00ff00timed|r") or (onTime == false and "|cffff9900over time|r") or nil
        if status then lines[#lines+1] = "Key: " .. status end
        if m.resumed then lines[#lines+1] = "|cff888888Partial (reloaded during the key)|r" end
    end
    if #m.bosses > 0 then
        lines[#lines+1] = " "
        for _, b in ipairs(m.bosses) do
            lines[#lines+1] = string.format("  %s: %s", b.name, ColorPct(100 - b.ratio))
        end
    end
    if completed then Concat(lines, BestLines(data, isRecord, isFirst, gain, "First run recorded")) end
    ShowResultFrame(title, lines)
    ABCPrint(string.format("%s%s: %.1f%% active over %s%s%s", m.name, lvlStr, ActivePct(f.time, f.idle),
        FormatDuration(f.time), completed and "" or " (abandoned)",
        f.idle >= 0.05 and (" | idle " .. IdleSplitText(f)) or ""))
end

-- =========================
-- Logic: end of a pull
-- =========================
local function FlushTrash(label)
    local f = fight
    fight = NewFight()
    CloseGap(f)
    if mplus then
        if f.time > 0 then AddFight(mplus.fight, f) end
        return
    end
    if f.time < MIN_PULL then return end

    local instanceName, instanceType = GetInstanceInfo()
    -- in raids only boss encounters are measured; trash is ignored
    if instanceType == "raid" then return end
    if not ABCReminderDB.enabledInstances[instanceType or "none"] then return end

    lastFight = f
    local st = CharABCRDB.sessionTrivial
    st.totalTime = st.totalTime + f.time
    st.idleTime  = st.idleTime  + f.idle
    st.idleMove  = (st.idleMove or 0) + f.idleMove
    st.idleCC    = (st.idleCC   or 0) + f.idleCC

    if ABCReminderDB.showSessionResults and ABCReminderDB.sessionDisplay == "window" then
        local lines = FightLines(f, nil)
        lines[#lines+1] = " "
        lines[#lines+1] = string.format("Session: %s over %s",
            ColorPct(ActivePct(st.totalTime, st.idleTime)), FormatDuration(st.totalTime))
        local name = label or (instanceType == "none" and GetZoneText()) or instanceName or "Session"
        ShowResultFrame("|cffffd100" .. name .. "|r", lines)
    end
    UpdateSessionFrame()
end

local function FinishMPlusBoss(encounterName, success)
    local f = fight
    fight = NewFight()
    CloseGap(f)
    AddFight(mplus.fight, f)  -- wipes are part of the key's combat time too
    if f.time <= 0 then return end
    if success then
        table.insert(mplus.bosses, { name = encounterName, ratio = (f.idle / f.time) * 100 })
    elseif not ABCReminderDB.recordWipes then
        return
    end
    local lines = FightLines(f, nil)
    lines[#lines+1] = " "
    lines[#lines+1] = string.format("Key so far: %s over %s",
        ColorPct(ActivePct(mplus.fight.time, mplus.fight.idle)), FormatDuration(mplus.fight.time))
    local title = success and ("|cffffd100" .. encounterName .. " (M+)|r")
                          or ("|cff888888" .. encounterName .. " (M+ wipe)|r")
    ShowResultFrame(title, lines)
end

local function FinishRaidBoss(encounterName, difficultyID, success)
    local f = fight
    fight = NewFight()
    CloseGap(f)
    if f.time < (ABCReminderDB.minRaidBossDuration or 40) then return end
    if not success and not ABCReminderDB.recordWipes then return end

    local diffName = GetDifficultyInfo(difficultyID) or tostring(difficultyID)
    local key  = "Boss: " .. encounterName .. " [" .. diffName .. "]"
    local perBoss = CharABCRDB.statistics.perBoss
    perBoss[key] = perBoss[key] or { totalTime=0, idleTime=0 }
    local data = perBoss[key]
    data.difficultyID = difficultyID

    local prev = LastSuccess(data)
    local isRecord, isFirst, gain = false, false, nil
    if success then
        data.kills     = (data.kills or 0) + 1
        data.totalTime = (data.totalTime or 0) + f.time
        data.idleTime  = (data.idleTime  or 0) + f.idle
        isRecord, isFirst, gain = UpdateBest(data, f, nil)
    else
        data.wipes = (data.wipes or 0) + 1
    end
    PushAttempt(data, MakeAttempt(f, success))

    local display = encounterName .. " [" .. diffName .. "]"
    local title
    if not success then title = "|cff888888" .. display .. " (wipe)|r"
    elseif isRecord then title = "|cffFFD700" .. display .. "|r"
    else title = "|cff00ccff" .. display .. "|r" end

    local lines = FightLines(f, success and prev or nil)
    if success then Concat(lines, BestLines(data, isRecord, isFirst, gain, "First kill recorded")) end
    ShowResultFrame(title, lines)
    ABCPrint(string.format("%s: %.1f%% active over %s%s%s", display, ActivePct(f.time, f.idle),
        FormatDuration(f.time), success and "" or " (wipe)",
        f.idle >= 0.05 and (" | idle " .. IdleSplitText(f)) or ""))
end

local function OnEncounterEnd(encounterName, difficultyID, success)
    encounterActive = false
    if mplus then
        FinishMPlusBoss(encounterName, success)
    elseif select(2, GetInstanceInfo()) == "raid" then
        FinishRaidBoss(encounterName, difficultyID, success)
    else
        FlushTrash(encounterName)  -- normal dungeon / scenario / delve boss
    end
end

-- =========================
-- Saved variables init
-- =========================
local function InitSavedVariables()
    ABCReminderDB = ABCReminderDB or {}
    CharABCRDB    = CharABCRDB    or {}
    ApplyDefaults(DB_DEFAULTS,   ABCReminderDB)
    ApplyDefaults(CHAR_DEFAULTS, CharABCRDB)

    local db = ABCReminderDB
    if db.sessionChatDedicated ~= nil then
        if db.sessionChatDedicated == true then db.sessionDisplay = "tab" end
        db.sessionChatDedicated = nil
    end
    -- removed features
    db.showSQW, db.alwaysShowSQW, db.sqwPosition, db.trackOutsideInstance = nil, nil, nil, nil

    db.statsPosition     = ValidatePosition(db.statsPosition,     DB_DEFAULTS.statsPosition)
    db.bossStatsPosition = ValidatePosition(db.bossStatsPosition, DB_DEFAULTS.bossStatsPosition)
    db.historyPosition   = ValidatePosition(db.historyPosition,   DB_DEFAULTS.historyPosition)

    local stats = CharABCRDB.statistics
    stats.perInstance = stats.perInstance or {}
    stats.perBoss     = stats.perBoss     or {}

    local function Place(f, pos)
        f:ClearAllPoints()
        f:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
    end
    Place(statsTable,   db.statsPosition)
    Place(resultFrame,  db.bossStatsPosition)
    Place(historyFrame, db.historyPosition)
end

-- =========================
-- Engine & Events
-- =========================
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("CHALLENGE_MODE_RESET")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

local function OnUpdate(_, delta)
    if not inCombat then return end
    if not IsEnabledForCurrentSpec() then StopReminderSound(); return end
    if UnitIsDeadOrGhost("player") then
        -- time spent dead is neither active nor idle
        CloseGap(fight)
        if ABCReminderDB.clipSound then StopReminderSound() end
        return
    end

    local busy = IsBusy()
    fight.time = fight.time + delta
    if busy then
        CloseGap(fight)
    else
        fight.idle   = fight.idle + delta
        fight.curGap = fight.curGap + delta
        local reason = IdleReason()
        if reason == "move" then fight.idleMove = fight.idleMove + delta
        elseif reason == "cc" then fight.idleCC = fight.idleCC + delta end
    end

    checkElapsed = checkElapsed + delta
    if checkElapsed < 0.1 then return end
    checkElapsed = 0

    local _, it = IsInInstance()
    if ABCReminderDB.enabledInstances[it or "none"] and not busy then
        if not wasEligible or soundElapsed >= ABCReminderDB.soundInterval then
            local _, handle = PlaySoundFile(soundFiles[ABCReminderDB.soundFile], ABCReminderDB.soundChannel)
            soundHandle = handle
            wasEligible, soundElapsed = true, 0
        else
            soundElapsed = soundElapsed + 0.1
        end
    else
        if ABCReminderDB.clipSound and soundHandle and busy then
            StopSound(soundHandle); soundHandle = nil
        end
        wasEligible, soundElapsed = false, 0
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= "ABCReminder" then return end
        self:UnregisterEvent("ADDON_LOADED")
        InitSavedVariables()
        self:SetScript("OnUpdate", OnUpdate)

    elseif event == "PLAYER_ENTERING_WORLD" then
        local _, instanceType = IsInInstance()
        if instanceType and instanceType ~= "none" then
            CharABCRDB.sessionTrivial = { totalTime=0, idleTime=0, idleMove=0, idleCC=0, outsideOnly=false }
            lastFight = nil
        end
        -- encounter that ended while we were away (release, disconnect…)
        if encounterActive and not IsEncounterInProgress() then
            encounterActive = false
            fight = NewFight()
        end
        -- keep the M+ session in sync with the game (left the key / reloaded inside it)
        local keyActive = C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive()
        if mplus and not keyActive then
            EndMPlusSession(false)
        elseif keyActive and not mplus then
            StartMPlusSession(true)
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        if panel and panel:IsShown() then RefreshPanelDynamic() end

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        if ABCReminderDB.clipSound then StopReminderSound() else wasEligible, soundElapsed = false, 0 end
        -- during a boss (death, phase transition) keep accumulating into the same fight
        if not encounterActive then FlushTrash() end

    elseif event == "ENCOUNTER_START" then
        if fight.time > 0 then FlushTrash() end  -- trash pulled into the boss
        fight = NewFight()
        encounterActive = true

    elseif event == "ENCOUNTER_END" then
        -- ignore an END without a matching START (duplicate END after a kill, or /reload mid-boss)
        if not encounterActive then return end
        local _, encounterName, difficultyID, _, success = ...
        OnEncounterEnd(encounterName or "Unknown", difficultyID, success == 1)

    elseif event == "CHALLENGE_MODE_START" then
        StartMPlusSession(false)

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        EndMPlusSession(true)

    elseif event == "CHALLENGE_MODE_RESET" then
        EndMPlusSession(false)
    end
end)

-- =========================
-- Options Panel
-- =========================
panel = CreateFrame("Frame", "ABCReminderOptions")
panel.name = "ABCReminder"

-- Références aux widgets dynamiques, stockées après l'init
-- pour pouvoir les mettre à jour sans recréer le panneau.
local dynWidgets = {}

-- Appelé à chaque OnShow ET depuis PLAYER_SPECIALIZATION_CHANGED
RefreshPanelDynamic = function()
    if dynWidgets.charEnable then
        dynWidgets.charEnable:SetChecked(CharABCRDB.enabled)
    end
    if dynWidgets.BuildSpecCheckboxes then
        dynWidgets.BuildSpecCheckboxes()
    end
end

local function SectionHeader(C, anchor, text, yOff)
    local h = C:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
    h:SetText("|cffffd100" .. text .. "|r")
    local l = C:CreateTexture(nil, "ARTWORK"); l:SetSize(460, 1)
    l:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -3); l:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    return h
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
        local hGen = SectionHeader(C, mainTitle, "General", -10)

        local charEnable = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
        charEnable:SetPoint("TOPLEFT", hGen, "BOTTOMLEFT", 0, -14)
        charEnable.Text:SetText("Enable for this character")
        charEnable:SetChecked(CharABCRDB.enabled)
        charEnable:SetScript("OnClick", function(cb) CharABCRDB.enabled = cb:GetChecked() end)
        dynWidgets.charEnable = charEnable

        local trackNote = C:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        trackNote:SetPoint("TOPLEFT", charEnable, "BOTTOMLEFT", 0, -8)
        trackNote:SetText("|cffaaaaaaTrack statistics and play reminders in:|r")

        local instKeys = {}
        for k in pairs(ABCReminderDB.enabledInstances) do table.insert(instKeys, k) end
        table.sort(instKeys)
        local lastInstCb, firstLeft
        for idx, inst in ipairs(instKeys) do
            local cb = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
            if idx % 2 ~= 0 then
                cb:SetPoint("TOPLEFT", idx == 1 and trackNote or lastInstCb, "BOTTOMLEFT", 0, idx == 1 and -4 or 2)
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

        -- ── Section : Specializations ──────────────────────────────────────
        local hSpec = SectionHeader(C, lastInstCb, "Specializations", -12)

        local specNote = C:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        specNote:SetPoint("TOPLEFT", hSpec, "BOTTOMLEFT", 0, -16)
        specNote:SetText("|cffaaaaaaUncheck to disable ABCReminder for that specialization|r")

        -- Conteneur de hauteur fixe : les sections suivantes sont ancrées dessus
        local specContainer = CreateFrame("Frame", nil, C)
        specContainer:SetPoint("TOPLEFT", specNote, "BOTTOMLEFT", 0, -6)
        specContainer:SetSize(460, 52)

        local function BuildSpecCheckboxes()
            for _, child in ipairs({ specContainer:GetChildren() }) do
                child:Hide(); child:SetParent(nil)
            end

            local numSpecs = GetNumSpecializations()
            if numSpecs == 0 then return end

            local currentSpecIndex = GetSpecialization()
            local currentSpecID    = currentSpecIndex and (GetSpecializationInfo(currentSpecIndex)) or nil

            local prevCb, prevCbR = nil, nil
            for i = 1, numSpecs do
                local specID, specName, _, specIcon = GetSpecializationInfo(i)
                if specID then
                    local cb = CreateFrame("CheckButton", nil, specContainer, "InterfaceOptionsCheckButtonTemplate")
                    if i % 2 ~= 0 then
                        cb:SetPoint("TOPLEFT", prevCb or specContainer, prevCb and "BOTTOMLEFT" or "TOPLEFT", 0, prevCb and 2 or 0)
                        prevCb = cb
                    else
                        cb:SetPoint("TOPLEFT", prevCbR, "TOPLEFT", 200, 0)
                    end

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
                        CharABCRDB.disabledSpecs[capturedID] = (not btn:GetChecked()) or nil
                    end)
                    if i % 2 ~= 0 then prevCbR = cb end
                end
            end
        end

        BuildSpecCheckboxes()
        dynWidgets.BuildSpecCheckboxes = BuildSpecCheckboxes

        -- ── Section : Sound ────────────────────────────────────────────────
        local hSnd = SectionHeader(C, specContainer, "Sound", -12)

        local slider = CreateFrame("Slider", "ABCReminderSlider", C, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", hSnd, "BOTTOMLEFT", 6, -28)
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

        -- ── Section : Statistics ───────────────────────────────────────────
        local hStat = SectionHeader(C, chanLabel, "Statistics", -22)

        local statsDisplay = CreateFrame("Slider", "ABCRStatsDur", C, "OptionsSliderTemplate")
        statsDisplay:SetPoint("TOPLEFT", hStat, "BOTTOMLEFT", 0, -28)
        statsDisplay:SetMinMaxValues(0, 30); statsDisplay:SetValueStep(5); statsDisplay:SetObeyStepOnDrag(true)
        statsDisplay:SetValue(ABCReminderDB.intervalStatsDisplay)
        statsDisplay.Text:SetJustifyH("LEFT"); statsDisplay.Text:ClearAllPoints()
        statsDisplay.Text:SetPoint("TOPLEFT", statsDisplay, "TOPLEFT", 0, 14)
        statsDisplay.Text:SetText("Floating window fade-out delay (0 = stays open)")
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
                local c = enabled and 1 or 0.5
                r.lbl:SetTextColor(c, c, c)
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

        SetRadioDisplay(ABCReminderDB.sessionDisplay or "chat")
        UpdateRadioState()

        showResultsCb:SetScript("OnClick", function(cb)
            ABCReminderDB.showSessionResults = cb:GetChecked()
            UpdateRadioState()
        end)

        local lastRadio = radios[#radios].btn

        local wipesCb = CreateFrame("CheckButton", nil, C, "InterfaceOptionsCheckButtonTemplate")
        wipesCb:SetPoint("TOPLEFT", lastRadio, "BOTTOMLEFT", -20, -8)
        wipesCb.Text:SetText("Record wipes and abandoned keys in history (never counted as records)")
        wipesCb:SetChecked(ABCReminderDB.recordWipes)
        wipesCb:SetScript("OnClick", function(cb) ABCReminderDB.recordWipes = cb:GetChecked() end)

        local minDurSlider = CreateFrame("Slider", "ABCRMinBossDur", C, "OptionsSliderTemplate")
        minDurSlider:SetPoint("TOPLEFT", wipesCb, "BOTTOMLEFT", 0, -28)
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
            ResetSession()
            if historyFrame:IsShown() then RefreshHistoryFrame() end
            print("|cffff9900ABCReminder:|r All statistics reset.")
        end)
    end

    RefreshPanelDynamic()
end)

local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
Settings.RegisterAddOnCategory(category)

local function OpenOptions()
    if category:GetID() then Settings.OpenToCategory(category:GetID())
    else Settings.OpenToCategory(panel.name) end
end

-- =========================
-- Slash Commands
-- =========================
SLASH_ABCREMINDER1 = "/ar"
SlashCmdList.ABCREMINDER = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "stats" or msg == "history" then
        ShowHistoryFrame()
    elseif msg == "raid" then
        ShowHistoryFrame("raid")
    elseif msg == "mythic" or msg == "m+" then
        ShowHistoryFrame("mythic")
    elseif msg == "session" then
        UpdateSessionFrame()
    elseif msg == "reset session" then
        ResetSession()
        print("ABC: Session reset.")
    else
        OpenOptions()
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
            info.notCheckable = true
            info.text, info.func = "Open Options", OpenOptions
            UIDropDownMenu_AddButton(info, level)
            info.text, info.func = "History (Raid)",    function() ShowHistoryFrame("raid")   end
            UIDropDownMenu_AddButton(info, level)
            info.text, info.func = "History (Mythic+)", function() ShowHistoryFrame("mythic") end
            UIDropDownMenu_AddButton(info, level)
            info.text, info.func = "Session Stats", function() UpdateSessionFrame() end
            UIDropDownMenu_AddButton(info, level)
            info.text, info.func = "Reset Session Stats", function()
                ResetSession()
                print("ABC: Session statistics reset.")
            end
            UIDropDownMenu_AddButton(info, level)
        end)
        ToggleDropDownMenu(1, nil, menuCompartment, "cursor", 0, 0)
    else
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
