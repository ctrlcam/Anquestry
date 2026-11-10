local addonName, Anquestry = ...
Anquestry.name = addonName
Anquestry.version = "0.1.0"

local frame = CreateFrame("Frame")
Anquestry.eventFrame = frame

-- Write a Anquestry message to the chat window.
function Anquestry:Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffAnquestry:|r " .. message)
end

-- Follow plain clicks on Questie's available-quest map pins.
function Anquestry:HookQuestiePins()
    if self.questiePinHook or not QuestieLoader or not QuestieLoader.ImportModule then return end
    local ok, module = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieFrame")
    local handlers = ok and module and module.private
    if not handlers or type(handlers.OnClick) ~= "function" then return end
    hooksecurefunc(handlers, "OnClick", function(pin, button)
        if button ~= "LeftButton" or pin.miniMapIcon or not pin.UiMapID or IsModifierKeyDown() then return end
        if not WorldMapFrame or not WorldMapFrame:IsVisible() then return end
        if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return end
        local data = pin.data
        if not data or data.Type ~= "available" or type(data.Id) ~= "number" or data.Id <= 0 then return end
        self.mapPreviewQuestID = data.Id
        self:Refresh("QUESTIE_PIN")
    end)
    self.questiePinHook = true
end

-- Get the quest ID selected in Blizzard’s quest log.
function Anquestry:GetSelectedQuestID()
    if C_QuestLog and C_QuestLog.GetSelectedQuest then
        return C_QuestLog.GetSelectedQuest()
    end
    local index = GetQuestLogSelection and GetQuestLogSelection()
    if index and index > 0 and GetQuestLogTitle then
        local _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(index)
        if not isHeader then return questID end
    end
end

-- Read Blizzard's tracked quest offer or active quest.
function Anquestry:GetTrackedQuestID()
    if not C_SuperTrack then return end
    local offerType = Enum and Enum.SuperTrackingMapPinType and Enum.SuperTrackingMapPinType.QuestOffer
    if offerType ~= nil and C_SuperTrack.GetSuperTrackedMapPin then
        local pinType, id = C_SuperTrack.GetSuperTrackedMapPin()
        if pinType == offerType and id and id > 0 then return id end
    end
    if C_SuperTrack.GetSuperTrackedQuestID then
        return C_SuperTrack.GetSuperTrackedQuestID()
    end
end

-- Pass the current selection to the flyout.
function Anquestry:Refresh(reason)
    if not self.ui or self.ui.openingQuestLocation then return end
    if reason == "QUESTIE_PIN" or reason == "BLIZZARD_PIN" then
        self.ui.locationQuestID = nil
    end
    if self.testQuestID and (reason == "SELECTION" or reason == "QUEST_DETAIL" or reason == "QUEST_PROGRESS" or reason == "QUEST_COMPLETE"
        or reason == "SUPER_TRACKING_CHANGED" or reason == "QUESTIE_PIN" or reason == "BLIZZARD_PIN") then
        self.testQuestID = nil
        reason = "TEST_END"
    end
    local questID = self:GetSelectedQuestID()
    self.ui:Refresh(questID, reason)
end

-- Open or clear a manual quest preview for testing.
local function handleSlashCommand(message)
    local command, argument = message:match("^%s*(%S*)%s*(.-)%s*$")
    if command == "" then
        Anquestry:OpenConfig()
        return
    end
    if command:lower() == "test" and argument:lower() == "off" then
        Anquestry.testQuestID = nil
        Anquestry:Refresh("TEST")
        return
    end
    local id = command:lower() == "test" and argument:match("^%d+$") and tonumber(argument)
    if not id or id <= 0 then
        Anquestry:Print("Usage: /anquestry test <questID> or /anquestry test off")
        return
    end
    if not Anquestry.db:Exists(id) then
        Anquestry:Print(("Quest %s was not found in QuestieDB."):format(argument))
        return
    end
    local chains = Anquestry.resolver.chains
    if chains and not chains[id] then
        Anquestry:Print(("Quest %s is excluded by your class or faction filter."):format(argument))
        return
    end
    Anquestry.testQuestID = id
    if Anquestry.ui.frame and Anquestry.ui.collapsed then
        Anquestry.ui:SetCollapsed(false)
    else
        Anquestry:Refresh("TEST")
    end
end

-- Handle WoW events such as login and quest changes.
local function onEvent(_, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == addonName then
            Anquestry:Initialize()
            Anquestry:HookQuestiePins()
        elseif loaded == "Questie" and Anquestry.initialized then
            Anquestry:HookQuestiePins()
        elseif Anquestry.ui and Anquestry.ui.frame then
            Anquestry.ui:HookQuestLog()
            Anquestry:Refresh("SHOW")
        end
        return
    end
    if event == "PLAYER_LOGIN" then
        if not Anquestry.disabledReason then Anquestry.resolver:LoadCache() end
        Anquestry.ui:Initialize()
        Anquestry:RegisterConfig()
        Anquestry:Refresh(event)
    elseif event == "QUEST_DETAIL" or event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
        Anquestry.giverQuestID = GetQuestID and GetQuestID()
        Anquestry:Refresh(event)
    elseif event == "UNIT_AURA" or event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" or event == "SKILL_LINES_CHANGED" then
        Anquestry:Refresh(event)
    elseif event == "QUEST_ACCEPTED" or event == "QUEST_TURNED_IN" or event == "PLAYER_LEVEL_UP" then
        Anquestry:Refresh(event)
    elseif event == "QUEST_LOG_UPDATE" or event == "SUPER_TRACKING_CHANGED" then
        if event == "SUPER_TRACKING_CHANGED" then
            local userWaypoint = C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint()
            if not userWaypoint then Anquestry.mapPreviewQuestID = nil end
        end
        -- The game also uses this for objective changes. UI suppresses work when selection is unchanged.
        Anquestry:Refresh(event)
    end
end

-- Connect to QuestieDB and subscribe to WoW events.
function Anquestry:Initialize()
    if self.initialized then return end
    self.initialized = true
    if type(AnquestrySettings) ~= "table" then AnquestrySettings = {} end
    SLASH_ANQUESTRY1 = "/anquestry"
    SlashCmdList.ANQUESTRY = handleSlashCommand
    local ok, message = self.db:Initialize()
    if not ok then
        self.disabledReason = message
        self:Print(message)
    end
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("QUEST_LOG_UPDATE")
    if C_SuperTrack and (C_SuperTrack.GetSuperTrackedQuestID or C_SuperTrack.GetSuperTrackedMapPin) then
        frame:RegisterEvent("SUPER_TRACKING_CHANGED")
    end
    frame:RegisterEvent("QUEST_ACCEPTED")
    frame:RegisterEvent("QUEST_TURNED_IN")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("SKILL_LINES_CHANGED")
    frame:RegisterUnitEvent("UNIT_AURA", "player")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("QUEST_DETAIL")
    frame:RegisterEvent("QUEST_PROGRESS")
    frame:RegisterEvent("QUEST_COMPLETE")
end

frame:SetScript("OnEvent", onEvent)
frame:RegisterEvent("ADDON_LOADED")
