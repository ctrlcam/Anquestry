local addonName, Anquestry = ...
Anquestry.ui = { rows = {}, collapsed = false }

local PANEL_WIDTH, STANDALONE_MAX_HEIGHT = 250, 390
local HEADER_HEIGHT = 34
local COMPLETED_COLOR = 0.53
local XP_GRADE_COLORS = {
    ["S+"] = "ffd700", S = "f5ca32", A = "e6bd55", B = "d8b371",
    C = "c8ad83", D = "b8aa92", F = "a8a49e", ["F-"] = "989898",
}

-- Pick a difficulty color based on the player’s level.
local function questColor(level)
    local player = UnitLevel("player") or level or 1
    if not level or level <= 0 then return 0.95, 0.82, 0.35 end
    local delta = level - player
    if delta >= 5 then return 1, 0.1, 0.1 end
    if delta >= 3 then return 1, 0.5, 0.25 end
    if delta >= -2 then return 1, 0.95, 0.1 end
    local greenRange = GetQuestGreenRange and GetQuestGreenRange() or 5
    if delta >= -greenRange then return 0.25, 0.8, 0.25 end
    return 0.55, 0.55, 0.55
end

-- Draw only links whose endpoints are visible after filtering and grouping.
local function layoutLinks(chain)
    local positions, groups = {}, {}
    for i, info in ipairs(chain) do
        positions[info.id] = i
        for _, id in ipairs(info.variants or {}) do positions[id] = i end
    end
    -- Group outgoing links so siblings share a single vertical rail.
    local function add(from, to, breadcrumb)
        local first, last = positions[from], positions[to]
        if not first or not last or first >= last then return end
        local key = first * 2 - (breadcrumb and 0 or 1)
        local group = groups[key]
        if not group then
            group = { first = first, last = last, targets = {} }
            groups[key] = group
        end
        group.last = math.max(group.last, last)
        group.targets[last] = breadcrumb
    end
    for _, info in ipairs(chain) do
        for _, variant in ipairs(info.variants or { info.id }) do
            local earlier, later = Anquestry.db:Relationships(variant)
            for _, id in ipairs(earlier) do add(id, variant, false) end
            for _, id in ipairs(later) do add(variant, id, false) end
        end
    end
    for i, info in ipairs(chain) do
        local breadcrumb = Anquestry.db:Get(info.id, "breadcrumbForQuestId")
        if breadcrumb and positions[breadcrumb] and positions[breadcrumb] > i then
            local solid = groups[i * 2 - 1]
            if solid then solid.targets[positions[breadcrumb]] = nil end
            add(info.id, breadcrumb, true)
        end
    end
    local links = {}
    for _, group in pairs(groups) do
        for target, breadcrumb in pairs(group.targets) do
            local source = group.first
            links[target] = links[target] or {}
            if breadcrumb then
                links[source] = links[source] or {}
                links[source][#links[source] + 1] = { index = target, label = "Breadcrumb for" }
            end
            links[target][#links[target] + 1] = {
                index = source, label = breadcrumb and "Breadcrumb from" or "Comes after",
            }
        end
    end
    local offsets, offset = {}, 0
    for index = 1, #chain do
        offsets[index] = offset
        offset = offset + 22
    end
    local joins = {}
    -- Find a fork whose straight, separate tracks end at this join.
    local function findSharedFork(sources, target)
        local endings = {}
        for _, source in ipairs(sources) do endings[source] = true end
        for first = sources[1] - 1, 1, -1 do
            local fork = groups[first * 2 - 1]
            if fork and not fork.sharedJoin then
                local matched, count, valid = {}, 0, true
                for start in pairs(fork.targets) do
                    local step = start
                    while step < target and not endings[step] do
                        local rail = groups[step * 2 - 1]
                        local nextStep = rail and next(rail.targets)
                        if not nextStep or nextStep ~= step + 1 or next(rail.targets, nextStep) then break end
                        step = nextStep
                    end
                    local ending = groups[step * 2 - 1]
                    if not endings[step] or matched[step] or not ending
                        or ending.targets[target] ~= false or next(ending.targets) ~= target
                        or next(ending.targets, target) then
                        valid = false
                        break
                    end
                    matched[step] = true
                    count = count + 1
                end
                if valid and count == #sources then return fork end
            end
        end
    end
    for target, info in ipairs(chain) do
        local all = Anquestry.db:Get(info.id, "preQuestGroup")
        local any = Anquestry.db:Get(info.id, "preQuestSingle")
        local required, label
        if all and #all > 1 and (not any or #any == 0) then
            required, label = all, "ALL"
        elseif any and #any > 1 and (not all or #all == 0) then
            required, label = any, "ANY"
        end
        if required then
            local sources, seenSources, visible = {}, {}, 0
            for _, id in ipairs(required) do
                local source = positions[id]
                local rail = source and groups[source * 2 - 1]
                if rail and rail.targets[target] == false then
                    visible = visible + 1
                    if not seenSources[source] then sources[#sources + 1] = source end
                    seenSources[source] = true
                end
            end
            if visible == #required and #sources > 1 then
                table.sort(sources)
                local fork = findSharedFork(sources, target)
                local taps = {}
                for index, source in ipairs(sources) do
                    groups[source * 2 - 1].targets[target] = nil
                    if index > 1 then taps[source] = true end
                end
                if fork then
                    fork.sharedJoin = target
                    fork.targets[target] = false
                else
                    groups[#chain * 2 + target] = { first = sources[1], targets = { [target] = false }, taps = taps }
                end
                joins[target] = label
            end
        end
    end
    local inCount, outCount = {}, {}
    for _, group in pairs(groups) do
        for target in pairs(group.targets) do
            inCount[target] = (inCount[target] or 0) + 1
            outCount[group.first] = (outCount[group.first] or 0) + 1
        end
    end
    local laneEnds, rails = {}, {}
    for _, group in pairs(groups) do
        if next(group.targets) then rails[#rails + 1] = group end
    end
    table.sort(rails, function(a, b) return a.first < b.first end)
    for _, group in ipairs(rails) do
        group.last = group.first
        for target in pairs(group.targets) do group.last = math.max(group.last, target) end
        local target, breadcrumb = next(group.targets)
        if not group.taps and target == group.first + 1 and not next(group.targets, target)
            and (breadcrumb or (outCount[group.first] == 1 and inCount[target] == 1)) then
            group.straight = target
        else
            local lane = 1
            while laneEnds[lane] and laneEnds[lane] >= group.first - 1 do lane = lane + 1 end
            laneEnds[lane] = group.last
            group.lane = lane
        end
    end
    local gutter = #rails > 0 and math.min(34, 12 + #laneEnds * 5) or 0
    return rails, offsets, gutter, #laneEnds, joins, offset, links
end

-- Reuse thin textures for rails, elbows, and quest dots.
function Anquestry.ui:DrawLinks(groups, offsets, gutter, lanes, joins, chain)
    self.linkArt = self.linkArt or {}
    local used, nodes = 0, {}
    local nodeRed, nodeGreen, nodeBlue
    -- Draw one rectangular segment in scroll-content coordinates.
    local function segment(x, y, width, height, dot)
        used = used + 1
        local texture = self.linkArt[used]
        if not texture then
            texture = self.frame.content:CreateTexture(nil, "ARTWORK")
            self.linkArt[used] = texture
        end
        texture:ClearAllPoints()
        texture:SetPoint("TOPLEFT", self.frame.content, "TOPLEFT", x, -y)
        texture:SetSize(width, height)
        texture:SetDrawLayer("ARTWORK", dot and 2 or 0)
        if dot then
            texture:SetColorTexture(nodeRed, nodeGreen, nodeBlue, 1)
        else
            texture:SetColorTexture(0.76, 0.55, 0.34, 0.8)
        end
        texture:Show()
    end
    local nodeX = gutter - 3
    local nodePositions = {}
    -- Find the horizontal position of a rail within the gutter.
    local function railX(group)
        return 3 + (group.lane - 1) * (gutter - 8) / lanes
    end
    for _, group in ipairs(groups) do
        if not group.straight then
            local _, breadcrumb = next(group.targets)
            if not breadcrumb then nodePositions[group.first] = railX(group) end
        end
    end
    for i = #groups, 1, -1 do
        local group = groups[i]
        if group.straight and not group.targets[group.straight] then
            nodePositions[group.first] = nodePositions[group.straight] or nodePositions[group.first]
        end
    end
    local outgoingCount, hasIncoming = {}, {}
    for _, group in ipairs(groups) do
        for target in pairs(group.targets) do
            outgoingCount[group.first] = (outgoingCount[group.first] or 0) + 1
            hasIncoming[target] = true
        end
        for source in pairs(group.taps or {}) do
            outgoingCount[source] = (outgoingCount[source] or 0) + 1
        end
    end
    -- Align a standalone breadcrumb with its destination when it has no other links.
    for _, group in ipairs(groups) do
        local target = group.straight
        if target and group.targets[target] and not hasIncoming[group.first] and outgoingCount[group.first] == 1 then
            nodePositions[group.first] = nodePositions[target] or nodeX
        end
    end
    -- Align leaf siblings with the entry to a continuing branch.
    for _, group in ipairs(groups) do
        if not group.straight and not group.taps then
            local siblingX
            local x = railX(group)
            for target, breadcrumb in pairs(group.targets) do
                local entry = nodePositions[target]
                if not breadcrumb and entry and entry > x then
                    siblingX = math.min(siblingX or entry, entry)
                end
            end
            if siblingX then
                for target, breadcrumb in pairs(group.targets) do
                    if not breadcrumb and not outgoingCount[target] and not nodePositions[target] then
                        nodePositions[target] = siblingX
                    end
                end
            end
        end
    end
    -- Point into the destination row, never back toward its source.
    local function arrow(index, downward)
        if joins and joins[index] then return end
        local y = offsets[index] + 11
        local nodeX = nodePositions[index] or nodeX
        if downward then
            segment(nodeX - 2, y - 6, 5, 1)
            segment(nodeX - 1, y - 5, 3, 1)
            segment(nodeX, y - 4, 1, 1)
        else
            segment(nodeX - 5, y - 2, 1, 5)
            segment(nodeX - 4, y - 1, 1, 3)
            segment(nodeX - 3, y, 1, 1)
        end
    end
    -- Break a horizontal connector where it crosses an unrelated vertical rail.
    local function horizontal(group, index, dashed)
        local x = railX(group)
        local nodeX = nodePositions[index] or nodeX
        local y = offsets[index] + 11
        local gaps = {}
        for _, other in pairs(groups) do
            if other ~= group and not other.straight and other.first < index and other.last > index
                and other.targets[index] == nil and not (other.taps and other.taps[index]) then
                local crossing = railX(other)
                if crossing > x and crossing < nodeX then gaps[#gaps + 1] = crossing end
            end
        end
        table.sort(gaps)
        -- Draw a solid run or short dashes between crossings.
        local function run(left, right)
            if right <= left then return end
            if not dashed then
                segment(left, y, right - left, 1)
                return
            end
            for dash = left, right - 0.5, 5 do
                segment(dash, y, math.min(3, right - dash), 1)
            end
        end
        for _, crossing in ipairs(gaps) do
            run(x, crossing - 2)
            x = math.max(x, crossing + 3)
        end
        run(x, nodeX)
    end
    for _, group in pairs(groups) do
        local y = offsets[group.first] + 11
        local target = group.straight
        if target then
            local endY = offsets[target] + 11
            local x = nodePositions[group.first] or nodeX
            local targetX = nodePositions[target] or nodeX
            if group.targets[target] then
                for dashY = y + 3, endY - 3, 5 do
                    local fraction = (dashY - y) / (endY - y)
                    local dashX = x + (targetX - x) * fraction
                    segment(dashX, dashY, 1, math.min(3, endY - 2 - dashY))
                end
            else
                segment(x, y, 1, endY - y)
            end
            arrow(target, true)
            nodes[group.first] = nodes[group.first] or "circle"
            nodes[target] = group.targets[target] and (nodes[target] or "circle") or "square"
        else
            local x = railX(group)
            local solidEnd = y
            for destination, breadcrumb in pairs(group.targets) do
                if not breadcrumb then solidEnd = math.max(solidEnd, offsets[destination] + 11) end
            end
            if not nodePositions[group.first] then horizontal(group, group.first, false) end
            if solidEnd > y then segment(x, y, 1, solidEnd - y) end
            for dashY = solidEnd, offsets[group.last] + 10, 5 do
                local length = math.min(3, offsets[group.last] + 11 - dashY)
                segment(x, dashY, 1, length)
            end
            nodes[group.first] = nodes[group.first] or "circle"
            for source in pairs(group.taps or {}) do
                horizontal(group, source, false)
                nodes[source] = nodes[source] or "circle"
            end
            for destination, breadcrumb in pairs(group.targets) do
                horizontal(group, destination, breadcrumb)
                arrow(destination, (nodePositions[destination] or nodeX) == x)
                nodes[destination] = nodes[destination] or "circle"
            end
        end
    end
    for index, shape in pairs(nodes) do
        nodeRed, nodeGreen, nodeBlue = questColor(chain[index].level)
        if chain[index].done then nodeRed, nodeGreen, nodeBlue = COMPLETED_COLOR, COMPLETED_COLOR, COMPLETED_COLOR end
        local x, y = nodePositions[index] or nodeX, offsets[index] + 11
        local join = joins and joins[index]
        if join == "ALL" then
            segment(x, y - 4, 1, 2, true)
            segment(x - 4, y - 2, 9, 1, true)
            segment(x - 3, y - 1, 7, 1, true)
            segment(x - 2, y, 5, 2, true)
            segment(x - 3, y + 2, 3, 1, true)
            segment(x + 1, y + 2, 3, 1, true)
            segment(x - 3, y + 3, 1, 1, true)
            segment(x + 3, y + 3, 1, 1, true)
        elseif join == "ANY" then
            for step = 0, 3 do
                segment(x - step, y - 3 + step * 2, step * 2 + 1, step == 3 and 1 or 2, true)
            end
        elseif shape == "square" then
            segment(x - 2, y - 2, 5, 5, true)
        else
            segment(x - 1, y - 2, 3, 5, true)
            segment(x - 2, y - 1, 5, 3, true)
        end
    end
    for i = used + 1, #self.linkArt do self.linkArt[i]:Hide() end
    return nodePositions
end


-- Give the panel a Blizzard-style background and border.
local function backdrop(frame)
    local base = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    base:SetPoint("TOPLEFT", 3, -3)
    base:SetPoint("BOTTOMRIGHT", -3, 3)
    base:SetColorTexture(0.09, 0.075, 0.06, 1)
    frame.backgroundBase = base
    frame.questLogArt = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    frame.questLogArt:SetAllPoints(base)
    frame.questLogArt:Hide()
    if frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        frame:SetBackdropColor(0.26, 0.22, 0.18, 0.8)
        frame:SetBackdropBorderColor(0.76, 0.51, 0.29)
    end
end

-- Reuse the map quest log's live background without modifying Blizzard's frame.
local function syncQuestLogArt(frame)
    if Anquestry.ui.collapsed then return end
    local details = QuestMapFrame and QuestMapFrame.DetailsFrame
    local back = details and details.BackFrame
    local sourceBand, largest = nil, 0
    if back then
        for _, region in ipairs({ back:GetRegions() }) do
            if region:IsObjectType("Texture") and (region:GetAtlas() or region:GetTexture()) then
                local area = region:GetWidth() * region:GetHeight()
                if area > largest then sourceBand, largest = region, area end
            end
        end
    end
    if frame.footerBand and C_Texture and C_Texture.GetAtlasInfo
        and C_Texture.GetAtlasInfo("questlog-reward-header-top") then
        frame.footerBand:SetAtlas("questlog-reward-header-top", false)
    end
    if sourceBand and frame.headerBand then
        local band = frame.headerBand
        local atlas = sourceBand:GetAtlas()
        if atlas then
            band:SetAtlas(atlas, false)
        else
            band:SetTexture(sourceBand:GetTexture())
        end
        local left, top, _, bottom, right = sourceBand:GetTexCoord()
        local dx, dy = (right - left) * 0.045, (bottom - top) * 0.14
        band:SetTexCoord(left + dx, right - dx, top + dy, bottom - dy)
        band:SetVertexColor(sourceBand:GetVertexColor())
    end
    local source = QuestScrollFrame and QuestScrollFrame.Background
    if not source then return end
    local atlas = source:GetAtlas()
    local texture = source:GetTexture()
    if not atlas and not texture then return end
    local art = frame.questLogArt
    if atlas then
        art:SetAtlas(atlas, false)
    else
        art:SetTexture(texture)
    end
    local ulX, ulY, llX, llY, urX, urY, lrX, lrY = source:GetTexCoord()
    local sourceWidth, sourceHeight = source:GetSize()
    local width, height = frame:GetWidth() - 6, frame:GetHeight() - 6
    if sourceWidth > 0 and sourceHeight > 0 and width > 0 and height > 0 then
        local scale = math.max(width / sourceWidth, height / sourceHeight)
        local x, y = width / (sourceWidth * scale), height / (sourceHeight * scale)
        -- Crop from the top left of the source texture or atlas region.
        local rightX, rightY = ulX + (urX - ulX) * x, ulY + (urY - ulY) * x
        local bottomX, bottomY = ulX + (llX - ulX) * y, ulY + (llY - ulY) * y
        local lowerX, lowerY = llX + (lrX - llX) * x, llY + (lrY - llY) * x
        art:SetTexCoord(ulX, ulY, bottomX, bottomY, rightX, rightY,
            rightX + (lowerX - rightX) * y, rightY + (lowerY - rightY) * y)
    else
        art:SetTexCoord(source:GetTexCoord())
    end
    art:SetVertexColor(source:GetVertexColor())
    art:SetAlpha(source:GetAlpha())
    art:Show()
end


-- Add the shared bronze-tinted header band.
local function createHeaderBand(frame, onClick)
    local band = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
    band:SetPoint("TOPLEFT", 3, -3)
    band:SetPoint("TOPRIGHT", -3, -3)
    band:SetHeight(HEADER_HEIGHT - 3)
    band:SetColorTexture(0.22, 0.15, 0.09, 0.68)
    local button = CreateFrame("Button", nil, frame)
    button:SetAllPoints(band)
    button:SetScript("OnClick", onClick)
    return band, button
end

-- Keep the native close art in place and darken it while pressed.
local function createPanelCloseButton(parent)
    local button = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    button:SetSize(22, 20)
    local normal, pushed = button:GetNormalTexture(), button:GetPushedTexture()
    if normal and pushed then
        local atlas = normal:GetAtlas()
        if atlas then
            pushed:SetAtlas(atlas, false)
        else
            pushed:SetTexture(normal:GetTexture())
        end
        pushed:SetTexCoord(normal:GetTexCoord())
        pushed:ClearAllPoints()
        pushed:SetAllPoints(normal)
        pushed:SetVertexColor(0.78, 0.78, 0.78)
    end
    return button
end

-- Create the flyout and hook it into Blizzard’s quest windows.
function Anquestry.ui:Initialize()
    if self.frame then return end
    if type(AnquestrySettings) ~= "table" then AnquestrySettings = {} end
    self.infoCollapsed = AnquestrySettings.infoCollapsed == true
    local f = CreateFrame("Frame", "AnquestryFlyout", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    f:SetSize(PANEL_WIDTH, 70)
    f:SetFrameStrata("HIGH")
    f:Hide()
    backdrop(f)
    f:HookScript("OnSizeChanged", syncQuestLogArt)
    self.frame = f

    f.headerBand, f.headerButton = createHeaderBand(f, function() self:SetCollapsed(true) end)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 30, -11)
    f.title:SetJustifyH("LEFT")
    f.title:SetText("Anquestry")
    f.launcher = CreateFrame("Button", nil, f)
    f.launcher:SetSize(22, 22)
    f.launcher:SetPoint("TOPLEFT", 6, -6)
    f.launcher:SetNormalTexture("Interface\\AddOns\\" .. addonName .. "\\icons\\anquestry_128.png")
    f.launcher:SetScript("OnClick", function() self:SetCollapsed(not self.collapsed) end)
    f.launcher:SetScript("OnEnter", function(button)
        if not self.collapsed then return end
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetText("Anquestry")
        GameTooltip:Show()
    end)
    f.launcher:SetScript("OnLeave", function(button)
        if GameTooltip:IsOwned(button) then GameTooltip:Hide() end
    end)
    f.toggle = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.toggle:SetSize(22, 20)
    f.toggle:SetPoint("TOPRIGHT", -8, -7)
    f.toggle:SetText("−")
    f.toggle:SetScript("OnClick", function() self:SetCollapsed(true) end)

    f.scroll = CreateFrame("ScrollFrame", nil, f)
    f.scroll:SetPoint("TOPLEFT", 5, -HEADER_HEIGHT); f.scroll:SetPoint("BOTTOMRIGHT", -5, 26)
    f.footerBand = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    f.footerBand:SetPoint("TOPLEFT", f.scroll, "BOTTOMLEFT", -2, 0)
    f.footerBand:SetPoint("BOTTOMRIGHT", -3, 5)
    f.footerBand:SetColorTexture(0.15, 0.105, 0.07, 0.75)
    f.scroll:EnableMouseWheel(true)
    f.scroll:SetScript("OnMouseWheel", function(scroll, delta)
        local nextOffset = scroll:GetVerticalScroll() - delta * 44
        scroll:SetVerticalScroll(math.max(0, math.min(nextOffset, scroll:GetVerticalScrollRange())))
    end)
    f.content = CreateFrame("Frame", nil, f.scroll)
    f.content:SetWidth(PANEL_WIDTH - 10); f.content:SetHeight(1)
    f.scroll:SetScrollChild(f.content)
    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOMLEFT", 12, 9); f.footer:SetPoint("BOTTOMRIGHT", -100, 9)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetText("Select a quest to view its chain.")
    f.xpTotal = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.xpTotal:SetPoint("BOTTOMRIGHT", -8, 9)

    f.build = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.build:SetSize(200, 24)
    f.build:SetPoint("TOP", 0, -42)
    f.build:SetText("Build quest chain cache")
    f.build:Hide()
    f.build:SetScript("OnClick", function()
        Anquestry:RebuildCache()
    end)

    if QuestFrame then
        QuestFrame:HookScript("OnShow", function() Anquestry:Refresh("SHOW") end)
        QuestFrame:HookScript("OnHide", function() Anquestry.giverQuestID = nil; Anquestry:Refresh("SHOW") end)
        QuestFrame:HookScript("OnSizeChanged", function() Anquestry:Refresh("ANCHOR_SIZE") end)
    end
    if QuestLog_Update then hooksecurefunc("QuestLog_Update", function() Anquestry:Refresh("QuestLog_Update") end) end
    if C_QuestLog and C_QuestLog.SetSelectedQuest then
        hooksecurefunc(C_QuestLog, "SetSelectedQuest", function() Anquestry:Refresh("SELECTION") end)
    elseif SelectQuestLogEntry then
        hooksecurefunc("SelectQuestLogEntry", function() Anquestry:Refresh("SELECTION") end)
    end
    self:HookQuestLog()
end

-- Watch the standalone log and the log built into the world map.
function Anquestry.ui:HookQuestLog()
    self.logHooks = self.logHooks or {}
    for _, log in pairs({ QuestLogFrame, QuestMapFrame, WorldMapFrame }) do
        if not self.logHooks[log] then
            self.logHooks[log] = true
            log:HookScript("OnShow", function() Anquestry:Refresh("SHOW") end)
            log:HookScript("OnSizeChanged", function() Anquestry:Refresh("ANCHOR_SIZE") end)
            log:HookScript("OnHide", function()
                if log == WorldMapFrame then Anquestry.mapPreviewQuestID = nil end
                Anquestry:Refresh("SHOW")
            end)
        end
    end
    if not self.detailHook and QuestMapFrame_ShowQuestDetails then
        self.detailHook = true
        hooksecurefunc("QuestMapFrame_ShowQuestDetails", function() Anquestry:Refresh("SELECTION") end)
        if QuestMapFrame_CloseQuestDetails then
            hooksecurefunc("QuestMapFrame_CloseQuestDetails", function() Anquestry:Refresh("SELECTION") end)
        end
    end
    self:HookBlizzardPins()
end

-- Watch Blizzard quest pins directly, even when tracking is redirected.
function Anquestry.ui:HookBlizzardPins()
    local map = WorldMapFrame
    if self.blizzardPinHooks or not map or not map.EnumeratePinsByTemplate or not map.AcquirePin then return end
    self.blizzardPinHooks = {}
    local templates = { QuestOfferPinTemplate = true, QuestPinTemplate = true }
    local pending = false
    -- Attach once to each pooled pin after the map finishes populating it.
    local function scan()
        pending = false
        for template in pairs(templates) do
            for pin in map:EnumeratePinsByTemplate(template) do
                if not self.blizzardPinHooks[pin] and type(pin.OnMouseClickAction) == "function" then
                    self.blizzardPinHooks[pin] = true
                    hooksecurefunc(pin, "OnMouseClickAction", function(clicked, button)
                        if button ~= "LeftButton" or IsModifierKeyDown() or not map:IsVisible() then return end
                        local id = clicked.GetQuestID and clicked:GetQuestID() or clicked.questID
                        if type(id) ~= "number" or id <= 0 then return end
                        Anquestry.mapPreviewQuestID = id
                        Anquestry:Refresh("BLIZZARD_PIN")
                    end)
                end
            end
        end
    end
    hooksecurefunc(map, "AcquirePin", function(_, template)
        if templates[template] and not pending then
            pending = true
            C_Timer.After(0, scan)
        end
    end)
    scan()
end

-- Switch between the full panel and the title bar.
function Anquestry.ui:SetCollapsed(collapsed)
    self.collapsed = collapsed
    if collapsed and self.urlPopup then self.urlPopup:Hide() end
    local f = self.frame
    f.title:SetShown(not collapsed)
    f.toggle:SetShown(not collapsed)
    f.headerBand:SetShown(not collapsed)
    f.headerButton:SetShown(not collapsed)
    if collapsed then f.questLogArt:Hide() end
    self.frame.scroll:SetShown(not collapsed)
    self.frame.footer:SetShown(not collapsed)
    self.frame.footerBand:SetShown(not collapsed)
    self.frame.xpTotal:SetShown(not collapsed)
    f:SetSize(collapsed and HEADER_HEIGHT or PANEL_WIDTH, collapsed and HEADER_HEIGHT or self.expandedHeight or 70)
    if GameTooltip:IsOwned(f.launcher) then GameTooltip:Hide() end
    Anquestry:Refresh("COLLAPSE")
end

-- Fit the rows and footer while keeping long chains scrollable.
function Anquestry.ui:FitHeight(contentHeight)
    self.contentHeight = contentHeight
    local footerHeight = math.max(26, self.frame.footer:GetStringHeight() + 15)
    self.frame.scroll:SetPoint("BOTTOMRIGHT", -5, footerHeight)
    local host = self.anchor
    if host == QuestMapFrame then host = WorldMapFrame or host end
    local maxHeight = STANDALONE_MAX_HEIGHT
    if host and host ~= UIParent and host:GetHeight() > 0 then
        maxHeight = host:GetHeight() * host:GetEffectiveScale() / self.frame:GetEffectiveScale()
    end
    local top, bottom = self.frame:GetTop(), UIParent:GetBottom()
    if top and bottom and self.urlPopup and self.urlPopup:IsShown() then
        local space = top - bottom * UIParent:GetEffectiveScale() / self.frame:GetEffectiveScale()
        maxHeight = math.min(maxHeight, math.max(HEADER_HEIGHT + footerHeight + 22,
            space - self.urlPopup:GetHeight() - 3))
    end
    self.expandedHeight = math.min(maxHeight, HEADER_HEIGHT + contentHeight + footerHeight)
    if not self.collapsed then self.frame:SetHeight(self.expandedHeight) end
end

-- Create a hoverable icon with its own tooltip.
local function createIconTag(row, texture)
    local tag = CreateFrame("Frame", nil, row)
    tag:SetSize(15, 18)
    tag:EnableMouse(true)
    tag.icon = tag:CreateTexture(nil, "ARTWORK")
    tag.icon:SetSize(11, 11)
    tag.icon:SetPoint("LEFT", 2, 0)
    tag.icon:SetTexture(texture)
    tag:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.tooltipLines then
            for _, line in ipairs(self.tooltipLines) do
                GameTooltip:AddLine(line, 1, 1, 1, false)
            end
        else
            GameTooltip:AddLine(self.tooltip, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    tag:SetScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    return tag
end

-- Open the endpoint's map and place a native pin where supported.
local function showEndpointOnMap(point)
    if InCombatLockdown() then
        Anquestry:Print("Open quest locations after combat.")
        return false
    end
    if C_Map and C_Map.OpenWorldMap then
        C_Map.OpenWorldMap(point.map)
    elseif WorldMapFrame and WorldMapFrame.SetMapID then
        ShowUIPanel(WorldMapFrame)
        WorldMapFrame:SetMapID(point.map)
    else
        return false
    end
    if C_Map and C_Map.SetUserWaypoint and C_Map.CanSetUserWaypointOnMap
        and UiMapPoint and C_Map.CanSetUserWaypointOnMap(point.map) then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(point.map, point.x, point.y))
    else
        Anquestry:Print("This map doesn’t support a pin.")
    end
    return true
end

-- Update the docked details for one quest or location variant.
function Anquestry.ui:ShowWowheadURL(questID, variants)
    if AnquestrySettings.showQuestInfo == false then return end
    local popup = self.urlPopup
    if not popup then
        popup = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate")
        popup:SetHeight(76)
        popup:SetPoint("TOPLEFT", self.frame, "BOTTOMLEFT", 0, -3)
        popup:SetPoint("TOPRIGHT", self.frame, "BOTTOMRIGHT", 0, -3)
        self.frame:HookScript("OnHide", function() popup:Hide() end)
        popup:SetFrameStrata("DIALOG")
        popup:EnableMouse(true)
        backdrop(popup)
        local function toggleInfo()
            self.infoCollapsed = not self.infoCollapsed
            AnquestrySettings.infoCollapsed = self.infoCollapsed
            self:ShowWowheadURL(popup.questID, popup.variants)
        end
        popup.headerBand = createHeaderBand(popup, toggleInfo)

        local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 12, -11)
        title:SetText("Quest Info")
        local toggle = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
        toggle:SetSize(22, 20)
        toggle:SetPoint("TOPRIGHT", -8, -7)
        toggle:SetScript("OnClick", toggleInfo)
        popup.toggle = toggle

        local editBox = CreateFrame("EditBox", nil, popup)
        editBox:SetPoint("BOTTOMLEFT", 10, 9)
        editBox:SetPoint("BOTTOMRIGHT", -10, 9)
        editBox:SetHeight(24)
        editBox:SetFontObject("GameFontHighlightSmall")
        editBox:SetTextInsets(7, 7, 0, 0)
        editBox:SetJustifyH("LEFT")
        popup.questIDText = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        popup.questIDText:SetPoint("TOPLEFT", 12, -39)
        popup.endpoints = {}
        popup.locationPicker = CreateFrame("DropdownButton", nil, popup, "WowStyle1DropdownTemplate")
        popup.locationPicker:SetPoint("TOPLEFT", 10, -55)
        popup.locationPicker:SetPoint("RIGHT", popup, "RIGHT", -10, 0)
        local rim = editBox:CreateTexture(nil, "BACKGROUND")
        rim:SetAllPoints()
        rim:SetColorTexture(0.43, 0.31, 0.19, 1)
        local fill = editBox:CreateTexture(nil, "BACKGROUND", nil, 1)
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", -1, 1)
        fill:SetColorTexture(0.11, 0.085, 0.065, 1)
        editBox:SetAutoFocus(false)
        editBox:SetScript("OnTextChanged", function(field, userInput)
            if userInput and field.copyURL and field:GetText() ~= field.copyURL then
                field:SetText(field.copyURL)
                field:SetCursorPosition(#field.copyURL)
                field:HighlightText()
            end
        end)
        editBox:SetScript("OnEscapePressed", function(field) field:ClearFocus() end)
        editBox:SetScript("OnEditFocusGained", function(field) field:HighlightText() end)
        editBox:SetScript("OnMouseUp", function(field, button)
            if button == "LeftButton" then
                field:SetFocus()
                field:HighlightText()
            end
        end)
        editBox:SetScript("OnKeyUp", function(_, key)
            if (key == "C" and IsControlKeyDown())
                or ((key == "LCTRL" or key == "RCTRL") and IsKeyDown and IsKeyDown("C")) then
                editBox:ClearFocus()
            end
        end)
        popup:SetScript("OnHide", function()
            self.locationQuestID = nil
            editBox:ClearFocus()
        end)
        popup.editBox = editBox
        self.urlPopup = popup
    end
    if popup.questID ~= questID or self.infoCollapsed then popup.editBox:ClearFocus() end
    popup.questIDText:SetText(("Quest ID: %d"):format(questID))
    popup.questID, popup.variants = questID, variants
    popup.toggle:SetText(self.infoCollapsed and "+" or "−")
    popup.questIDText:SetShown(not self.infoCollapsed)
    popup.editBox:SetShown(not self.infoCollapsed)
    if self.infoCollapsed then
        popup.locationPicker:Hide()
        for _, button in ipairs(popup.endpoints) do button:Hide() end
        popup:SetHeight(HEADER_HEIGHT)
        popup:Show()
        syncQuestLogArt(popup)
        if self.contentHeight then self:FitHeight(self.contentHeight) end
        return
    end
    local grouped = variants and #variants > 1
    popup.locationPicker:SetShown(not not grouped)
    if grouped then
        popup.locationPicker:SetupMenu(function(_, root)
            root:CreateTitle("Quest location")
            for _, id in ipairs(variants) do
                local variantID = id
                local starter = Anquestry.db:QuestEndpoints(variantID)[1]
                local point = starter and starter.starts and Anquestry.db:FindMapPoint(starter.spawns)
                local map = point and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(point.map)
                local label = starter and starter.starts and starter.name or ("Quest " .. variantID)
                if map and map.name then label = label .. " · " .. map.name end
                root:CreateRadio(label, function() return popup.questID == variantID end, function()
                    C_Timer.After(0, function()
                        if popup:IsShown() and popup.variants == variants then
                            self:ShowWowheadURL(variantID, variants)
                        end
                    end)
                end)
            end
        end)
    end
    local pickerHeight = grouped and 28 or 0
    local endpoints = Anquestry.db:QuestEndpoints(questID)
    for index, endpoint in ipairs(endpoints) do
        local button = popup.endpoints[index]
        if not button then
            button = CreateFrame("Button", nil, popup)
            button:SetHeight(20)
            button.icon = button:CreateTexture(nil, "ARTWORK")
            button.icon:SetSize(13, 13)
            button.icon:SetPoint("LEFT")
            button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            button.label:SetPoint("LEFT", button.icon, "RIGHT", 6, 0)
            button.label:SetPoint("RIGHT")
            button.label:SetJustifyH("LEFT")
            button.label:SetMaxLines(1)
            button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
            button:SetScript("OnClick", function(clicked)
                if not clicked.point then return end
                local questID = self.lastSelected or popup.questID
                self.openingQuestLocation = true
                local opened = showEndpointOnMap(clicked.point)
                self.openingQuestLocation = false
                if opened then
                    self.locationQuestID = questID
                    Anquestry:Refresh("QUEST_LOCATION")
                end
            end)
            popup.endpoints[index] = button
        end
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", 12, -54 - pickerHeight - (index - 1) * 20)
        button:SetPoint("RIGHT", popup, "RIGHT", -12, 0)
        button.point = Anquestry.db:FindMapPoint(endpoint.spawns)
        button:EnableMouse(button.point ~= nil)
        button.icon:SetTexture(endpoint.starts and "Interface\\GossipFrame\\AvailableQuestIcon"
            or "Interface\\GossipFrame\\ActiveQuestIcon")
        button.label:SetText((endpoint.starts and "Start: " or "Turn in: ") .. endpoint.name)
        local shade = button.point and 1 or 0.65
        button.label:SetTextColor(shade, shade, shade)
        button:Show()
    end
    for index = #endpoints + 1, #popup.endpoints do popup.endpoints[index]:Hide() end
    popup:SetHeight(95 + pickerHeight + #endpoints * 20)
    popup:Show()
    syncQuestLogArt(popup)
    if self.contentHeight then self:FitHeight(self.contentHeight) end
    local url = "wowhead.com/forever/quest=" .. questID
    popup.editBox.copyURL = url
    popup.editBox:SetText(url)
    popup.editBox:SetCursorPosition(#url)
end

-- Reuse or create a clickable quest row.
function Anquestry.ui:GetRow(index)
    local row = self.rows[index]
    if row then return row end
    row = CreateFrame("Button", nil, self.frame.content)
    row.connection = createIconTag(row, nil)
    row.connection:SetSize(12, 20)
    row.connection:SetPoint("RIGHT", row, "LEFT", 0, 0)
    row.connection:Hide()
    row:SetHeight(22); row:SetPoint("LEFT", 0, 0); row:SetPoint("RIGHT", 0, 0)
    row.highlight = row:CreateTexture(nil, "BACKGROUND"); row.highlight:SetAllPoints(); row.highlight:SetColorTexture(0.25, 0.45, 0.8, 0.35); row.highlight:Hide()
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 3, 0); row.text:SetPoint("RIGHT", -77, 0); row.text:SetJustifyH("LEFT")
    row.text:SetMaxLines(1)
    row.strike = row:CreateTexture(nil, "OVERLAY", nil, 1)
    row.strike:SetPoint("LEFT", row.text, "LEFT", 0, 0)
    row.strike:SetHeight(1)
    row.strike:SetColorTexture(COMPLETED_COLOR, COMPLETED_COLOR, COMPLETED_COLOR, 1)
    row.strike:Hide()
    row.xp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.xp:SetPoint("RIGHT", -3, 0)
    row.optional = createIconTag(row, 133968)
    row.optional.icon:SetTexCoord(0.14, 0.86, 0.14, 0.86)
    row.locationTag = createIconTag(row, "Interface\\Icons\\INV_Misc_Map_01")
    row.locationTag.icon:SetTexCoord(0.09, 0.91, 0.09, 0.91)
    row:SetScript("OnEnter", function(button)
        local hasObjective = false
        for _, objective in ipairs(Anquestry.db:Get(button.questID, "objectivesText") or {}) do
            if type(objective) == "string" and objective ~= "" then
                if not hasObjective then GameTooltip:SetOwner(button, "ANCHOR_RIGHT", 12, -16) end
                GameTooltip:AddLine(objective, 1, 1, 1, true)
                hasObjective = true
            end
        end
        local percentile = button.info.xpPercentile
        if percentile then
            if not hasObjective then GameTooltip:SetOwner(button, "ANCHOR_RIGHT", 12, -16) end
            local fraction = percentile / 100
            GameTooltip:AddLine(("XP Rank: #%d (%.1f%%)"):format(button.info.xpPosition, percentile),
                math.min(1, 2 - 2 * fraction), math.min(1, 2 * fraction), 0.2)
        end
        if hasObjective or percentile then GameTooltip:Show() end
    end)
    row:SetScript("OnLeave", function(button)
        if GameTooltip:IsOwned(button) then GameTooltip:Hide() end
    end)
    row:SetScript("OnClick", function(button)
        self.inspectedQuestID = button.questID
        for _, questRow in ipairs(self.rows) do
            questRow.highlight:SetShown(questRow == button)
        end
        self:ShowWowheadURL(button.questID, button.info.variants)
    end)
    self.rows[index] = row
    return row
end

-- Update the flyout for the current quest and cache state.
function Anquestry.ui:Refresh(selectedID, reason)
    if not self.frame then return end
    local anchor
    if QuestFrame and QuestFrame:IsVisible() then
        anchor = QuestFrame
        selectedID = Anquestry.giverQuestID
    elseif QuestLogFrame and QuestLogFrame:IsVisible() then
        anchor = QuestLogFrame
    elseif QuestMapFrame and QuestMapFrame:IsVisible() then
        anchor = QuestMapFrame
        if QuestMapFrame.DetailsFrame and QuestMapFrame.DetailsFrame:IsVisible() then
            local detailID = QuestMapFrame_GetDetailQuestID and QuestMapFrame_GetDetailQuestID()
            if detailID and detailID > 0 then selectedID = detailID end
        else
            selectedID = nil
        end
    elseif WorldMapFrame and WorldMapFrame:IsVisible() then
        anchor = WorldMapFrame
        selectedID = nil
    end
    if Anquestry.testQuestID then
        selectedID = Anquestry.testQuestID
        anchor = anchor or UIParent
    end
    if anchor and anchor ~= QuestFrame and (not selectedID or selectedID <= 0) then
        selectedID = self.locationQuestID or Anquestry.mapPreviewQuestID or Anquestry:GetTrackedQuestID()
    end
    if not anchor or not selectedID or selectedID <= 0 then
        self.frame:Hide()
        self.anchor = nil
        return
    end
    local inset = 0
    if anchor == QuestMapFrame or anchor == WorldMapFrame then
        local border = WorldMapFrame and WorldMapFrame.BorderFrame
        local close = border and border.CloseButton
        local _, titleBar, relativePoint
        if close then _, titleBar, relativePoint = close:GetPoint(1) end
        -- Leatrix anchors the close button to its title bar in both log views.
        local topFrame = relativePoint == "RIGHT" and titleBar or border
        local top = anchor:GetTop()
        local frameTop = topFrame and topFrame:GetTop()
        if top and frameTop then
            inset = (frameTop * topFrame:GetEffectiveScale() - top * anchor:GetEffectiveScale())
                / self.frame:GetEffectiveScale()
        end
    end
    if self.anchor ~= anchor or self.anchorInset ~= inset then
        self.anchor = anchor
        self.anchorInset = inset
        self.frame:ClearAllPoints()
        if anchor == UIParent then
            self.frame:SetPoint("TOP", UIParent, "CENTER", 0, 160)
        else
            self.frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", anchor == QuestFrame and 2 or 8, inset)
        end
    end
    self.frame:Show()
    syncQuestLogArt(self.frame)
    if Anquestry.disabledReason then
        self.frame.xpTotal:SetText("")
        self.frame.footer:SetText(Anquestry.disabledReason)
        self:FitHeight(6)
        return
    end
    local ready = Anquestry.resolver.chains ~= nil
    self.frame.build:SetShown(not ready and not self.collapsed)
    if not ready then
        self.frame.xpTotal:SetText("")
        if not Anquestry.resolver.building and type(AnquestryChainCache) == "table" then
            self.frame.build:SetText("Rebuild quest chain cache")
        end
        self.frame.footer:SetText("Build the local cache to view quest chains.")
        self:FitHeight(35)
        return
    end
    if self.collapsed then return end
    local showInfo = AnquestrySettings.showQuestInfo ~= false
    if not showInfo and self.urlPopup then self.urlPopup:Hide() end
    local infoVisible = self.urlPopup and self.urlPopup:IsShown()
    if (infoVisible or not showInfo) and selectedID == self.lastSelected and (reason == "QUEST_LOG_UPDATE" or reason == "QuestLog_Update" or reason == "SELECTION" or reason == "SUPER_TRACKING_CHANGED") then return end
    local selectionChanged = selectedID ~= self.lastSelected
    if selectionChanged then
        self.inspectedQuestID = nil
        self.frame.scroll:SetVerticalScroll(0)
    end
    self.lastSelected = selectedID
    local chain = Anquestry.resolver:Resolve(selectedID)
    if #chain == 0 then
        if self.urlPopup then self.urlPopup:Hide() end
        self:DrawLinks({}, {}, 0, 0)
        self.frame.xpTotal:SetText("")
        for _, row in ipairs(self.rows) do row:Hide() end
        self.frame.footer:SetText("No QuestieDB data for this quest.")
        self:FitHeight(6)
        return
    end
    local summary = Anquestry.progress:Summary(chain)
    local inspected
    if self.inspectedQuestID then
        for _, info in ipairs(chain) do
            if info.id == self.inspectedQuestID then inspected = info; break end
        end
    end
    local inspectionLost = self.inspectedQuestID and not inspected
    if inspectionLost then self.inspectedQuestID = nil end
    local highlightedID = self.inspectedQuestID or selectedID
    if selectionChanged or not infoVisible or inspectionLost then
        for _, info in ipairs(chain) do
            if info.id == highlightedID then
                self:ShowWowheadURL(highlightedID, info.variants)
                break
            end
        end
    end
    local groups, offsets, gutter, lanes, joins, offset, links = layoutLinks(chain)
    local nodePositions = self:DrawLinks(groups, offsets, gutter, lanes, joins, chain)
    for i, info in ipairs(chain) do
        local row = self:GetRow(i); row.questID = info.id
        row.info = info
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", self.frame.content, "TOPLEFT", 3 + gutter, -offsets[i])
        row:SetPoint("RIGHT", self.frame.content, "RIGHT")
        local connections = links[i]
        row.connection:ClearAllPoints()
        row.connection:SetPoint("CENTER", row, "LEFT", (nodePositions[i] or gutter - 3) - gutter - 3, 0)
        row.connection:SetShown(connections ~= nil)
        if connections then
            table.sort(connections, function(a, b) return a.index < b.index end)
            local lines, listed = {}, {}
            -- Format each prerequisite group as one requirement.
            local function addRequirements(field, label)
                local names, counts, total = {}, {}, 0
                for _, id in ipairs(Anquestry.db:Get(info.id, field) or {}) do
                    if id > 0 then
                        local title = Anquestry.db:Get(id, "name") or ("Quest " .. id)
                        if not counts[title] then names[#names + 1] = title end
                        counts[title] = (counts[title] or 0) + 1
                        total = total + 1
                        listed[id] = true
                    end
                end
                for index, title in ipairs(names) do
                    if counts[title] > 1 then names[index] = ("%s (%d variants)"):format(title, counts[title]) end
                end
                if total > 0 then
                    lines[#lines + 1] = (total == 1 and "Requires: " or label) .. table.concat(names, ", ")
                end
            end
            addRequirements("preQuestGroup", "Requires all of: ")
            addRequirements("preQuestSingle", "Requires any of: ")
            for _, connection in ipairs(connections) do
                local quest = chain[connection.index]
                if connection.label ~= "Comes after" or not listed[quest.id] then
                    local level = quest.level and quest.level > 0 and ("[" .. quest.level .. "] ") or ""
                    lines[#lines + 1] = connection.label .. ": " .. level .. quest.title
                end
            end
            row.connection.tooltipLines = lines
        end
        info.breadcrumb = Anquestry.db:Get(info.id, "breadcrumbForQuestId")
        local optional = info.breadcrumb and info.breadcrumb > 0
        row.optional:SetShown(optional)
        local done = info.done
        local xpText = info.xp and (tostring(info.xp) .. " XP") or "—"
        local color = done and "878787" or info.xp and XP_GRADE_COLORS[info.xpGrade]
        row.xp:SetText(color and ("|cff" .. color .. xpText .. "|r") or xpText)
        local tagInset = 6 + row.xp:GetStringWidth()
        row.locationTag:SetShown(info.locations ~= nil)
        if info.locations then
            row.locationTag.tooltip = (info.alternatives and "%d alternative starters" or "%d locations"):format(info.locations)
            row.locationTag:ClearAllPoints()
            row.locationTag:SetPoint("RIGHT", -tagInset, 0)
            tagInset = tagInset + row.locationTag:GetWidth() + 3
        end
        if optional then
            local target = Anquestry.db:Get(info.breadcrumb, "name")
            row.optional.tooltip = target and ("Breadcrumb for " .. target) or "Breadcrumb"
            row.optional:ClearAllPoints()
            row.optional:SetPoint("RIGHT", -tagInset, 0)
            tagInset = tagInset + row.optional:GetWidth() + 3
        end
        row.text:SetPoint("RIGHT", -tagInset - 3, 0)
        local level = info.level and info.level > 0 and ("[" .. info.level .. "] ") or ""
        local r, g, b = questColor(info.level)
        if done then r, g, b = COMPLETED_COLOR, COMPLETED_COLOR, COMPLETED_COLOR end
        row.text:SetText(level .. info.title)
        row.text:SetTextColor(r, g, b)
        row.strike:SetShown(done)
        if done then
            row.strike:SetWidth(math.max(1, math.min(row.text:GetStringWidth(), row.text:GetWidth())))
        end
        row.highlight:SetShown(info.id == highlightedID)
        row:Show()
    end
    for i = #chain + 1, #self.rows do self.rows[i]:Hide() end
    self.frame.content:SetHeight(math.max(1, offset))
    local range = summary.minLevel and (summary.minLevel .. "–" .. summary.maxLevel) or "?"
    self.frame.footer:SetText(("%d/%d done  ·  Lv %s"):format(summary.complete, summary.total, range))
    local xp = tostring(summary.remainingXP)
    if summary.unknownXP then xp = summary.remainingXP > 0 and (xp .. "+") or "—" end
    local totalColor = XP_GRADE_COLORS[summary.xpGrade] or XP_GRADE_COLORS["F-"]
    self.frame.xpTotal:SetText("|cff" .. totalColor .. xp .. " XP|r")
    self:FitHeight(offset + 4)
    local scroll = self.frame.scroll
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), scroll:GetVerticalScrollRange()))
end
