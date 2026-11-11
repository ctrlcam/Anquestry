-- Wraps QuestieDB reads for quest relationships, profession requirements, and map locations.

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

local OBJECTIVE_TYPES = {
    [1] = { label = "Slay", texture = "Interface\\Icons\\INV_Sword_04" },
    [2] = { label = "Collect", texture = "Interface\\Icons\\INV_Misc_Bag_10" },
    [3] = { label = "Event", texture = "Interface\\Icons\\INV_Misc_Map_01" },
    [4] = { label = "Interact", texture = "Interface\\Icons\\Trade_Engineering" },
    [5] = { label = "Talk", texture = "Interface\\GossipFrame\\GossipGossipIcon" },
    [17] = { label = "Interact", texture = "Interface\\Icons\\Trade_Engineering" },
    [19] = { label = "Mount", texture = "Interface\\Icons\\Ability_Mount_RidingHorse" },
}

-- Read Questie's explicit objective icons, with its usual defaults for each group.
function Anquestry.db:ObjectiveTypes(id)
    self.objectiveTypes = self.objectiveTypes or {}
    if self.objectiveTypes[id] then return self.objectiveTypes[id] end
    local types, seen = {}, {}
    local function add(icon)
        local kind = OBJECTIVE_TYPES[icon]
        if kind and not seen[kind.label] then
            seen[kind.label] = true
            types[#types + 1] = { label = kind.label, texture = kind.texture, icon = icon }
        end
    end
    local objectives = self:Get(id, "objectives") or {}
    -- Prefer collection as the row summary when killing is also involved.
    for _, group in ipairs({ 3, 1, 2, 5, 6 }) do
        for _, objective in ipairs(objectives[group] or {}) do
            local icon = objective[group == 5 and 4 or 3]
            if group == 6 then icon = 3 end
            if not icon or icon == 0 then
                icon = group == 1 and 1 or group == 2 and 4 or group == 3 and 2 or 1
            end
            add(icon)
        end
    end
    for _, objective in ipairs(self:Get(id, "extraObjectives") or {}) do add(objective[2]) end
    if self:Get(id, "triggerEnd") then add(3) end
    -- A quest with no objective groups or trigger is a simple NPC turn-in.
    if #types == 0 and not next(objectives) and not self:Get(id, "triggerEnd") then
        local finishers = self:Get(id, "finishedBy")
        if finishers and finishers[1] and #finishers[1] > 0 then add(5) end
    end
    self.objectiveTypes[id] = types
    return types
end

-- Use Questie's configured artwork when available, otherwise use a client icon.
function Anquestry.db:ObjectiveTexture(kind)
    return Questie and Questie.usedIcons and Questie.usedIcons[kind.icon] or kind.texture
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

-- Load the shared area-to-map lookup once for endpoint pins and distances.
function Anquestry.db:AreaMaps()
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
    return self.areaToMap
end

-- Pick a valid spawn, preferring the player's current map when possible.
function Anquestry.db:FindMapPoint(spawns)
    if not spawns then return end
    local areaToMap = self:AreaMaps()
    local current = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local best, bestArea
    for area, points in pairs(spawns) do
        local map = areaToMap[area]
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

-- Cache the shortest known start-to-turn-in distance for each quest variant.
function Anquestry.db:TravelDistance(id)
    if not C_Map or not C_Map.GetWorldPosFromMapPos then return end
    self.travelDistances = self.travelDistances or {}
    if self.travelDistances[id] ~= nil then return self.travelDistances[id] or nil end
    local starts, finishes = {}, {}
    local areaToMap = self:AreaMaps()
    for _, endpoint in ipairs(self:QuestEndpoints(id)) do
        local points = endpoint.starts and starts or finishes
        for area, spawns in pairs(endpoint.spawns or {}) do
            local map = areaToMap[area]
            if map then
                for _, spawn in ipairs(spawns) do
                    local x, y = spawn[1], spawn[2]
                    if x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
                        local continent, position = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(x / 100, y / 100))
                        if continent and position then
                            local worldX, worldY = position:GetXY()
                            points[#points + 1] = { continent = continent, x = worldX, y = worldY }
                        end
                    end
                end
            end
        end
    end
    local nearest
    for _, start in ipairs(starts) do
        for _, finish in ipairs(finishes) do
            if start.continent == finish.continent then
                local dx, dy = finish.x - start.x, finish.y - start.y
                nearest = math.min(nearest or math.huge, dx * dx + dy * dy)
            end
        end
    end
    local result
    if nearest then
        result = { yards = math.sqrt(nearest) }
    elseif #starts > 0 and #finishes > 0 then
        result = { differentContinents = true }
    end
    self.travelDistances[id] = result or false
    return result
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

