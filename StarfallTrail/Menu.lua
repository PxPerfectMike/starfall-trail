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

local button, panel
local checks = {}

local function PlayClick(on)
	if SOUNDKIT and PlaySound then
		PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
	end
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------

local function PlaceButton()
	local angle = math.rad(ns.Settings.Get("minimapAngle") or 200)
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
	panel:SetSize(math.max(150, width + 52), -y + 10)

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
	AnchorPanel()
	panel:Show()
end

function Menu.Refresh()
	if panel and panel:IsShown() then
		RefreshChecks()
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
	Menu.ApplyButton()
end
