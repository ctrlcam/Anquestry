-- Registers Anquestry's settings page and manages its controls and cache rebuild status.

local _, Anquestry = ...
local MAX_XP_WINDOW = 10
local MAX_TRAVEL_DISTANCE = 10000

-- Read the saved level range, defaulting to two levels on either side.
function Anquestry:GetXPWindow()
    local value = tonumber(AnquestrySettings.xpWindow) or 2
    return math.max(0, math.min(MAX_XP_WINDOW, math.floor(value)))
end

-- Read the travel marker threshold in yards, defaulting to 1,000.
function Anquestry:GetTravelThreshold()
    local value = tonumber(AnquestrySettings.travelThreshold) or 1000
    return math.max(0, math.min(MAX_TRAVEL_DISTANCE, math.floor(value / 100 + 0.5) * 100))
end

-- Update both cache controls from the same build state.
function Anquestry:UpdateCacheStatus()
    local busy = self.resolver.building
    local progress = ("Building cache… %d%%"):format(self.cachePercent or 0)
    if self.config then
        local status = self.disabledReason and "Unavailable"
            or busy and progress or self.resolver.chains and "Ready"
            or type(AnquestryChainCache) == "table" and "Needs rebuild" or "Not built"
        self.config.cacheStatus:SetText("Quest chain cache: " .. status)
        self.config.rebuild:SetEnabled(not busy and not self.disabledReason)
    end
    local build = self.ui.frame and self.ui.frame.build
    if build then
        build:SetEnabled(not busy)
        build:SetText(busy and progress or self.resolver.chains and "Rebuild quest chain cache" or "Build quest chain cache")
    end
end

-- Rebuild the quest index in batches and refresh the flyout when it is ready.
function Anquestry:RebuildCache()
    if self.disabledReason or self.resolver.building then return end
    self.cachePercent = 0
    self.resolver:Build(function(done, total)
        local percent = total > 0 and math.floor(done * 100 / total) or 100
        if self.cachePercent == percent then return end
        self.cachePercent = percent
        self:UpdateCacheStatus()
    end, function()
        self:UpdateCacheStatus()
        self:Refresh("CACHE_READY")
    end)
    self:UpdateCacheStatus()
end

