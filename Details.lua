-- Provides the searchable quest browser and on-demand parchment reward preview.

local addonName, Anquestry = ...
local details = { page = 1, statuses = {}, selectedZones = {}, requests = {} }
Anquestry.details = details
local WINDOW_WIDTH, WINDOW_HEIGHT = 620, 500
local SIDEBAR_WIDTH, PAGE_SIZE, TEXT_INSET = 234, 15, 14
local PANE_WIDTH = WINDOW_WIDTH - SIDEBAR_WIDTH - 20
local CONTENT_WIDTH = PANE_WIDTH - 40
local INFO_HEIGHT = 26
local LINK_HEIGHT = 28
local FILTERS = { { "all", "All quests" }, { "incomplete", "Incomplete" },
    { "completed", "Completed" }, { "active", "Active" } }

-- Read an optional client value without passing protected values into the preview.
local function readAPI(getter, ...)
    if not getter then return end
    local ok, value = pcall(getter, ...)
    if ok and (not issecretvalue or not issecretvalue(value)) then return value end
end

-- Add a classic red button with a fixed label and click action.
local function button(parent, label, width, onClick)
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetSize(width, 24)
    control:SetText(label)
    control:SetScript("OnClick", onClick)
    return control
end

-- Share the map's drawing stratum; normal top-level focus controls which window is in front.
function details:SyncMapLayer()
    local strata = WorldMapFrame and WorldMapFrame:GetFrameStrata() or "HIGH"
    if self.frame:GetFrameStrata() ~= strata then self.frame:SetFrameStrata(strata) end
end

-- Coalesce client updates without resetting the reader's scroll position.
function details:ScheduleRefresh()
    if self.refreshPending or not self.frame or not self.frame:IsShown() then return end
    self.refreshPending = true
    C_Timer.After(0, function()
        self.refreshPending = false
        if self.frame:IsShown() then
            self:Render()
            if self.searchDirty then
                self.searchDirty = false
                self:Search()
            else
                self:UpdateList()
            end
        end
    end)
end

-- Basic quest data and item rewards do not necessarily arrive together.
local function rewardDataReady(id)
    return readAPI(HaveQuestRewardData, id) == true
        or (readAPI(GetNumQuestLogChoices, id) or 0) > 0
        or (readAPI(GetNumQuestLogRewards, id) or 0) > 0
end

-- Request only the inspected quest and wait separately for its reward data.
function details:RequestData(id)
    if not C_QuestLog or not C_QuestLog.RequestLoadQuestByID then return end
    local previous = self.requests[id]
    if previous and (previous.state == "pending"
        or (previous.state == "loaded" and rewardDataReady(id))
        or (previous.state == "failed" and GetTime() < previous.retryAt)) then return end
    local request = { state = "pending", basicState = "pending", rewardState = "pending" }
    self.requests[id] = request
    local ok = pcall(C_QuestLog.RequestLoadQuestByID, id)
    if not ok then
        request.basicState = "failed"
    end
    if not rewardDataReady(id) and C_TaskQuest and C_TaskQuest.RequestPreloadRewardData then
        pcall(C_TaskQuest.RequestPreloadRewardData, id)
    end
    local attempts = 0
    local function checkRewards()
        if self.requests[id] ~= request or request.state ~= "pending" then return end
        if self.questID ~= id or not self.frame:IsShown() then
            request.state = "cancelled"
            request.rewardState = "cancelled"
            return
        end
        if rewardDataReady(id) then
            request.state, request.rewardState = "loaded", "ready"
            self:ScheduleRefresh()
            return
        end
        if attempts >= 10 then
            request.state, request.rewardState, request.retryAt = "failed", "unavailable", GetTime() + 5
            self:ScheduleRefresh()
            return
        end
        attempts = attempts + 1
        C_Timer.After(0.5, checkRewards)
    end
    checkRewards()
end

