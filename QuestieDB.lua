local _, Anquestry = ...
Anquestry.db = {}

-- Connect to the installed QuestieDB and check API compatibility.
function Anquestry.db:Initialize()
    local library = _G.LibQuestieDB
    if type(library) ~= "table" or type(library.Quest) ~= "table" then
        return false, "QuestieDB is required but was not loaded."
    end
    if library.RequireContract then
        local ok, message = library.RequireContract(4)
        if not ok then return false, message end
    end
    self.library = library
    self.quest = library.Quest
    return true
end

-- Read learned professions and their skill levels by ID.
function Anquestry.db:PlayerSkills()
    local skills = {}
    if GetProfessions and GetProfessionInfo then
        for _, index in pairs({ GetProfessions() }) do
            local _, _, rank, _, _, _, id = GetProfessionInfo(index)
            if id and rank then skills[id] = rank end
        end
    elseif not (C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo) then
        return nil
    end
    if C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
        for index = 1, C_SkillInfo.GetNumSkillLines() do
            local line = C_SkillInfo.GetSkillLineInfo(index)
            if line and not line.isHeader and line.skillID and line.rank then
                skills[line.skillID] = line.rank
            end
        end
    end
    return skills
end

-- Check profession ownership and any explicit minimum skill level.
function Anquestry.db:MatchesProfession(id, skills)
    if not skills then return true end
    local required = self:Get(id, "requiredSkill")
    if required and required[1] and required[1] > 0 then
        local rank = skills[required[1]]
        if not rank or rank < (required[2] or 0) then return false end
    end
    local ranks = self:Get(id, "requiredRanks")
    if ranks and #ranks > 0 then
        for _, pair in ipairs(ranks) do
            if skills[pair[1]] then return true end
        end
        return false
    end
    return true
end

-- Check whether QuestieDB knows this quest ID.
function Anquestry.db:Exists(id)
    return self.quest and self.quest.Exists and self.quest.Exists(id) or false
end

-- Read one field from the local quest database.
function Anquestry.db:Get(id, key)
    if not self.quest or not id then return nil end
    return self.quest.Get(id, key)
end

-- Read the quest's NPC, object, and item endpoints.
function Anquestry.db:QuestEndpoints(id)
    local endpoints = {}
    local entities = { self.library.Npc, self.library.Object, self.library.Item }
    local labels = { "NPC", "Object", "Item" }
    for _, field in ipairs({ "startedBy", "finishedBy" }) do
        local groups = self:Get(id, field) or {}
        local starts = field == "startedBy"
        for kind = 1, starts and 3 or 2 do
            local entity = entities[kind]
            for _, entryID in ipairs(groups[kind] or {}) do
                local name = entity and entity.name(entryID)
                endpoints[#endpoints + 1] = {
                    starts = starts,
                    name = name or (labels[kind] .. " " .. entryID),
                    spawns = entity and entity.spawns and entity.spawns(entryID),
                }
            end
        end
    end
    return endpoints
end

-- Pick a valid spawn, preferring the player's current map when possible.
function Anquestry.db:FindMapPoint(spawns)
    if not spawns then return end
    if not self.areaToMap then
        local support = self.library.Support
        local zone = support and support.Get("ZoneDB")
        local maps = zone and zone.private
        self.areaToMap = {}
        if maps then
            for _, field in ipairs({ "areaIdToUiMapId", "areaIdToUiMapIdOverride" }) do
                local value = maps[field]
                if type(value) == "string" then
                    for area, map in value:gmatch("%[(%d+)%]%s*=%s*(%d+)") do
                        self.areaToMap[tonumber(area)] = tonumber(map)
                    end
                elseif type(value) == "table" then
                    for area, map in pairs(value) do self.areaToMap[area] = map end
                end
            end
        end
    end
    local current = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local best, bestArea
    for area, points in pairs(spawns) do
        local map = self.areaToMap[area]
        if map and map > 0 then
            for _, point in ipairs(points) do
                local x, y = point[1], point[2]
                if x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
                    if map == current then return { map = map, x = x / 100, y = y / 100 } end
                    if not bestArea or area < bestArea then
                        bestArea, best = area, { map = map, x = x / 100, y = y / 100 }
                    end
                    break
                end
            end
        end
    end
    return best
end

-- Collect prerequisite and follow-up IDs separately.
function Anquestry.db:Relationships(id)
    local before, after = {}, {}
    for _, field in ipairs({ "preQuestGroup", "preQuestSingle" }) do
        for _, target in ipairs(self:Get(id, field) or {}) do
            if target > 0 then before[#before + 1] = target end
        end
    end
    for _, target in ipairs(self:Get(id, "childQuests") or {}) do
        if target > 0 then after[#after + 1] = target end
    end
    local parent = self:Get(id, "parentQuest")
    if parent and parent > 0 then before[#before + 1] = parent end
    local nextQuest = self:Get(id, "nextQuestInChain")
    if nextQuest and nextQuest > 0 then after[#after + 1] = nextQuest end
    return before, after
end

