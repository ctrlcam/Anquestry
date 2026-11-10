-- Builds and saves the quest-chain index and resolves the rows for a selected quest.

local _, Anquestry = ...
Anquestry.resolver = { maxNodes = 80 }

-- Walk one direction without crossing into sibling branches.
local function collect(seeds, edges, ids, included, maxNodes, skip)
    local seen, queue = {}, {}
    for _, id in ipairs(seeds) do
        seen[id] = true
        queue[#queue + 1] = id
    end
    local head = 1
    while queue[head] do
        local id = queue[head]; head = head + 1
        if not included[id] then
            if #ids == maxNodes then return true end
            included[id] = true
            ids[#ids + 1] = id
        end
        for _, target in ipairs(edges[id] or {}) do
            if not seen[target] and (not skip or not skip(target)) then
                seen[target] = true
                queue[#queue + 1] = target
            end
        end
    end
    return false
end

-- Sort the selected quest and its upstream and downstream paths.
local function resolveIDs(selectedID, before, after, levels, breadcrumbs, exclusive, maxNodes)
    local ids, included = { selectedID }, { [selectedID] = true }
    local beforeCapped = collect({ selectedID }, before, ids, included, maxNodes)
    local afterCapped = collect({ selectedID }, after, ids, included, maxNodes)
    local blocked = {}
    for _, id in ipairs(ids) do
        for _, alternative in ipairs(exclusive[id] or {}) do
            if not included[alternative] then blocked[alternative] = true end
        end
    end
    -- Bring in missing prerequisites without importing alternate routes already represented.
    local prerequisitesCapped = collect(ids, before, ids, included, maxNodes, function(id)
        return blocked[id]
    end)
    local function byLevel(a, b)
        local al, bl = levels[a], levels[b]
        if al == bl then return a < b end
        return al < bl
    end
    table.sort(ids, byLevel)
    local ordered, visited, visiting, depths = {}, {}, {}, {}
    local optionalBefore = {}
    for _, id in ipairs(ids) do
        local target = breadcrumbs[id]
        if target and included[target] then
            optionalBefore[target] = optionalBefore[target] or {}
            table.insert(optionalBefore[target], id)
        end
    end
    -- Place included prerequisites before their dependents and break cycles.
    local function place(id, depth)
        if visited[id] or visiting[id] then return end
        visiting[id] = true
        local prior = {}
        for _, parent in ipairs(before[id] or {}) do
            if included[parent] then prior[#prior + 1] = parent end
        end
        for _, parent in ipairs(optionalBefore[id] or {}) do prior[#prior + 1] = parent end
        table.sort(prior, byLevel)
        for _, parent in ipairs(prior) do place(parent, depth) end
        visiting[id] = nil
        visited[id] = true
        depths[id] = depth
        ordered[#ordered + 1] = id
    end
    -- Keep each follow-up path together and indent where paths fork.
    local walked, branches = {}, {}
    local function walk(id, depth, branch)
        if walked[id] then return end
        walked[id] = true
        branches[id] = branch
        place(id, depth)
        local children, seen = {}, {}
        for _, child in ipairs(after[id] or {}) do
            if included[child] and not seen[child] then
                seen[child] = true
                children[#children + 1] = child
            end
        end
        local leadTo = breadcrumbs[id]
        if leadTo and included[leadTo] and not seen[leadTo] then children[#children + 1] = leadTo end
        table.sort(children, byLevel)
        local childDepth = #children > 1 and math.min(depth + 1, 2) or depth
        for _, child in ipairs(children) do
            walk(child, childDepth, #children > 1 and child or branch)
        end
    end
    for _, id in ipairs(ids) do
        local hasParent = optionalBefore[id] ~= nil
        for _, parent in ipairs(before[id] or {}) do
            if included[parent] then
                hasParent = true
                break
            end
        end
        if not hasParent then walk(id, 0) end
    end
    walk(selectedID, 0)
    for _, id in ipairs(ids) do place(id, 0) end
    local relations = {}
    for _, id in ipairs(before[selectedID] or {}) do relations[id] = "<" end
    for _, id in ipairs(after[selectedID] or {}) do relations[id] = ">" end
    return { ids = ordered, depths = depths, branches = branches, relations = relations,
        truncated = beforeCapped or afterCapped or prerequisitesCapped }
end

-- Reuse the saved index if it matches this QuestieDB build.
function Anquestry.resolver:LoadCache()
    local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local name = Anquestry.db.library.addonName or "QuestieDB"
    local version = metadata and metadata(name, "Version")
    local commit = metadata and metadata(name, "X-BUILD-COMMIT")
    local _, class = UnitClass("player")
    local faction = UnitFactionGroup("player")
    local enum = Anquestry.db.library.Enum
    self.classMask = enum and enum.classKeys and enum.classKeys[class]
    local factionMasks = enum and enum.factionRaceMasks
    self.factionMask = factionMasks and factionMasks[faction]
    local otherFaction = faction == "Alliance" and "Horde" or faction == "Horde" and "Alliance"
    self.otherFactionMask = otherFaction and factionMasks and factionMasks[otherFaction]
    self.buildKey = (version or commit) and ("8|" .. (version or "") .. "|" .. (commit or ""))
    self.key = self.buildKey and (self.buildKey .. "|" .. (class or "") .. "|" .. (faction or ""))
    local store = AnquestryChainCache
    local saved = type(store) == "table" and (store[self.key] or store)
    if self.key and type(saved) == "table" and saved.key == self.key and type(saved.chains) == "table" then
        self.chains = saved.chains
    end
end

-- Build the quest index in small batches across frames.
function Anquestry.resolver:Build(onProgress, onDone)
    if self.building then return end
    self.building = true
    local ids = Anquestry.db.quest.GetAllIds()
    local before, after, levels, chains, breadcrumbs, exclusive = {}, {}, {}, {}, {}, {}
    local known = Anquestry.db.quest.GetAllIds(true)
    local eligible = {}
    local band = bit and bit.band
    -- Check each quest's class and faction eligibility once during the build.
    local function matchesCharacter(id)
        if eligible[id] == nil then
            local required = Anquestry.db:Get(id, "requiredClasses")
            local matchesClass = not self.classMask or not band or not required or required == 0
                or band(required, self.classMask) ~= 0
            local races = Anquestry.db:Get(id, "requiredRaces")
            local oppositeOnly = band and races and self.factionMask and self.otherFactionMask
                and band(races, self.factionMask) == 0 and band(races, self.otherFactionMask) ~= 0
            eligible[id] = matchesClass and not oppositeOnly
        end
        return eligible[id]
    end
    -- Record both sides of a link between known quests.
    local function link(previous, nextID)
        if previous == nextID or not known[previous] or not known[nextID] then return end
        if not matchesCharacter(previous) or not matchesCharacter(nextID) then return end
        after[previous] = after[previous] or {}
        before[nextID] = before[nextID] or {}
        table.insert(after[previous], nextID)
        table.insert(before[nextID], previous)
    end
    local processed, total = 0, #ids * 2
    local worker = CreateFrame("Frame")
    onProgress(0, total)
    worker:SetScript("OnUpdate", function()
        local deadline = debugprofilestop and debugprofilestop() + 2
        for _ = 1, 100 do
            if processed == total then break end
            processed = processed + 1
            if processed <= #ids then
                local id = ids[processed]
                local prerequisites, followups = Anquestry.db:Relationships(id)
                levels[id] = Anquestry.db:Get(id, "questLevel") or 0
                breadcrumbs[id] = Anquestry.db:Get(id, "breadcrumbForQuestId")
                exclusive[id] = Anquestry.db:Get(id, "exclusiveTo")
                for _, target in ipairs(prerequisites) do link(target, id) end
                for _, target in ipairs(followups) do link(id, target) end
            else
                local id = ids[processed - #ids]
                if matchesCharacter(id) then
                    chains[id] = resolveIDs(id, before, after, levels, breadcrumbs, exclusive, self.maxNodes)
                end
            end
            if deadline and debugprofilestop() >= deadline then break end
        end
        onProgress(processed, total)
        if processed == total then
            worker:SetScript("OnUpdate", nil)
            self.building = false
            self.chains = chains
            if self.key then
                local saved = AnquestryChainCache
                if type(saved) ~= "table" or saved.build ~= self.buildKey then
                    saved = { build = self.buildKey }
                    AnquestryChainCache = saved
                end
                saved[self.key] = { key = self.key, chains = chains }
            end
            onDone()
        end
    end)
end

-- Look up a saved chain and fill in its titles and levels.
function Anquestry.resolver:Resolve(selectedID)
    local chain = self.chains and self.chains[selectedID]
    if not chain then return {} end
    local rows = {}
    local skills = Anquestry.db:PlayerSkills()
    local groups = {}
    -- Prefer the selected, active, or completed variant as the visible row.
    local function priority(id)
        if id == selectedID then return 3 end
        local index = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
        if index and index > 0 then return 2 end
        return Anquestry.progress:IsComplete(id) and 1 or 0
    end
    for _, id in ipairs(chain.ids) do
        if id == selectedID or Anquestry.db:MatchesProfession(id, skills) then
            local title = Anquestry.db:Get(id, "name") or ("Quest " .. id)
            local row = { id = id, title = title, level = Anquestry.db:Get(id, "questLevel"), relation = chain.relations[id], depth = chain.depths[id], branch = chain.branches[id] }
            local key, alternatives
            local exclusive = Anquestry.db:Get(id, "exclusiveTo")
            local objective = Anquestry.db:Get(id, "objectivesText")
            if title:match("^Camping 101: ") then
                local prerequisites = Anquestry.db:Get(id, "preQuestSingle")
                if prerequisites and #prerequisites > 0 then
                    key = title .. "|" .. table.concat(prerequisites, ",")
                end
            elseif exclusive and #exclusive > 0 and objective and #objective > 0 then
                local variants = { id }
                for _, other in ipairs(exclusive) do variants[#variants + 1] = other end
                table.sort(variants)
                key = "exclusive|" .. title .. "|" .. tostring(row.level) .. "|"
                    .. table.concat(variants, ",") .. "|" .. table.concat(objective, "\n")
                alternatives = true
            end
            local group = key and groups[key]
            if group then
                group.ids[#group.ids + 1] = id
                if priority(id) > priority(rows[group.index].id) then rows[group.index] = row end
                local representative = rows[group.index]
                representative.locations = #group.ids
                representative.alternatives = alternatives
                representative.variants = group.ids
            else
                rows[#rows + 1] = row
                if key then groups[key] = { index = #rows, ids = { id } } end
            end
        end
    end
    return rows, chain.truncated
end