-- Cache searchable titles and levels locally without requesting server data.
function details:BuildCatalog()
    if self.catalog then return end
    self.catalog, self.zones = {}, {}
    local seenZones, zoneNames = {}, {}
    for _, id in ipairs(Anquestry.db.quest.GetAllIds()) do
        local title = Anquestry.db:Get(id, "name") or ("Quest " .. id)
        local zone = Anquestry.db:Get(id, "zoneOrSort") or 0
        if zone <= 0 then zone = 0 end
        if seenZones[zone] == nil then
            local name = zone == 0 and "No zone"
                or readAPI(C_Map and C_Map.GetAreaInfo, zone) or ("Zone " .. zone)
            local canonical = zoneNames[name]
            if canonical == nil then
                canonical = zone
                zoneNames[name] = canonical
                self.zones[#self.zones + 1] = { id = canonical, name = name }
            end
            seenZones[zone] = canonical
        end
        zone = seenZones[zone]
        self.catalog[#self.catalog + 1] = {
            id = id, title = title, search = title:lower(), level = Anquestry.db:Get(id, "questLevel") or 0,
            zone = zone,
        }
    end
    table.sort(self.catalog, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        if a.title ~= b.title then return a.title < b.title end
        return a.id < b.id
    end)
    table.sort(self.zones, function(a, b) return a.name < b.name end)
end

-- Filter the flat catalog by name or ID, completion, and active quests.
function details:Search()
    local query = self.frame.search:GetText():lower():match("^%s*(.-)%s*$")
    self.matches = {}
    for _, entry in ipairs(self.catalog) do
        local matches = query == "" or entry.search:find(query, 1, true) or tostring(entry.id) == query
        if matches and self.minLevel then matches = entry.level >= self.minLevel end
        if matches and self.maxLevel then matches = entry.level <= self.maxLevel end
        if matches and next(self.selectedZones) then matches = self.selectedZones[entry.zone] end
        if matches and next(self.statuses) then
            local done = Anquestry.progress:IsComplete(entry.id)
            local index = C_QuestLog and C_QuestLog.GetLogIndexForQuestID(entry.id)
            matches = (self.statuses.incomplete and not done) or (self.statuses.completed and done)
                or (self.statuses.active and index and index > 0)
        end
        if matches then self.matches[#self.matches + 1] = entry end
    end
    self:UpdateList()
end

-- Show one page of difficulty-colored rows and strike completed quests.
function details:UpdateList()
    local matches = self.matches or {}
    local pageSize = self.pageSize or PAGE_SIZE
    local pages = math.max(1, math.ceil(#matches / pageSize))
    self.page = math.max(1, math.min(self.page, pages))
    for index, row in ipairs(self.frame.rows) do
        local entry = index <= pageSize and matches[(self.page - 1) * pageSize + index] or nil
        row:SetShown(entry ~= nil)
        if entry then
            row.questID = entry.id
            row.text:SetText(("[%d] %s"):format(entry.level, entry.title))
            local done = Anquestry.progress:IsComplete(entry.id)
            local r, g, b = Anquestry.ui:QuestColor(entry.level, entry.id)
            if done then r, g, b = 0.53, 0.53, 0.53 end
            row.text:SetTextColor(r, g, b)
            row.strike:SetShown(done)
            row.strike:SetWidth(math.max(1, math.min(row.text:GetStringWidth(), row.text:GetWidth())))
            row.selected:SetShown(entry.id == self.questID)
        end
    end
    self.frame.pageText:SetText(("%d / %d"):format(self.page, pages))
    self.frame.previous:SetEnabled(self.page > 1)
    self.frame.next:SetEnabled(self.page < pages)
end

-- Reuse a parchment text line and advance the detail cursor by its wrapped height.
function details:AddText(text, font, r, g, b)
    self.textCount = self.textCount + 1
    local label = self.texts[self.textCount]
    if not label then
        label = self.frame.content:CreateFontString(nil, "OVERLAY")
        self.texts[self.textCount] = label
    end
    label:SetFontObject(font or "QuestFont")
    label:SetParent(self.renderParent or self.frame.content)
    label:SetTextColor(r or (self.inRewards and 0.90 or 0.16),
        g or (self.inRewards and 0.79 or 0.1), b or (self.inRewards and 0.67 or 0.04))
    label:ClearAllPoints()
    label:SetPoint("TOPLEFT", TEXT_INSET, -self.cursor)
    label:SetWidth(CONTENT_WIDTH)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    label:Show()
    self.cursor = self.cursor + label:GetStringHeight() + 4
end

-- Use plain quest-log headings without interactive collapse controls.
function details:AddSection(key, title)
    local header = self.sections[key]
    if not header then
        header = CreateFrame("Frame", nil, self.frame.content)
        header:SetSize(PANE_WIDTH, key == "rewards" and 34 or 28)
        header.text = header:CreateFontString(nil, "OVERLAY",
            key == "rewards" and "QuestFont_Large" or "QuestTitleFont")
        local nativeHeader = key == "objectives" and QuestInfoObjectivesHeader
            or key == "description" and QuestInfoDescriptionHeader
        if nativeHeader then header.text:SetFont(nativeHeader:GetFont()) end
        if key == "rewards" then
            header.text:SetPoint("CENTER")
            header.text:SetJustifyH("CENTER")
        else
            header.text:SetPoint("LEFT", TEXT_INSET, 0)
        end
        header.text:SetJustifyV("MIDDLE")
        header.text:SetTextColor(key == "rewards" and 0.90 or 0.16,
            key == "rewards" and 0.79 or 0.1, key == "rewards" and 0.67 or 0.04)
        self.sections[key] = header
    end
    header:ClearAllPoints()
    header:SetParent(key == "rewards" and self.frame.rewards or self.renderParent or self.frame.content)
    header:SetPoint("TOPLEFT", 0, -self.cursor)
    header.text:SetText(title)
    header:Show()
    self.cursor = self.cursor + (key == "rewards" and 34 or 30)
    return true
end

-- Place a reusable start or turn-in NPC link in the main details.
function details:AddEndpoint(endpoint, count)
    self.endpointCount = self.endpointCount + 1
    local control = self.endpointButtons[self.endpointCount]
    if not control then
        control = CreateFrame("Button", nil, self.frame.infoHeader)
        control:SetHeight(18)
        control.icon = control:CreateTexture(nil, "ARTWORK")
        control.icon:SetSize(13, 13)
        control.icon:SetPoint("LEFT", 0, 0)
        control.text = control:CreateFontString(nil, "OVERLAY", "QuestFont")
        control.text:SetPoint("LEFT", 19, 0)
        control.text:SetPoint("RIGHT")
        control.text:SetJustifyH("LEFT")
        control.text:SetMaxLines(1)
        control:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
        control:SetScript("OnClick", function(clicked)
            if clicked.point then Anquestry.ui:ShowEndpointOnMap(clicked.point) end
        end)
        self.endpointButtons[self.endpointCount] = control
    end
    control:ClearAllPoints()
    local width = (self.frame.infoHeader:GetWidth() - 24) / count
    control:SetPoint("TOPLEFT", 12 + (self.endpointCount - 1) * width, -4)
    local cellWidth = width - (self.endpointCount < count and 6 or 0)
    control:SetWidth(cellWidth)
    control.point = Anquestry.db:FindMapPoint(endpoint.spawns)
    control:EnableMouse(control.point ~= nil)
    control.icon:SetTexture(endpoint.starts and "Interface\\GossipFrame\\AvailableQuestIcon"
        or "Interface\\GossipFrame\\ActiveQuestIcon")
    control.text:SetText(endpoint.name)
    Anquestry.ui:AlignEndpoint(control, control.text, endpoint.starts, cellWidth)
    control.text:SetTextColor(0.16, 0.1, 0.04)
    control:Show()
end

-- Inspect only the selected quest's required items; item metadata is client-cached.
function details:AddRequiredItems(id)
    local objectives = Anquestry.db:Get(id, "objectives") or {}
    local counts = {}
    local live = readAPI(C_QuestLog and C_QuestLog.GetQuestObjectives, id) or {}
    for _, objective in ipairs(live) do
        if objective.type == "item" and objective.objectID then
            counts[objective.objectID] = objective.numRequired
        end
    end
    local seen, used = {}, 0
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    self.requiredItems = self.requiredItems or {}
    self.itemLoads = self.itemLoads or {}
    for _, objective in ipairs(objectives[3] or {}) do
        local itemID = objective[1]
        if type(itemID) == "number" and itemID > 0 and not seen[itemID] then
            seen[itemID] = true
            self.requiredItemIDs[itemID] = true
            local info = getInfo and { getInfo(itemID) } or {}
            if not info[1] and not self.itemLoads[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
                self.itemLoads[itemID] = true
                C_Item.RequestLoadItemDataByID(itemID)
            end
            used = used + 1
            local control = self.requiredItems[used]
            if not control then
                control = CreateFrame("Button", nil, self.frame.content)
                control:SetSize(CONTENT_WIDTH, 30)
                control.icon = control:CreateTexture(nil, "ARTWORK")
                control.icon:SetSize(26, 26)
                control.icon:SetPoint("LEFT")
                control.name = control:CreateFontString(nil, "OVERLAY", "QuestFont")
                control.name:SetPoint("LEFT", 32, 0)
                control.name:SetPoint("RIGHT", -18, 0)
                control.name:SetJustifyH("LEFT")
                control.name:SetMaxLines(1)
                control.name:SetTextColor(0.16, 0.1, 0.04)
                control.count = control:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
                control.count:SetPoint("BOTTOMRIGHT", control.icon, "BOTTOMRIGHT", -1, 1)
                control.buyable = CreateFrame("Frame", nil, control)
                control.buyable:SetSize(12, 26)
                control.buyable:SetPoint("RIGHT", control.icon, "LEFT", -1, 0)
                local dollar = control.buyable:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                dollar:SetAllPoints()
                dollar:SetJustifyH("CENTER")
                dollar:SetJustifyV("MIDDLE")
                dollar:SetText("$")
                dollar:SetTextColor(1, 0.82, 0)
                control.buyable:SetScript("OnEnter", function(owner)
                    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
                    GameTooltip:AddLine("Tradable", 1, 1, 1)
                    GameTooltip:Show()
                end)
                control.buyable:SetScript("OnLeave", function() GameTooltip:Hide() end)
                control.buyable:EnableMouse(true)
                control:SetScript("OnEnter", function(owner)
                    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR_RIGHT")
                    GameTooltip:SetItemByID(owner.itemID)
                    GameTooltip:Show()
                end)
                control:SetScript("OnLeave", function(owner)
                    if GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
                end)
                self.requiredItems[used] = control
            end
            control.itemID = itemID
            control:ClearAllPoints()
            control:SetPoint("TOPLEFT", TEXT_INSET, -self.cursor)
            control.icon:SetTexture(info[10] or 134400)
            control.name:SetText(info[1] or Anquestry.db.library.Item.name(itemID) or ("Item " .. itemID))
            control.count:SetText(counts[itemID] and tostring(counts[itemID]) or "")
            local binding = info[14]
            control.buyable:SetShown(info[1] ~= nil and (binding == 0 or binding == 2 or binding == 3))
            control:Show()
            self.cursor = self.cursor + 32
        end
    end
end

-- Draw native-style quest reward cards in two columns, with item tooltips.
function details:AddItems(items)
    local startY = self.cursor
    local rowsBefore = self.itemRows
    local width = (CONTENT_WIDTH - 12) / 2
    for index, item in ipairs(items) do
        self.itemCount = self.itemCount + 1
        local card = self.itemButtons[self.itemCount]
        if not card then
            card = CreateFrame("Button", nil, self.frame.content)
            card:SetSize(width, 46)
            local background = card:CreateTexture(nil, "BACKGROUND")
            background:SetPoint("TOPLEFT", 28, 9)
            background:SetPoint("BOTTOMRIGHT", 0, -9)
            background:SetTexture("Interface\\QuestFrame\\UI-QuestItemNameFrame")
            card.icon = card:CreateTexture(nil, "ARTWORK")
            card.icon:SetPoint("LEFT", 1, 0)
            card.icon:SetSize(36, 36)
            local border = card:CreateTexture(nil, "OVERLAY")
            border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
            border:SetSize(62, 62)
            border:SetPoint("CENTER", card.icon, "CENTER")
            card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            card.name:SetPoint("LEFT", 43, 0)
            card.name:SetSize(width - 55, 34)
            card.name:SetJustifyH("LEFT")
            card.name:SetWordWrap(true)
            card.name:SetNonSpaceWrap(true)
            card.name:SetMaxLines(2)
            card.count = card:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
            card.count:SetPoint("BOTTOMRIGHT", card.icon, "BOTTOMRIGHT", -1, 1)
            card:SetScript("OnEnter", function(owner)
                GameTooltip:SetOwner(owner, "ANCHOR_CURSOR_RIGHT")
                GameTooltip:SetItemByID(owner.itemID)
                GameTooltip:Show()
            end)
            card:SetScript("OnLeave", function(owner)
                if GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
            end)
            self.itemButtons[self.itemCount] = card
        end
        card:ClearAllPoints()
        card:SetParent(self.renderParent or self.frame.content)
        card:SetPoint("TOPLEFT", TEXT_INSET + ((index - 1) % 2) * (width + 12), -startY - math.floor((index - 1) / 2) * 52)
        card.itemID = item.id
        card.icon:SetTexture(item.texture or 134400)
        card.name:SetText(item.name or ("Item " .. item.id))
        local r, g, b = GetItemQualityColor(item.quality or 1)
        card.name:SetTextColor(r, g, b)
        card.count:SetText(item.count and item.count > 1 and tostring(item.count) or "")
        card:Show()
        self.rewardItemIDs[item.id] = true
    end
    self.itemRows = self.itemRows + math.ceil(#items / 2)
    if not self.twoRowHeight and self.itemRows >= 2 then
        self.twoRowHeight = startY + (2 - rowsBefore) * 52 + 14
    end
    self.cursor = startY + math.ceil(#items / 2) * 52 + 6
end

-- Read reward choices separately from guaranteed items for an arbitrary quest ID.
local function rewardItems(id, countAPI, infoAPI)
    local result = {}
    local count = readAPI(countAPI, id)
    if type(count) ~= "number" or not infoAPI then return result end
    for index = 1, count do
        local ok, name, texture, quantity, quality, _, itemID = pcall(infoAPI, index, id)
        if ok and type(itemID) == "number" and itemID > 0 then
            result[#result + 1] = { id = itemID, name = name, texture = texture, count = quantity, quality = quality }
        end
    end
    return result
end

-- Fill the right pane without selecting, accepting, or completing the quest.
-- Keep the browser's tree selection independent of the map and compact flyout.
function details:UpdateTree()
    local view = self.treeView
    if not view then return end
    local chain, contextChanged = view:ResolveTree(self.questID)
    if contextChanged then
        view.frame.scroll:SetVerticalScroll(0)
    end
    view:RenderFlyout(chain, self.questID)
    local scroll = view.frame.scroll
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), scroll:GetVerticalScrollRange()))
end

function details:Render()
    local id = self.questID
    if not id then return end
    self:UpdateTree()
    local oldScroll = self.frame.scroll:GetVerticalScroll()
    for _, label in ipairs(self.texts) do label:Hide() end
    for _, control in ipairs(self.endpointButtons) do control:Hide() end
    for _, card in ipairs(self.itemButtons) do card:Hide() end
    for _, item in ipairs(self.requiredItems or {}) do item:Hide() end
    for _, header in pairs(self.sections) do header:Hide() end
    self.frame.rewardsBackground:Hide()
    self.frame.rewardsHeader:Hide()
    Anquestry.ui.SyncQuestLogArt(self.frame.sidebar)
    self.frame.rewardXP:Hide()
    self.frame.rewardRank:Hide()
    self.frame.rewardGold:Hide()
    self.textCount, self.endpointCount, self.itemCount, self.cursor = 0, 0, 0, 8
    self.inRewards = false
    self.renderParent = self.frame.titleFrame
    self.itemRows, self.twoRowHeight = 0, nil
    self.rewardItemIDs = {}
    self.requiredItemIDs = {}
    local level = Anquestry.db:Get(id, "questLevel") or 0
    self:AddText(Anquestry.db:Get(id, "name") or ("Quest " .. id), "QuestTitleFont", 0.94, 0.83, 0.65)
    self.frame.levelLabel:SetText(("Lvl %d"):format(level))
    self.frame.levelLabel:SetTextColor(Anquestry.ui:QuestColor(level, id))
    local title = self.texts[self.textCount]
    title:SetWidth(math.max(140, PANE_WIDTH - TEXT_INSET * 2 - self.frame.levelLabel:GetStringWidth() - 10))
    local titleHeight = math.max(36, title:GetStringHeight() + 14)
    self.frame.titleBackground:SetSize(PANE_WIDTH, titleHeight)
    self.frame.titleFrame:SetHeight(titleHeight)
    title:ClearAllPoints()
    title:SetPoint("LEFT", self.frame.titleBackground, "LEFT", TEXT_INSET, 4)
    title:SetJustifyV("MIDDLE")
    self.cursor = 0
    self.renderParent = self.frame.content
    local url = "wowhead.com/forever/quest=" .. id
    if self.frame.url.copyURL ~= url then
        self.frame.url:ClearFocus()
        self.frame.url.copyURL = url
        self.frame.url:SetText(url)
        self.frame.url:SetCursorPosition(#url)
    end
    local endpoints = Anquestry.db:QuestEndpoints(id)
    local infoHeight = #endpoints > 0 and INFO_HEIGHT or 1
    self.frame.infoHeader:SetHeight(infoHeight)
    for _, endpoint in ipairs(endpoints) do self:AddEndpoint(endpoint, #endpoints) end
    local description, objectives
    local logIndex = C_QuestLog and C_QuestLog.GetLogIndexForQuestID(id)
    if logIndex and logIndex > 0 and GetQuestLogQuestText then
        local ok, desc, obj = pcall(GetQuestLogQuestText, logIndex)
        if ok then description, objectives = desc, obj end
    elseif QuestFrame and QuestFrame:IsVisible() and GetQuestID and GetQuestID() == id then
        description = readAPI(GetQuestText)
        objectives = readAPI(GetObjectiveText)
    end
    if type(objectives) ~= "string" or objectives == "" then
        objectives = table.concat(Anquestry.db:Get(id, "objectivesText") or {}, "\n")
    end
    if objectives:match("%S") then
        if self:AddSection("objectives", "Objectives") then self:AddText(objectives) end
        self.cursor = self.cursor + 2
    end
    self:AddRequiredItems(id)
    local hasDescription = type(description) == "string" and description:match("%S")
    if hasDescription then
        if self:AddSection("description", "Description") then self:AddText(description) end
        self.cursor = self.cursor + 4
    end
    local textHeight = self.cursor + 8
    local choices = rewardItems(id, GetNumQuestLogChoices, GetQuestLogChoiceInfo)
    local fixed = rewardItems(id, GetNumQuestLogRewards, GetQuestLogRewardInfo)
    local rows = { { id = id, level = level } }
    Anquestry.progress:Summary(rows)
    local row = rows[1]
    local money = readAPI(GetQuestLogRewardMoney, id)
    local request = self.requests[id]
    local loading = request and request.state == "pending" and not readAPI(HaveQuestRewardData, id)
    local hasItems = #choices > 0 or #fixed > 0
    local unknownItems = not hasItems and not loading and Anquestry.db:HasUnmetRequirements(id) == true
    local hasRewards = (row.xp and row.xp > 0) or (type(money) == "number" and money > 0)
        or hasItems or loading or unknownItems
    self.renderParent = self.frame.rewardsContent
    self.cursor = 0
    if hasRewards then
        self.frame.rewardsHeader:ClearAllPoints()
        self.frame.rewardsHeader:SetPoint("TOPLEFT")
        self.frame.rewardsHeader:SetSize(PANE_WIDTH, 34)
        self.frame.rewardsHeader:Show()
        self.frame.rewardsBackground:ClearAllPoints()
        self.frame.rewardsBackground:SetPoint("TOPLEFT")
        self.frame.rewardsBackground:Show()
    end
    local showRewards = hasRewards and self:AddSection("rewards", "Rewards")
    self.cursor = 0
    self.inRewards = true
    if showRewards then
        if row.xp and row.xp > 0 then
            self.frame.rewardXP:SetText(("%d XP"):format(row.xp))
            local rank = Anquestry.progress:FormatRank(row)
            if rank then
                self.frame.rewardRank:SetText(rank)
                self.frame.rewardRank:Show()
            end
            self.frame.rewardXP:Show()
        end
        if type(money) == "number" and money > 0 then
            self.frame.rewardGold:SetText(GetMoneyString(money, true))
            self.frame.rewardGold:Show()
        end
        if #choices > 0 then
            self:AddText("Choose one reward", "QuestFontNormalSmall")
            self:AddItems(choices)
        end
        if #fixed > 0 then
            self:AddText(#choices > 0 and "You will also receive" or "You will receive", "QuestFontNormalSmall")
            self:AddItems(fixed)
        end
        if unknownItems then self:AddText("Item rewards unknown.", "QuestFontNormalSmall") end
    end
    local available = self.frame.pane:GetHeight() - LINK_HEIGHT - infoHeight - titleHeight
    local bodyHeight = self.cursor + (hasItems and 8 or 0)
    local rewardsHeight = hasRewards and 62 + bodyHeight or 0
    self.frame.rewardsBackground:SetShown(hasItems or unknownItems)
    self.frame.rewardFooterLine:SetShown(hasItems or unknownItems)
    local dockHeight = math.min(rewardsHeight, 62 + (self.twoRowHeight or bodyHeight), math.max(62, available - 90))
    self.frame.rewards:SetHeight(math.max(1, dockHeight))
    self.frame.rewards:SetShown(hasRewards and true or false)
    self.frame.scroll:ClearAllPoints()
    self.frame.scroll:SetPoint("TOPLEFT", self.frame.infoHeader, "BOTTOMLEFT", 0, 0)
    self.frame.scroll:SetPoint("BOTTOMRIGHT", self.frame.pane, "BOTTOMRIGHT", 0, dockHeight)
    self.frame.scroll.ScrollBar:ClearAllPoints()
    self.frame.scroll.ScrollBar:SetPoint("TOPRIGHT", self.frame.pane, "TOPRIGHT", -5, -LINK_HEIGHT - titleHeight - infoHeight - 18)
    self.frame.scroll.ScrollBar:SetPoint("BOTTOMRIGHT", self.frame.pane, "BOTTOMRIGHT", -5, 20 + dockHeight)
    self.frame.rewardsBackground:SetSize(PANE_WIDTH, math.max(1, bodyHeight))
    self.frame.rewardsContent:SetHeight(math.max(1, bodyHeight))
    self.frame.rewardsScroll:UpdateScrollChildRect()
    self.frame.rewardsScroll:SetVerticalScroll(math.min(self.frame.rewardsScroll:GetVerticalScroll(),
        self.frame.rewardsScroll:GetVerticalScrollRange()))
    self.frame.content:SetHeight(textHeight)
    self.frame.scroll:UpdateScrollChildRect()
    self.frame.scroll:SetVerticalScroll(math.min(oldScroll, self.frame.scroll:GetVerticalScrollRange()))
    self.frame.scroll.ScrollBar:SetShown(textHeight > available - dockHeight + 1)
    self.frame.rewardsScroll.ScrollBar:SetShown(bodyHeight > dockHeight - 62 + 1)
end

-- Build a native framed window with a flat list and scrollable parchment details.
function details:Initialize()
    if self.frame then return end
    local frame = CreateFrame("Frame", "AnquestryDetailsFrame", UIParent, "PortraitFrameTemplate")
    self.frame = frame
    frame:Hide()
    frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetClampedToScreen(true)
    frame:SetToplevel(true)
    self:SyncMapLayer()
    if WorldMapFrame then
        WorldMapFrame:HookScript("OnShow", function() self:SyncMapLayer() end)
    end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetTitle("Anquestry")
    local portrait = frame:GetPortrait()
    frame:SetPortraitTextureRaw("Interface\\AddOns\\" .. addonName .. "\\icons\\anquestry_128.png")
    portrait:SetVertexColor(1, 1, 1)
    portrait:SetDrawLayer("ARTWORK", 1)
    -- Keep the native portrait visible; expand its UVs to shrink and offset the icon inside the rim.
    portrait:SetTexCoord(-0.157, 1.203, -0.112, 1.248)
    local backing = portrait:GetParent():CreateTexture(nil, "BACKGROUND", nil, -1)
    backing:SetAllPoints(portrait)
    backing:SetColorTexture(0.12, 0.08, 0.04, 1)
    for index = 1, portrait:GetNumMaskTextures() do
        backing:AddMaskTexture(portrait:GetMaskTexture(index))
    end
    local drag = CreateFrame("Frame", nil, frame)
    drag:SetPoint("TOPLEFT", 70, -3)
    drag:SetPoint("TOPRIGHT", -35, -3)
    drag:SetHeight(28)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() frame:StartMoving() end)
    drag:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    tinsert(UISpecialFrames, frame:GetName())
    local sidebar = CreateFrame("Frame", nil, frame)
    frame.sidebar = sidebar
    sidebar:SetPoint("TOPLEFT", 8, -94)
    sidebar:SetPoint("BOTTOMLEFT", 8, 8)
    sidebar:SetWidth(SIDEBAR_WIDTH)
    local listBackground = sidebar:CreateTexture(nil, "BACKGROUND")
    listBackground:SetAllPoints()
    listBackground:SetColorTexture(0.09, 0.075, 0.06, 1)
    sidebar.questLogArt = sidebar:CreateTexture(nil, "BACKGROUND", nil, 1)
    sidebar.questLogArt:SetAllPoints()
    sidebar.questLogArt:Hide()
    sidebar:EnableMouseWheel(true)
    sidebar:SetScript("OnMouseWheel", function(_, delta)
        if delta == 0 then return end
        self.page = self.page + (delta < 0 and 1 or -1)
        self:UpdateList()
    end)
    frame.search = CreateFrame("EditBox", "AnquestryDetailsSearch", frame, "SearchBoxTemplate")
    frame.search:SetSize(WINDOW_WIDTH - 28, 22)
    frame.search:SetPoint("TOPLEFT", 14, -65)
    frame.search:SetAutoFocus(false)
    frame.search:SetScript("OnTextChanged", function(field)
        SearchBoxTemplate_OnTextChanged(field)
        self.page = 1
        if self.catalog then self:Search() end
    end)
    frame.search:SetScript("OnEscapePressed", function(field) field:ClearFocus() end)
    local filter = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
    frame.statusFilter = filter
    filter:SetPoint("TOPLEFT", 66, -33)
    filter:SetWidth(132)
    filter:SetDefaultText("All quests")
    filter:SetupMenu(function(_, root)
        for _, option in ipairs(FILTERS) do
            local key, label = option[1], option[2]
            root:CreateCheckbox(label, function()
                return key == "all" and not next(self.statuses) or self.statuses[key]
            end, function()
                if key == "all" then self.statuses = {}
                else self.statuses[key] = not self.statuses[key] or nil end
                self.page = 1
                self:Search()
            end)
        end
    end)
    local zoneFilter = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
    frame.zoneFilter = zoneFilter
    zoneFilter:SetPoint("TOPLEFT", 206, -33)
    zoneFilter:SetWidth(270)
    zoneFilter:SetDefaultText("All zones")
    zoneFilter:SetupMenu(function(_, root)
        root:SetScrollMode(240)
        root:CreateCheckbox("All zones", function() return not next(self.selectedZones) end, function()
            self.selectedZones, self.page = {}, 1
            self:Search()
        end)
        for _, zone in ipairs(self.zones or {}) do
            local id, name = zone.id, zone.name
            root:CreateCheckbox(name, function() return self.selectedZones[id] end, function()
                self.selectedZones[id] = not self.selectedZones[id] or nil
                self.page = 1
                self:Search()
            end)
        end
    end)
    local levelCaption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    levelCaption:SetText("Level:")
    levelCaption:SetJustifyH("RIGHT")
    local levelSeparator = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    levelSeparator:SetPoint("CENTER", frame, "TOPLEFT", 570, -44)
    levelSeparator:SetWidth(6)
    levelSeparator:SetJustifyH("CENTER")
    levelSeparator:SetText("-")
    for _, key in ipairs({ "minLevel", "maxLevel" }) do
        local input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
        frame[key] = input
        input:SetSize(24, 22)
        if key == "minLevel" then
            input:SetPoint("RIGHT", levelSeparator, "LEFT", -3, 0)
        else
            -- InputBoxTemplate's left border extends five pixels beyond the edit box.
            input:SetPoint("LEFT", levelSeparator, "RIGHT", 8, 0)
        end
        input:SetAutoFocus(false)
        input:SetNumeric(true)
        input:SetMaxLetters(2)
        input:SetTextInsets(0, 5, 0, 0)
        input:SetJustifyH("CENTER")
        input:SetScript("OnTextChanged", function(box)
            self[key] = tonumber(box:GetText())
            self.page = 1
            if self.catalog then self:Search() end
        end)
        input:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
        input:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
        input:SetScript("OnTabPressed", function(box)
            box:ClearFocus()
            frame[key == "minLevel" and "maxLevel" or "minLevel"]:SetFocus()
        end)
    end
    levelCaption:SetPoint("RIGHT", frame.minLevel, "LEFT", -9, 0)
    local settings = CreateFrame("Button", nil, portrait:GetParent())
    frame.settingsButton = settings
    settings:SetAllPoints(portrait)
    settings:SetScript("OnClick", function() Anquestry:OpenConfig() end)
    settings:SetScript("OnEnter", function(owner)
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetText("Settings")
        GameTooltip:Show()
    end)
    settings:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.rows = {}
    for index = 1, PAGE_SIZE do
        local row = CreateFrame("Button", nil, sidebar)
        row:SetPoint("TOPLEFT", 6, -8 - (index - 1) * 23)
        row:SetSize(SIDEBAR_WIDTH - 14, 23)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetPoint("RIGHT", -5, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetMaxLines(1)
        row.selected = row:CreateTexture(nil, "BACKGROUND")
        row.selected:SetAllPoints()
        row.selected:SetColorTexture(0.2, 0.4, 0.7, 0.55)
        row.strike = row:CreateTexture(nil, "OVERLAY")
        row.strike:SetPoint("LEFT", row.text, "LEFT")
        row.strike:SetHeight(1)
        row.strike:SetColorTexture(0.53, 0.53, 0.53, 1)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
        row:SetScript("OnClick", function(clicked) self:Open(clicked.questID) end)
        frame.rows[index] = row
    end
    frame.previous = button(sidebar, "‹", 32, function() self.page = self.page - 1; self:UpdateList() end)
    frame.previous:SetPoint("BOTTOMLEFT", 9, 8)
    frame.next = button(sidebar, "›", 32, function() self.page = self.page + 1; self:UpdateList() end)
    frame.next:SetPoint("BOTTOMRIGHT", -9, 8)
    frame.pageText = sidebar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.pageText:SetPoint("BOTTOM", 0, 14)
    self.treeView = Anquestry.ui:CreateFlyout(frame, function(id) self:Open(id) end)
    frame.tree = self.treeView.frame
    local pane = CreateFrame("Frame", nil, frame)
    frame.pane = pane
    pane:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 4, 0)
    pane:SetPoint("BOTTOMRIGHT", -8, 8)
    local divider = frame:CreateTexture(nil, "BORDER")
    divider:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMRIGHT", 0, 0)
    divider:SetWidth(4)
    divider:SetColorTexture(0.22, 0.15, 0.09, 1)
    local dividerEdge = frame:CreateTexture(nil, "ARTWORK")
    dividerEdge:SetPoint("TOPLEFT", divider, "TOPLEFT", 1, 0)
    dividerEdge:SetPoint("BOTTOMLEFT", divider, "BOTTOMLEFT", 1, 0)
    dividerEdge:SetWidth(1)
    dividerEdge:SetColorTexture(0.65, 0.45, 0.25, 0.8)
    local toolbarDivider = frame:CreateTexture(nil, "BORDER")
    toolbarDivider:SetPoint("TOPLEFT", 8, -90)
    toolbarDivider:SetPoint("TOPRIGHT", -8, -90)
    toolbarDivider:SetHeight(4)
    toolbarDivider:SetColorTexture(0.22, 0.15, 0.09, 1)
    local toolbarEdge = frame:CreateTexture(nil, "ARTWORK")
    toolbarEdge:SetPoint("TOPLEFT", toolbarDivider, "TOPLEFT", 0, -1)
    toolbarEdge:SetPoint("TOPRIGHT", toolbarDivider, "TOPRIGHT", 0, -1)
    toolbarEdge:SetHeight(1)
    toolbarEdge:SetColorTexture(0.65, 0.45, 0.25, 0.8)
    local parchment = pane:CreateTexture(nil, "BACKGROUND", nil, 1)
    parchment:SetAllPoints()
    parchment:SetAtlas("QuestBG-Parchment")
    frame.scroll = CreateFrame("ScrollFrame", "AnquestryDetailsScroll", pane, "UIPanelScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 0, 0)
    frame.scroll:SetPoint("BOTTOMRIGHT")
    frame.scroll.ScrollBar:ClearAllPoints()
    frame.scroll.ScrollBar:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -5, -22)
    frame.scroll.ScrollBar:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -5, 88)
    frame.content = CreateFrame("Frame", nil, frame.scroll)
    frame.content:SetSize(PANE_WIDTH, 1)
    frame.scroll:SetScrollChild(frame.content)
    frame.titleFrame = CreateFrame("Frame", nil, pane)
    frame.titleFrame:SetPoint("TOPLEFT", 0, -LINK_HEIGHT)
    frame.titleFrame:SetPoint("TOPRIGHT", 0, -LINK_HEIGHT)
    frame.titleBackground = frame.titleFrame:CreateTexture(nil, "BACKGROUND")
    frame.titleBackground:SetPoint("TOPLEFT")
    frame.titleBackground:SetAtlas("questlog-reward-top-frame")
    frame.levelLabel = frame.titleFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.levelLabel:SetPoint("RIGHT", frame.titleBackground, "RIGHT", -TEXT_INSET, 4)
    frame.levelLabel:SetJustifyH("RIGHT")
    frame.levelLabel:SetJustifyV("MIDDLE")
    frame.rewards = CreateFrame("Frame", nil, pane)
    frame.rewards:SetPoint("BOTTOMLEFT")
    frame.rewards:SetPoint("BOTTOMRIGHT")
    frame.rewardsScroll = CreateFrame("ScrollFrame", "AnquestryRewardsScroll", frame.rewards, "UIPanelScrollFrameTemplate")
    frame.rewardsScroll:SetPoint("TOPLEFT", 0, -34)
    frame.rewardsScroll:SetPoint("BOTTOMRIGHT", 0, 28)
    frame.rewardsScroll.ScrollBar:ClearAllPoints()
    frame.rewardsScroll.ScrollBar:SetPoint("TOPRIGHT", -2, -18)
    frame.rewardsScroll.ScrollBar:SetPoint("BOTTOMRIGHT", -2, 18)
    frame.rewardsContent = CreateFrame("Frame", nil, frame.rewardsScroll)
    frame.rewardsContent:SetSize(PANE_WIDTH, 1)
    frame.rewardsScroll:SetScrollChild(frame.rewardsContent)
    frame.rewardsBackground = frame.rewardsContent:CreateTexture(nil, "BACKGROUND")
    frame.rewardsBackground:SetAtlas("questlog-reward-tile-vertical")
    frame.rewardsHeader = frame.rewards:CreateTexture(nil, "BORDER")
    frame.rewardsHeader:SetAtlas("questlog-reward-header-top")
    frame.rewardFooter = CreateFrame("Frame", nil, frame.rewards)
    frame.rewardFooter:SetPoint("BOTTOMLEFT")
    frame.rewardFooter:SetPoint("BOTTOMRIGHT")
    frame.rewardFooter:SetHeight(28)
    local rewardFooterBackground = frame.rewardFooter:CreateTexture(nil, "BACKGROUND")
    rewardFooterBackground:SetAllPoints()
    rewardFooterBackground:SetAtlas("questlog-reward-tile-vertical")
    local rewardFooterLine = frame.rewardFooter:CreateTexture(nil, "ARTWORK")
    frame.rewardFooterLine = rewardFooterLine
    rewardFooterLine:SetPoint("TOPLEFT")
    rewardFooterLine:SetPoint("TOPRIGHT")
    rewardFooterLine:SetHeight(1)
    rewardFooterLine:SetColorTexture(0.43, 0.31, 0.19, 0.7)
    frame.rewardGold = frame.rewardFooter:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.rewardGold:SetPoint("LEFT", TEXT_INSET, 0)
    frame.rewardGold:SetWidth(100)
    frame.rewardGold:SetJustifyH("LEFT")
    frame.rewardGold:SetMaxLines(1)
    frame.rewardXP = frame.rewardFooter:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.rewardXP:SetPoint("CENTER")
    frame.rewardXP:SetJustifyH("CENTER")
    frame.rewardXP:SetJustifyV("MIDDLE")
    frame.rewardXP:SetMaxLines(1)
    frame.rewardRank = frame.rewardFooter:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.rewardRank:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    frame.rewardRank:SetPoint("RIGHT", -12, 0)
    frame.rewardRank:SetWidth(110)
    frame.rewardRank:SetJustifyH("RIGHT")
    frame.rewardRank:SetJustifyV("MIDDLE")
    frame.rewardRank:SetMaxLines(1)
    for _, scroll in ipairs({ frame.scroll, frame.rewardsScroll }) do
        scroll.ScrollBar:Hide()
        scroll:HookScript("OnScrollRangeChanged", function(owner, _, range)
            owner.ScrollBar:SetShown(range > 1)
        end)
    end
    frame.infoHeader = CreateFrame("Frame", nil, pane)
    frame.infoHeader:SetPoint("TOPLEFT", frame.titleFrame, "BOTTOMLEFT")
    frame.infoHeader:SetPoint("TOPRIGHT", frame.titleFrame, "BOTTOMRIGHT")
    frame.infoHeader:SetHeight(INFO_HEIGHT)
    local infoLine = frame.infoHeader:CreateTexture(nil, "ARTWORK")
    infoLine:SetPoint("BOTTOMLEFT")
    infoLine:SetPoint("BOTTOMRIGHT")
    infoLine:SetHeight(1)
    infoLine:SetColorTexture(0.43, 0.31, 0.19, 0.7)
    frame.url = Anquestry.ui:CreateURLField(pane, true)
    frame.url:SetHeight(LINK_HEIGHT)
    frame.url:SetPoint("TOPLEFT")
    frame.url:SetPoint("TOPRIGHT")
    self.texts, self.endpointButtons, self.itemButtons, self.sections = {}, {}, {}, {}
    frame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
    frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    frame:RegisterEvent("QUEST_LOG_UPDATE")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("SKILL_LINES_CHANGED")
    frame:SetScript("OnEvent", function(_, event, id, success)
        if event == "QUEST_DATA_LOAD_RESULT" then
            local request = self.requests[id]
            if request then
                request.basicState = success and "ready" or "failed"
            end
            if id == self.questID then self:ScheduleRefresh() end
        elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
            if self.itemLoads then self.itemLoads[id] = nil end
            if success and ((self.rewardItemIDs and self.rewardItemIDs[id])
                or (self.requiredItemIDs and self.requiredItemIDs[id])) then self:ScheduleRefresh() end
        elseif frame:IsShown() then
            if next(self.statuses) then self.searchDirty = true end
            self:ScheduleRefresh()
        end
    end)
    frame:SetScript("OnHide", function()
        frame:StopMovingOrSizing()
        frame.search:ClearFocus()
        frame.minLevel:ClearFocus()
        frame.maxLevel:ClearFocus()
        frame.url:ClearFocus()
        local owner = GameTooltip:GetOwner()
        while owner and owner ~= frame do owner = owner:GetParent() end
        if owner then GameTooltip:Hide() end
    end)
end

-- Open a quest's independent preview and request its client data on demand.
function details:Open(id, keepFocus, focusURL)
    if not Anquestry.db:Exists(id) then return end
    self:Initialize()
    self:BuildCatalog()
    local changed = self.questID ~= id
    if changed then
        self.frame.scroll:SetVerticalScroll(0)
        self.frame.rewardsScroll:SetVerticalScroll(0)
    end
    self.questID = id
    self.frame:SetScale(math.min(1, (UIParent:GetWidth() - 30) / WINDOW_WIDTH,
        (UIParent:GetHeight() - 30) / WINDOW_HEIGHT))
    self:SyncMapLayer()
    self.frame:Show()
    if not keepFocus then self.frame:Raise() end
    self:Search()
    if changed then
        for index, entry in ipairs(self.matches) do
            if entry.id == id then
                self.page = math.ceil(index / (self.pageSize or PAGE_SIZE))
                self:UpdateList()
                break
            end
        end
    end
    self:RequestData(id)
    self:Render()
    if focusURL then
        self.frame.url:SetFocus()
        self.frame.url:HighlightText()
    end
end
