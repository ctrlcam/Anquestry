-- Tracks completion and calculates displayed XP, rankings, and remaining totals.

local _, Anquestry = ...
Anquestry.progress = {}

-- Ask WoW whether the character has completed this quest.
function Anquestry.progress:IsComplete(questID)
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then return C_QuestLog.IsQuestFlaggedCompleted(questID) end
    if IsQuestFlaggedCompleted then return IsQuestFlaggedCompleted(questID) end
    return false
end

local XP_BUFFS = { [377749] = 0.5, [46668] = 0.1, [95987] = 0.1, [24705] = 0.1 }

-- Map a reward rank to the flyout's color band.
local function rankGrade(rank)
    return rank >= .98 and "S+" or rank >= .90 and "S" or rank >= .75 and "A"
        or rank >= .55 and "B" or rank >= .35 and "C" or rank >= .15 and "D"
        or rank > .02 and "F" or "F-"
end

-- Rank base XP in the configured level range, with tied rewards sharing a rank.
local function xpGrade(progress, data, record)
    if not record or not record[1] or record[1] <= 0 or not record[2] then return nil end
    if not progress.xpByLevel then
        progress.xpByLevel, progress.grades = {}, {}
        for _, reward in pairs(data) do
            local level, xp = reward[1], reward[2]
            if level and level > 0 and xp and xp >= 0 then
                local bucket = progress.xpByLevel[level] or {}
                bucket[xp] = (bucket[xp] or 0) + 1
                progress.xpByLevel[level] = bucket
            end
        end
    end
    local level, xp = record[1], record[2]
    local grades = progress.grades[level] or {}
    progress.grades[level] = grades
    local result = grades[xp]
    if result then return result.grade, result.percentile, result.rank, result.position, result.count end
    local below, tied, count = 0, 0, 0
    local window = Anquestry:GetXPWindow()
    for peer = level - window, level + window do
        for reward, frequency in pairs(progress.xpByLevel[peer] or {}) do
            count = count + frequency
            if reward < xp then below = below + frequency end
            if reward == xp then tied = tied + frequency end
        end
    end
    result = { count = count }
    if count > 1 then
        result.rank = (below + tied / 2) / count
        result.grade = rankGrade(result.rank)
        result.percentile = 100 * below / (count - 1)
        result.position = count - below - tied + 1
    end
    grades[xp] = result
    return result.grade, result.percentile, result.rank, result.position, result.count
end

-- Read known XP buffs when Forever allows aura access.
local function xpMultiplier()
    if (InCombatLockdown and InCombatLockdown()) or (IsInInstance and IsInInstance()) then return 1 end
    local multiplier = 1
    for index = 1, 40 do
        local spellID
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local aura = C_UnitAuras.GetAuraDataByIndex("player", index, "HELPFUL")
            spellID = aura and aura.spellId
        elseif UnitAura then
            spellID = select(10, UnitAura("player", index, "HELPFUL"))
        end
        if issecretvalue and issecretvalue(spellID) then break end
        if not spellID then break end
        multiplier = multiplier + (XP_BUFFS[spellID] or 0)
    end
    return multiplier
end

-- Apply the Classic level penalty and reward rounding before XP buffs.
local function adjustedXP(record, playerLevel, maxLevel, multiplier)
    if maxLevel and playerLevel >= maxLevel then return 0 end
    if not record then return nil end
    local level, base = record[1], record[2]
    if base == 0 then return 0 end
    if not level or level <= 0 or not base then return nil end
    local scale = math.max(1, math.min(10, 2 * (level - playerLevel) + 20))
    local xp = base * scale / 10
    local step = xp <= 100 and 5 or xp <= 500 and 10 or xp <= 1000 and 25 or 50
    return math.floor(step * math.floor((xp + math.floor(step / 2)) / step) * multiplier)
end

-- Calculate each row's XP and sum the incomplete quests.
function Anquestry.progress:Summary(rows)
    local complete, minLevel, maxLevel, remainingXP, unknownXP = 0, nil, nil, 0, false
    local rankTotal, rankedQuests = 0, 0
    local xp = Anquestry.db.library and Anquestry.db.library.Support and Anquestry.db.library.Support.Get and Anquestry.db.library.Support.Get("QuestXP")
    local playerLevel = UnitLevel("player") or 1
    local playerCap = GetMaxPlayerLevel and GetMaxPlayerLevel()
    local multiplier = xpMultiplier()
    for _, row in ipairs(rows) do
        local level = row.level
        if level and level > 0 then minLevel = not minLevel and level or math.min(minLevel, level); maxLevel = not maxLevel and level or math.max(maxLevel, level) end
        row.done = self:IsComplete(row.id)
        local record = xp and xp.db and xp.db[row.id]
        row.xp = adjustedXP(record, playerLevel, playerCap, multiplier)
        local reward
        if QuestFrame and QuestFrame:IsShown() and GetQuestID and GetQuestID() == row.id and GetRewardXP then
            reward = GetRewardXP()
        elseif HaveQuestData and HaveQuestData(row.id) and GetQuestLogRewardXP then
            reward = GetQuestLogRewardXP(row.id)
        end
        if type(reward) == "number" and (not issecretvalue or not issecretvalue(reward)) and reward > 0 then
            -- Native rewards already include the client's level scaling and modifiers.
            row.xp = reward
        end
        local grade, percentile, rank, position, count = xpGrade(self, xp and xp.db, record)
        row.xpGrade, row.xpPercentile, row.xpPosition = grade, percentile, position
        row.xpBracketCount = count
        if row.done then
            complete = complete + 1
        elseif row.xp then
            remainingXP = remainingXP + row.xp
            if rank then
                rankTotal = rankTotal + rank
                rankedQuests = rankedQuests + 1
            end
        else
            unknownXP = true
        end
    end
    local grade = rankedQuests > 0 and rankGrade(rankTotal / rankedQuests) or nil
    return { complete = complete, total = #rows, minLevel = minLevel, maxLevel = maxLevel, remainingXP = remainingXP, unknownXP = unknownXP, xpGrade = grade }
end
