-- Appends XP ranks to offered quests inside Questie's existing map tooltips.

local _, Anquestry = ...

function Anquestry:HookQuestieTooltips()
    if self.questieTooltipHook or not QuestieLoader or not QuestieLoader.ImportModule then return end
    local ok, layout = pcall(QuestieLoader.ImportModule, QuestieLoader, "TooltipLayout")
    if not ok or not layout or type(layout.Render) ~= "function" then return end
    hooksecurefunc(layout, "Render", function(_, tooltip, rows)
        if self.renderingQuestieRank or self.disabledReason then return end
        local owner = tooltip._owner
        if not owner or not owner.data or owner.data.Type ~= "available"
            or tooltip._showData ~= owner.data or type(tooltip.npcAndObjectOrder) ~= "table" then return end
        local giver, changed = nil, false
        local ranks = {}
        for _, line in ipairs(rows) do
            local text = line.kind == "doubleLine" and line.leftText or line.text
            if tooltip.npcAndObjectOrder[text] then
                giver = tooltip.npcAndObjectOrder[text]
            elseif giver and line.kind == "doubleLine" and not line.anquestryRank then
                for _, quest in pairs(giver) do
                    local id, title = quest.questId, quest.title
                    local active = id and C_QuestLog and C_QuestLog.GetLogIndexForQuestID(id)
                    if id and title and title ~= "" and text:sub(-#title) == title
                        and not (active and active > 0) and self.db:Exists(id) then
                        if ranks[id] == nil then
                            local entry = { id = id, level = self.db:Get(id, "questLevel") }
                            self.progress:Summary({ entry })
                            ranks[id] = self.progress:FormatRank(entry) or false
                        end
                        if ranks[id] then
                            line.rightText = (line.rightText ~= "" and line.rightText .. "  " or "") .. ranks[id]
                            line.anquestryRank, changed = true, true
                        end
                        break
                    end
                end
            end
        end
        if changed then
            -- Reuse Questie's renderer so it measures and wraps the augmented rows itself.
            self.renderingQuestieRank = true
            local rendered, err = pcall(function()
                tooltip:ClearLines()
                layout:Render(tooltip, rows)
            end)
            self.renderingQuestieRank = nil
            if not rendered then self:Print("Questie tooltip ranking: " .. tostring(err)) end
        end
    end)
    self.questieTooltipHook = true
end
