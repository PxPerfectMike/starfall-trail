-- Starfall Trail: minimap button and the small settings menu it opens.
-- The menu edits the same settings as the slash commands, through ns.Settings.

local _, ns = ...

local Menu = {}
ns.Menu = Menu

local MEDIA = "Interface\\AddOns\\StarfallTrail\\Media\\"
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local BUTTON_RIM = 5 -- how far the button sits outside the minimap edge

local OPTIONS = {
	{ key = "trail", label = "Sparkle trail" },
	{ key = "arrow", label = "Arrow" },
	{ key = "text", label = "Text under the arrow" },
}

-- Which quadrants of each minimap shape are round (true) or square (false),
-- ordered bottom-right, bottom-left, top-right, top-left.
local SHAPES = {
	["ROUND"] = { true, true, true, true },
	["SQUARE"] = { false, false, false, false },
	["CORNER-TOPLEFT"] = { false, false, false, true },
	["CORNER-TOPRIGHT"] = { false, false, true, false },
	["CORNER-BOTTOMLEFT"] = { false, true, false, false },
	["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
	["SIDE-LEFT"] = { false, true, false, true },
	["SIDE-RIGHT"] = { true, false, true, false },
	["SIDE-TOP"] = { false, false, true, true },
	["SIDE-BOTTOM"] = { true, true, false, false },
	["TRICORNER-TOPLEFT"] = { false, true, true, true },
	["TRICORNER-TOPRIGHT"] = { true, false, true, true },
	["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
	["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local ROW_HEIGHT = 20
local MAX_ROWS = 5 -- four party members, plus a followed raid member from another subgroup

local button, panel
local checks = {}
local rows = {}
local followEmpty
local checksBottom, baseWidth

local function PlayClick(on)
	if SOUNDKIT and PlaySound then
		PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
	end
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------

local function PlaceButton()
	local angle = math.rad(ns.Settings.Get("minimapAngle") or 270)
	local x, y = math.cos(angle), math.sin(angle)
	local quadrant = 1
	if x < 0 then
		quadrant = quadrant + 1
	end
	if y > 0 then
		quadrant = quadrant + 2
	end
	local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
	local round = (SHAPES[shape] or SHAPES.ROUND)[quadrant]
	local w = Minimap:GetWidth() / 2 + BUTTON_RIM
	local h = Minimap:GetHeight() / 2 + BUTTON_RIM
	if round then
		x, y = x * w, y * h
	else
		-- Square corner: walk out along the diagonal, then clamp to the edge.
		x = math.max(-w, math.min(x * (math.sqrt(2 * w * w) - 10), w))
		y = math.max(-h, math.min(y * (math.sqrt(2 * h * h) - 10), h))
	end
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function DragUpdate()
	local mx, my = Minimap:GetCenter()
	local cx, cy = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	local angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
	ns.Settings.Set("minimapAngle", angle)
	PlaceButton()
end

local function ShowTooltip(self)
	if not GameTooltip then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("Starfall Trail")
	GameTooltip:AddLine("Click to open settings", 1, 1, 1)
	GameTooltip:AddLine("Drag to move this button", 1, 1, 1)
	GameTooltip:Show()
end

local function CreateButton()
	button = CreateFrame("Button", "StarfallTrailMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("AnyUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(MEDIA .. "icon.png")
	icon:SetSize(21, 21)
	icon:SetPoint("TOPLEFT", 6, -5)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", function()
		Menu.Toggle()
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", DragUpdate)
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
end

---------------------------------------------------------------------------
-- Settings menu
---------------------------------------------------------------------------

local function RefreshChecks()
	for key, check in pairs(checks) do
		check:SetChecked(ns.Settings.Get(key) and true or false)
	end
end

-- The "Follow" list: your party by name. Clicking a name leads the arrow to that person; clicking
-- the highlighted name goes back to quests.
local function RefreshFollow()
	local list = ns.Friend.Roster("party")
	local guid, name, class = ns.Friend.Get()
	local listed = false
	for _, entry in ipairs(list) do
		listed = listed or entry.guid == guid
	end
	if guid and not listed then
		-- Chosen by right-click or slash command from another raid subgroup: shown so it can be cleared here.
		table.insert(list, 1, { guid = guid, name = name, class = class })
	end
	local width = baseWidth
	for i, row in ipairs(rows) do
		local entry = list[i]
		row.entry = entry
		if entry then
			row.text:SetText(ns.Friend.ColoredName(entry.name, entry.class))
			row.selected:SetShown(entry.guid == guid)
			width = math.max(width, row.text:GetStringWidth() + 36)
			row:Show()
		else
			row:Hide()
		end
	end
	followEmpty:SetShown(#list == 0)
	local shown = math.max(1, math.min(#list, MAX_ROWS))
	panel:SetSize(width, -checksBottom + 24 + shown * ROW_HEIGHT + 10)
	for _, row in ipairs(rows) do
		row:SetWidth(width - 16)
	end
end

local function CreateFollowList()
	local title = panel:CreateFontString(nil, "OVERLAY")
	title:SetFont(FONT, 12, "OUTLINE")
	title:SetTextColor(1, 0.82, 0.3)
	title:SetText("Follow a party member")
	title:SetPoint("TOPLEFT", 12, checksBottom - 6)
	baseWidth = math.max(baseWidth, title:GetStringWidth() + 24)

	followEmpty = panel:CreateFontString(nil, "OVERLAY")
	followEmpty:SetFont(FONT, 12, "")
	followEmpty:SetTextColor(0.6, 0.6, 0.6)
	followEmpty:SetText("Not in a party")
	followEmpty:SetPoint("TOPLEFT", 16, checksBottom - 28)

	for i = 1, MAX_ROWS do
		local row = CreateFrame("Button", nil, panel)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 8, checksBottom - 24 - (i - 1) * ROW_HEIGHT)

		row.selected = row:CreateTexture(nil, "BACKGROUND")
		row.selected:SetAllPoints()
		row.selected:SetColorTexture(1, 0.82, 0.3, 0.28)

		local hover = row:CreateTexture(nil, "HIGHLIGHT")
		hover:SetAllPoints()
		hover:SetColorTexture(1, 1, 1, 0.12)

		row.text = row:CreateFontString(nil, "OVERLAY")
		row.text:SetFont(FONT, 12, "")
		row.text:SetPoint("LEFT", 8, 0)

		row:SetScript("OnClick", function(self)
			local entry = self.entry
			if not entry then
				return
			end
			local following = ns.Friend.Get() == entry.guid
			if following then
				ns.Friend.Clear()
			else
				ns.Friend.Set(entry.guid, entry.name, entry.class)
			end
			PlayClick(not following)
		end)
		row:Hide()
		rows[i] = row
	end
end

-- "Starfall Trail: follow" in the right-click menu of group members. This file's `Menu` is the
-- addon's own table, so the game's menu API is reached through _G. Clients without it skip this.
local function AddUnitMenus()
	local api = _G.Menu
	if not (type(api) == "table" and api.ModifyMenu) then
		return
	end
	local function Find(context)
		local roster = ns.Friend.Roster("group")
		if context.unit and UnitExists(context.unit) then
			local guid = UnitGUID(context.unit)
			for _, entry in ipairs(roster) do
				if entry.guid == guid then
					return entry
				end
			end
			return nil
		end
		return context.name and ns.Friend.MatchName(roster, context.name) or nil
	end
	local function Add(_, root, context)
		-- Unit data can be hidden in combat; then the entry is simply left out.
		local ok, entry = pcall(Find, context or {})
		if not (ok and entry) then
			return
		end
		local following = ns.Friend.Get() == entry.guid
		root:CreateDivider()
		root:CreateButton(following and "Starfall Trail: stop following" or "Starfall Trail: follow", function()
			if following then
				ns.Friend.Clear()
			else
				ns.Friend.Set(entry.guid, entry.name, entry.class)
			end
		end)
	end
	for _, tag in ipairs({ "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID", "MENU_UNIT_PLAYER" }) do
		pcall(api.ModifyMenu, tag, Add)
	end
end

-- Opens toward the middle of the screen from wherever the button sits.
local function AnchorPanel()
	panel:ClearAllPoints()
	local bx, by = button:GetCenter()
	local sx, sy = UIParent:GetCenter()
	local scale = button:GetEffectiveScale() / UIParent:GetEffectiveScale()
	bx, by = bx * scale, by * scale
	local vertical = by > sy and "TOP" or "BOTTOM"
	local horizontal = bx > sx and "RIGHT" or "LEFT"
	local otherHorizontal = horizontal == "RIGHT" and "LEFT" or "RIGHT"
	panel:SetPoint(vertical .. horizontal, button, vertical .. otherHorizontal, horizontal == "RIGHT" and -2 or 2, 0)
end

local function CreatePanel()
	panel = CreateFrame("Frame", "StarfallTrailSettingsMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	panel:SetFrameStrata("DIALOG")
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:Hide()
	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		panel:SetBackdropColor(0.04, 0.05, 0.08, 0.94)
		panel:SetBackdropBorderColor(0.75, 0.62, 0.32, 1)
	end

	local title = panel:CreateFontString(nil, "OVERLAY")
	title:SetFont(FONT, 13, "OUTLINE")
	title:SetTextColor(1, 0.82, 0.3)
	title:SetText("Starfall Trail")
	title:SetPoint("TOPLEFT", 12, -10)

	local width = 0
	local y = -30
	for _, option in ipairs(OPTIONS) do
		local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		check:SetSize(24, 24)
		check:SetPoint("TOPLEFT", 8, y)

		local label = check:CreateFontString(nil, "OVERLAY")
		label:SetFont(FONT, 12, "")
		label:SetTextColor(1, 1, 1)
		label:SetText(option.label)
		label:SetPoint("LEFT", check, "RIGHT", 2, 1)
		-- Clicking the words toggles too.
		check:SetHitRectInsets(0, -(label:GetStringWidth() + 6), 0, 0)
		width = math.max(width, label:GetStringWidth())

		check:SetScript("OnClick", function(self)
			local on = self:GetChecked() and true or false
			ns.Settings.Set(option.key, on)
			PlayClick(on)
		end)
		checks[option.key] = check
		y = y - 24
	end
	checksBottom, baseWidth = y, math.max(150, width + 52)
	CreateFollowList()
	RefreshFollow()

	-- Escape closes it, like other game windows.
	if UISpecialFrames then
		table.insert(UISpecialFrames, "StarfallTrailSettingsMenu")
	end

	-- A click anywhere else closes it.
	panel:SetScript("OnEvent", function(self)
		if self:IsShown() and not self:IsMouseOver() and not button:IsMouseOver() then
			self:Hide()
		end
	end)
	panel:SetScript("OnShow", function(self)
		pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN")
	end)
	panel:SetScript("OnHide", function(self)
		self:UnregisterAllEvents()
	end)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function Menu.Toggle()
	if panel:IsShown() then
		panel:Hide()
		return
	end
	RefreshChecks()
	RefreshFollow()
	AnchorPanel()
	panel:Show()
end

function Menu.Refresh()
	if panel and panel:IsShown() then
		RefreshChecks()
		RefreshFollow()
	end
end

function Menu.ApplyButton()
	if not button then
		return
	end
	button:SetShown(not ns.Settings.Get("minimapHidden"))
	PlaceButton()
	Menu.Refresh()
end

function Menu.Init()
	if button or not Minimap then
		return
	end
	CreateButton()
	CreatePanel()
	AddUnitMenus()
	Menu.ApplyButton()
end