-- Show a wrapped description when the pointer rests over a setting.
local function addTooltip(control, title, description)
    control:HookScript("OnEnter", function(owner)
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title)
        GameTooltip:AddLine(description, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    local function hideTooltip(owner)
        if GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
    end
    control:HookScript("OnLeave", hideTooltip)
    control:HookScript("OnHide", hideTooltip)
end

-- Give a text label a hover target that follows its size.
local function addLabelTooltip(panel, label, title, description)
    local target = CreateFrame("Frame", nil, panel)
    target:SetAllPoints(label)
    target:EnableMouseMotion(true)
    addTooltip(target, title, description)
end

-- Create a checkbox that saves its setting immediately.
local function addCheckbox(panel, y, label, key, onChange)
    local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", 18, y)
    check.text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    check.text:SetPoint("LEFT", check, "RIGHT", 4, 0)
    check.text:SetText(label)
    check:SetHitRectInsets(0, -check.text:GetStringWidth() - 4, 0, 0)
    check:SetChecked(AnquestrySettings[key] ~= false)
    check:SetScript("OnClick", function(button)
        AnquestrySettings[key] = button:GetChecked() and true or false
        onChange()
    end)
    return check
end

-- Register the settings page in Blizzard's AddOns tab.
function Anquestry:RegisterConfig()
    if self.configCategory or not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    do
        local panel = CreateFrame("Frame")
        local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 23, -12)
        title:SetText("Anquestry")
        local version = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
        local getMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
        version:SetText("Version: " .. (getMetadata and getMetadata(self.name, "Version") or "Unknown"))

        local tan = CreateColor(0.75, 0.55, 0.34, 0.8)
        local faded = CreateColor(0.75, 0.55, 0.34, 0.08)
        local left = panel:CreateTexture(nil, "ARTWORK")
        left:SetPoint("TOPLEFT", panel, "TOPLEFT", 23, -53)
        left:SetPoint("TOPRIGHT", panel, "TOP", 0, -53)
        left:SetHeight(1)
        left:SetColorTexture(1, 1, 1)
        left:SetGradient("HORIZONTAL", faded, tan)
        local right = panel:CreateTexture(nil, "ARTWORK")
        right:SetPoint("TOPLEFT", left, "TOPRIGHT")
        right:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -23, -53)
        right:SetHeight(1)
        right:SetColorTexture(1, 1, 1)
        right:SetGradient("HORIZONTAL", tan, faded)
        self.config = panel

        local showInfo = addCheckbox(panel, -66, "Show Quest Info", "showQuestInfo", function() self:Refresh("SETTINGS") end)
        addTooltip(showInfo, "Show Quest Info", "Show the Quest Info panel below the quest list.")

        local range = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        range:SetPoint("TOPLEFT", 23, -111)
        local slider = CreateFrame("Slider", "AnquestryXPWindowSlider", panel, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", 23, -136)
        slider:SetSize(320, 16)
        slider:SetMinMaxValues(0, MAX_XP_WINDOW)
        slider:SetValueStep(1)
        slider:SetObeyStepOnDrag(true)
        local value = self:GetXPWindow()
        range:SetText(("XP comparison range: ±%d levels"):format(value))
        slider:SetValue(value)
        local rangeHelp = "Determines the level range to compare against when calculating XP ranking. Set to 0 to only compare with quests of the same level."
        addTooltip(slider, "XP comparison range", rangeHelp)
        addLabelTooltip(panel, range, "XP comparison range", rangeHelp)
        slider:SetScript("OnValueChanged", function(_, newValue)
            newValue = math.floor(newValue + 0.5)
            if newValue == self:GetXPWindow() then return end
            AnquestrySettings.xpWindow = newValue
            range:SetText(("XP comparison range: ±%d levels"):format(newValue))
            self.progress.grades = {}
            self:Refresh("SETTINGS")
        end)

        local travelLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        travelLabel:SetPoint("TOPLEFT", 23, -179)
        travelLabel:SetText(("Long-distance threshold: %d yards"):format(self:GetTravelThreshold()))
        local travelSlider = CreateFrame("Slider", "AnquestryTravelThresholdSlider", panel, "OptionsSliderTemplate")
        travelSlider:SetPoint("TOPLEFT", 23, -204)
        travelSlider:SetSize(320, 16)
        travelSlider:SetMinMaxValues(0, MAX_TRAVEL_DISTANCE)
        travelSlider:SetValueStep(100)
        travelSlider:SetObeyStepOnDrag(true)
        travelSlider:SetValue(self:GetTravelThreshold())
        local travelHelp = "Distance from quest start to turn-in required for the long-distance indicator, in straight-line yards. Set to 0 to disable."
        addTooltip(travelSlider, "Long-distance threshold", travelHelp)
        addLabelTooltip(panel, travelLabel, "Long-distance threshold", travelHelp)
        travelSlider:SetScript("OnValueChanged", function(_, newValue)
            newValue = math.floor(newValue / 100 + 0.5) * 100
            if newValue == self:GetTravelThreshold() then return end
            AnquestrySettings.travelThreshold = newValue
            travelLabel:SetText(("Long-distance threshold: %d yards"):format(newValue))
            self:Refresh("SETTINGS")
        end)

        panel.cacheStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        panel.cacheStatus:SetPoint("TOPLEFT", 23, -247)
        panel.rebuild = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        panel.rebuild:SetSize(146, 24)
        panel.rebuild:SetPoint("TOPLEFT", 23, -273)
        panel.rebuild:SetText("Rebuild Cache")
        panel.rebuild:SetScript("OnClick", function() self:RebuildCache() end)
        local cacheHelp = "Anquestry saves an index of QuestieDB quest links so it can show chains quickly as you select quests. Rebuild Cache regenerates that index from your installed QuestieDB data."
        addLabelTooltip(panel, panel.cacheStatus, "Quest chain cache", cacheHelp)
        addTooltip(panel.rebuild, "Rebuild Cache", cacheHelp)
        panel:SetScript("OnShow", function() self:UpdateCacheStatus() end)
        self.configCategory = Settings.RegisterCanvasLayoutCategory(panel, "Anquestry")
        Settings.RegisterAddOnCategory(self.configCategory)
    end
    self:UpdateCacheStatus()
end

-- Open the AddOns tab directly to Anquestry.
function Anquestry:OpenConfig()
    self:RegisterConfig()
    if self.configCategory then
        Settings.OpenToCategory(self.configCategory:GetID())
    else
        self:Print("The AddOns settings tab is unavailable.")
    end
end
