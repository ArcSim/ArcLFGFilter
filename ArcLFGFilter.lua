local ADDON, NS = ...

-- Arc LFG Filter - an "Advanced Filter" button beside the refresh button of WoW
-- Forever's Looking For Group window (Blizzard_GroupFinder_VanillaStyle,
-- browse tab). Its menu holds three independent filters:
--   Show        - players and groups / players only / groups only
--   Players     - Tank / Healer / DPS: solo players who signed up for a
--                 ticked role (the role icons Blizzard shows), plus a Class
--                 submenu (every class the game has, with counts) and a typed
--                 Minimum level; role, class and level combine, so DPS + Mage
--                 = DPS mages
--   Groups      - "has a spot for me": groups with an open slot for a role
--                 YOU are queued as (C_LFGListRoles.GetRoles, the same source
--                 Blizzard uses to rank groups) via the *_REMAINING counts;
--                 plus "Hide groups with": drop any group that has a member
--                 of a ticked class (every member is read)
-- Nothing set = nothing changes (default OFF). Your own listing always stays.
--
-- HOW (v6, 2026-09-21): BLIZZARD'S LIST IS NEVER TOUCHED. While a filter is
-- on, the addon draws its OWN list over Blizzard's (same background art, row
-- layout, fonts and role display) holding only the matching listings, in
-- Blizzard's order, with its own selection, tooltip, right-click menu and
-- Send Message / Group Invite buttons laid over Blizzard's. Filter off,
-- searching, no results, or data it cannot read: its list hides and
-- Blizzard's is simply there.
-- WHY: v2-v5 filtered by editing Blizzard's results table (a post-hook on
-- LFGBrowseUtil_SortSearchResults) and redrew with
-- LFGBrowseFrame:UpdateResultList(). Any addon write or call there leaves
-- Blizzard's list - its ScrollBox, data provider and rows - stored as
-- addon-touched for the rest of the session. In a dungeon or in combat
-- Forever makes listing data secret to touched code, so every background
-- search then errored inside Blizzard's own row code ("attempt to compare
-- field 'numMembers' (a secret number value, while execution tainted by
-- 'ArcLFGFilter')", Blizzard_LFGVanilla_Browse.lua:366). Everything this
-- addon does to Blizzard's LFG frames now: two read-only hooksecurefunc
-- post-hooks (UpdateResults, C_PartyInfo.InviteUnit), reading fields, and
-- anchoring its own frames to theirs.
--
-- INVITE WHISPER (default OFF): inviting a listed player from this window
-- also whispers them your message, "Inviting you to run {dungeon}" unless you
-- write your own. A hooksecurefunc post-hook on C_PartyInfo.InviteUnit, which
-- both of Blizzard's invite paths and this addon's own Group Invite call, so
-- the invite itself always runs first and untouched. It only answers an
-- invite while the browse window is open and the name is a solo player in the
-- results, never repeats a player within a minute, and stands aside in chat
-- lockdown. The menu holds the switch; the message lives in a small settings
-- window (/arclfg) built from the Arc theme (ALF_Theme.lua, a verbatim copy
-- of ArcDisplay's AD_Theme.lua).
--
-- DEBUG: /arclfg debug opens a copyable log panel (probe-GUI rule) and
-- /arclfg snap adds a snapshot of every listing. It records setup, every
-- Blizzard list rebuild, every rebuild of the addon's own list, and every
-- invite whisper. Every logged value goes through S(), so secret values print
-- as <secret> instead of throwing.
--
-- SAVED: only the invite whisper settings (ArcLFGFilterDB, account-wide).
-- The filter itself still resets every session on purpose. Forever's
-- SavedVariables loading bug can hand the addon an empty table for a whole
-- session; the whisper is then off with the default message until the saved
-- file loads again, and a session like that saves the defaults over it. The
-- debug log lives only in the panel, never in a saved file.

local issecret = issecretvalue or function() return false end

local ROLES = {
	{ key = "TANK",    solo = "tank",   label = "Tank" },
	{ key = "HEALER",  solo = "healer", label = "Healer" },
	{ key = "DAMAGER", solo = "dps",    label = "DPS" },
}

local SHOW_MODES = {
	{ key = "both",    label = "Players and groups" },
	{ key = "players", label = "Players only" },
	{ key = "groups",  label = "Groups only" },
}

local FILTER_ATLAS   = "ui-questtrackerbutton-filter"
local FALLBACK_ATLAS = "groupfinder-icon-role-large-tank"
local STATUS_WIDEST  = "Paused: roles hidden" -- sizes the menu's status line
local MAX_LOG_LINES  = 800

local DEFAULT_MESSAGE  = "Inviting you to run {dungeon}"
local FALLBACK_DUNGEON = "a dungeon" -- {dungeon} when the listing names none
local SAMPLE_DUNGEON   = "Deadmines" -- settings preview when nothing is picked
local SAMPLE_NAME      = "Rowan"     -- settings preview for {name}
local MAX_TEMPLATE     = 200         -- leaves room for the tokens in a whisper
local MAX_WHISPER      = 255         -- chat's limit, in bytes
local WHISPER_REPEAT   = 60          -- seconds before the same player is whispered again

-- The addon's own list mirrors Blizzard's row template (Mainline
-- Blizzard_LFGVanilla_Browse.xml): 48px rows, 36px category headers, names
-- capped at 228px, and Blizzard's role display template on the right.
local ROW_H, HEADER_H, NAME_MAX = 48, 36, 228
local DISPLAY_TEMPLATE = "LFGVanillaListGroupDataDisplayTemplate"
local DELISTED_COLOR   = { r = 0.3, g = 0.3, b = 0.3 }

local active = {}                   -- [role key] = true while that role is ticked
local classActive = {}              -- [classFile] = true while that class is ticked
local groupExclude = {}             -- [classFile] = true: hide groups with that class in them
local minLevel                      -- nil, or the lowest level a solo player may be
local showMode = "both"             -- "both", "players" or "groups"
local openSpotOnly = false          -- groups: only those with a slot for my role
local shownCount, totalCount = 0, 0 -- result of the last rebuild of our list
local pausedReason                  -- nil, "lockdown" or "hidden"
local lockSeen = "no"               -- last lockdown reading: "no", "yes" or "secret"
local db                            -- ArcLFGFilterDB once this addon has loaded
local lastWhisper = {}              -- [name] = GetTime() of the last invite whisper
local filterButton, panel, settingsWindow, settingsPage, whisperBox
local view                          -- the addon's own list over Blizzard's
local viewRows, viewHeaders = {}, {} -- pooled row and header buttons
local selectedID                    -- the listing selected in our list
local collapsed = {}                -- [category] = true while its header is shut
local rebuildQueued = false
local logLines, logBatching = {}, false

-- Extension points for a companion addon, which reads this addon's table via
-- C_AddOns.GetAddOnLocalTable (the toc opts in with AllowAddOnTableAccess):
-- functions(root) run while the menu is built, and functions(tooltip) that
-- add lines to the button tooltip. Empty for everyone else. The read-only
-- API they use is set at the bottom of this file.
NS.menuExtras = NS.menuExtras or {}
NS.tooltipExtras = NS.tooltipExtras or {}

-------------------------------------------------------------------------------
-- Debug log
-------------------------------------------------------------------------------

-- Every logged value goes through here: a secret must never reach tostring.
local function S(v)
	if issecret(v) then return "<secret>" end
	return tostring(v)
end

-- A value, or nil when it is secret.
local function Plain(v)
	if issecret(v) then return nil end
	return v
end

local function RefreshPanel()
	if not (panel and panel:IsShown()) then return end
	panel.Edit:SetText(table.concat(logLines, "\n"))
	C_Timer.After(0, function()
		panel.Scroll:SetVerticalScroll(panel.Scroll:GetVerticalScrollRange())
	end)
end

local function Log(text)
	logLines[#logLines + 1] = date("%H:%M:%S") .. "  " .. text
	if #logLines > MAX_LOG_LINES then table.remove(logLines, 1) end
	if not logBatching then RefreshPanel() end
end

-------------------------------------------------------------------------------
-- Filter state helpers
-------------------------------------------------------------------------------

local function AnyRoleTicked()
	return active.TANK or active.HEALER or active.DAMAGER
end

local function AnyClassTicked()
	return next(classActive) ~= nil
end

local function AnyGroupExclusion()
	return next(groupExclude) ~= nil
end

local function FilterActive()
	return showMode ~= "both" or openSpotOnly or AnyRoleTicked() or AnyClassTicked() or AnyGroupExclusion()
		or minLevel ~= nil
end

-- A rule about which PLAYERS match (role, class or level), as opposed to the
-- show mode or group rules.
local function HasPlayerRules()
	return (AnyRoleTicked() or AnyClassTicked() or minLevel ~= nil) and true or false
end

local function ActiveNames()
	local names = {}
	for _, role in ipairs(ROLES) do
		if active[role.key] then names[#names + 1] = role.label end
	end
	return table.concat(names, ", ")
end

-- Blizzard's class order (CLASS_SORT_ORDER) where it has the class, else by name.
local function SortClasses(list)
	local rank = {}
	if CLASS_SORT_ORDER then
		for i, classFile in ipairs(CLASS_SORT_ORDER) do rank[classFile] = i end
	end
	table.sort(list, function(a, b)
		local ra, rb = rank[a] or 99, rank[b] or 99
		if ra ~= rb then return ra < rb end
		return a < b
	end)
	return list
end

local function ClassLabel(classFile)
	local name = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
	return name or (classFile:sub(1, 1) .. classFile:sub(2):lower())
end

-- The classes in a set (classActive or groupExclude), in class order, joined.
local function ClassNames(set)
	local list = {}
	for classFile in pairs(set) do list[#list + 1] = classFile end
	SortClasses(list)
	for i, classFile in ipairs(list) do list[i] = ClassLabel(classFile) end
	return table.concat(list, ", ")
end

-- The roles you are queued / listed as: { tank, healer, dps }, or nil when
-- unavailable or secret.
local function MyRoles()
	local roles = C_LFGListRoles and C_LFGListRoles.GetRoles and C_LFGListRoles.GetRoles()
	if roles == nil or issecret(roles) then return nil end
	return roles
end

local function MyRolesText()
	local roles = MyRoles()
	if not roles then return "unknown" end
	local names = {}
	for _, role in ipairs(ROLES) do
		local on = roles[role.solo]
		if not issecret(on) and on then names[#names + 1] = role.label end
	end
	if #names == 0 then return "no role set" end
	return table.concat(names, "/")
end

local function FilterSummary()
	local parts = {}
	if showMode == "players" then
		parts[#parts + 1] = "players only"
	elseif showMode == "groups" then
		parts[#parts + 1] = "groups only"
	end
	if showMode ~= "groups" then
		if AnyRoleTicked() then parts[#parts + 1] = "players: " .. ActiveNames() end
		if AnyClassTicked() then parts[#parts + 1] = "class: " .. ClassNames(classActive) end
		if minLevel then parts[#parts + 1] = "level " .. minLevel .. "+" end
	end
	if showMode ~= "players" then
		if openSpotOnly then parts[#parts + 1] = "groups: spot for " .. MyRolesText() end
		if AnyGroupExclusion() then parts[#parts + 1] = "groups without: " .. ClassNames(groupExclude) end
	end
	if #parts == 0 then return "none" end
	return table.concat(parts, "; ")
end

-- Never boolean-test a secret: an unreadable answer is reported as "secret".
local function LockState()
	if not (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) then return "no" end
	local isRestricted = C_ChatInfo.InChatMessagingLockdown()
	if issecret(isRestricted) then return "secret" end
	return isRestricted and "yes" or "no"
end

-- true = keep, false = drop, nil = unreadable (our list then steps aside).
local function Verdict(resultID)
	local info = C_LFGList.GetSearchResultInfo(resultID)
	if not info then return true end
	if issecret(info) then return nil end
	local hasSelf, numMembers = info.hasSelf, info.numMembers
	if issecret(hasSelf) or issecret(numMembers) then return nil end
	if hasSelf then return true end

	if numMembers == 1 then
		if showMode == "groups" then return false end
		local wantRoles, wantClasses = AnyRoleTicked(), AnyClassTicked()
		if not (wantRoles or wantClasses or minLevel) then return true end
		local member = C_LFGList.GetSearchResultPlayerInfo(resultID, 1)
		if not member then return false end
		if issecret(member) then return nil end
		if minLevel then
			local level = member.level
			if issecret(level) then return nil end
			if not level or level < minLevel then return false end
		end
		if wantClasses then
			local classFile = member.classFilename
			if issecret(classFile) then return nil end
			if not (classFile and classActive[classFile]) then return false end
		end
		if not wantRoles then return true end
		local roles = member.lfgRoles
		if not roles then return false end
		if issecret(roles) then return nil end
		for _, role in ipairs(ROLES) do
			if active[role.key] then
				local can = roles[role.solo]
				if issecret(can) then return nil end
				if can then return true end
			end
		end
		return false
	end

	if showMode == "players" then return false end
	-- "Hide groups with": any member of a ticked class drops the group; a
	-- member the game gives no info for simply cannot count against it
	if AnyGroupExclusion() then
		for m = 1, numMembers do
			local member = C_LFGList.GetSearchResultPlayerInfo(resultID, m)
			if member then
				if issecret(member) then return nil end
				local classFile = member.classFilename
				if issecret(classFile) then return nil end
				if classFile and groupExclude[classFile] then return false end
			end
		end
	end
	if not openSpotOnly then return true end
	local mine = MyRoles()
	if not mine then return nil end
	local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
	if not counts then return true end
	if issecret(counts) then return nil end
	for _, role in ipairs(ROLES) do
		local wanted = mine[role.solo]
		if issecret(wanted) then return nil end
		if wanted then
			local open = counts[role.key .. "_REMAINING"]
			if issecret(open) then return nil end
			if open == nil then return true end -- count missing: can't judge, keep
			if open > 0 then return true end
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- Invite whisper (the only saved setting)
-------------------------------------------------------------------------------

local function WhisperOn()
	return db ~= nil and db.inviteWhisper == true
end

local function SetWhisperOn(on)
	if not db then return end
	db.inviteWhisper = on and true or nil
	Log("settings: invite whisper -> " .. (on and "ON" or "off"))
end

-- The message exactly as saved; "" = not set, so the settings field shows
-- the default as a hint instead of pre-filling it.
local function TypedMessage()
	local text = db and db.inviteMessage
	if type(text) == "string" then return text end
	return ""
end

local function SetTypedMessage(text)
	if not db then return end
	text = (text or ""):match("^%s*(.-)%s*$")
	db.inviteMessage = (text ~= "") and text or nil
end

local function MessageTemplate()
	local text = TypedMessage()
	if text == "" then return DEFAULT_MESSAGE end
	return text
end

-- Runs once this addon's saved file has had its chance to load.
local function LoadSettings()
	local found = type(ArcLFGFilterDB) == "table"
	if not found then ArcLFGFilterDB = {} end
	db = ArcLFGFilterDB
	Log(string.format("settings: %s - invite whisper %s, message %s",
		found and "loaded from the saved file" or "nothing saved yet, defaults",
		WhisperOn() and "ON" or "off", (TypedMessage() ~= "") and "custom" or "default"))
end

-- On Forever other players' names come in two parts ("First Last"); {name}
-- is the first.
local function FirstName(name)
	return name:match("^[^%s%-]+") or name
end

-- Chat refuses "|" (it starts an escape code) and line breaks, and takes at
-- most 255 bytes: cut there without splitting a letter.
local function ChatSafe(text)
	text = text:gsub("|", ""):gsub("[\r\n]", " ")
	if #text > MAX_WHISPER then
		local cut = MAX_WHISPER
		local nextByte = text:byte(cut + 1)
		while cut > 0 and nextByte and nextByte >= 0x80 and nextByte < 0xC0 do
			cut = cut - 1
			nextByte = text:byte(cut + 1)
		end
		text = text:sub(1, cut)
	end
	return text
end

-- Fills {dungeon} and {name} (any case; anything else in braces stays as
-- typed), then makes the result chat-safe.
local function BuildMessage(template, dungeon, name)
	local text = template:gsub("{(%a+)}", function(key)
		key = key:lower()
		if key == "dungeon" then return dungeon end
		if key == "name" then return name end
	end)
	return ChatSafe(text)
end

-- Blizzard's own naming rule (LFGUtil_GetActivityInfoName): the short name
-- when there is one, else the full name.
local function ActivityName(activityID)
	if issecret(activityID) or activityID == nil then return nil end
	local info = C_LFGList.GetActivityInfoTable(activityID)
	if not info or issecret(info) then return nil end
	local short, full = info.shortName, info.fullName
	if issecret(short) or issecret(full) then return nil end
	if short and short ~= "" then return short end
	if full and full ~= "" then return full end
	return nil
end

-- A readable list of activity IDs, or nil.
local function IDList(list)
	if issecret(list) or type(list) ~= "table" then return nil end
	return list
end

local function ListHas(list, value)
	for _, v in ipairs(list) do
		if not issecret(v) and v == value then return true end
	end
	return false
end

local function FirstActivityName(list)
	list = IDList(list)
	if not list then return nil end
	for _, id in ipairs(list) do
		local name = ActivityName(id)
		if name then return name end
	end
	return nil
end

local function MyActivityIDs()
	local mine = C_LFGList.GetActiveEntryInfo()
	if not mine or issecret(mine) then return nil end
	return IDList(mine.activityIDs)
end

local function PickedActivityIDs()
	local dropdown = LFGBrowseFrame and LFGBrowseFrame.ActivityDropdown
	if not dropdown then return nil end
	return IDList(dropdown.selectedValues)
end

-- First of the listing's activities that is also in `prefer`, named.
local function SharedName(activityIDs, prefer)
	if not prefer then return nil end
	for _, id in ipairs(activityIDs) do
		if not issecret(id) and ListHas(prefer, id) then
			local name = ActivityName(id)
			if name then return name end
		end
	end
	return nil
end

-- The dungeon an invite is for: one the listing shares with your own
-- listing, else one picked in the browse window's activity filter, else the
-- listing's first - how Blizzard names the row, plus the filter.
local function DungeonFor(activityIDs)
	activityIDs = IDList(activityIDs)
	if not activityIDs then return nil end
	return SharedName(activityIDs, MyActivityIDs())
		or SharedName(activityIDs, PickedActivityIDs())
		or FirstActivityName(activityIDs)
end

-- The settings preview names what you are set up for right now.
local function PreviewDungeon()
	return FirstActivityName(MyActivityIDs()) or FirstActivityName(PickedActivityIDs()) or SAMPLE_DUNGEON
end

-- The solo listing (search result info) of the invited name, or nil. A fresh
-- GetFilteredSearchResults call is the unfiltered list.
local function SoloListingOf(name)
	local _, results = C_LFGList.GetFilteredSearchResults()
	if not results or issecret(results) then return nil end
	for i = 1, #results do
		local id = results[i]
		if not issecret(id) then
			local info = C_LFGList.GetSearchResultInfo(id)
			if info and not issecret(info) then
				local leader, members = info.leaderName, info.numMembers
				if not (issecret(leader) or issecret(members)) and members == 1 and leader == name then
					return info
				end
			end
		end
	end
	return nil
end

local function SendWhisper(text, target)
	if C_ChatInfo and C_ChatInfo.SendChatMessage then
		C_ChatInfo.SendChatMessage(text, "WHISPER", nil, target)
	else
		SendChatMessage(text, "WHISPER", nil, target)
	end
end

-- Whispers the invite message to a listed solo player just invited. From a
-- click (the InviteUnit hook) it needs the whisper switch on and the browse
-- window open; `auto` (an invite made through a companion addon) skips both -
-- such an invite must always explain itself - but every other gate
-- (lockdown, listed solo player, the one-minute repeat guard) still applies,
-- so the hook and the companion firing for the same invite whisper once.
local function WhisperInvitee(name, auto)
	if not auto then
		if not WhisperOn() then return end
		local frame = LFGBrowseFrame
		if not (frame and frame:IsVisible()) then return end
	end
	if issecret(name) or type(name) ~= "string" then
		Log("invite: name unreadable - no whisper")
		return
	end
	lockSeen = LockState()
	if lockSeen ~= "no" then
		Log("invite: " .. name .. " - lockdown=" .. lockSeen .. ", no whisper")
		return
	end
	local listing = SoloListingOf(name)
	if not listing then
		Log("invite: " .. name .. " - not a listed player, no whisper")
		return
	end
	local now = GetTime()
	local last = lastWhisper[name]
	if last and now - last < WHISPER_REPEAT then
		Log(string.format("invite: %s - whispered %ds ago, not again", name, math.floor(now - last)))
		return
	end
	local text = BuildMessage(MessageTemplate(), DungeonFor(listing.activityIDs) or FALLBACK_DUNGEON, FirstName(name))
	if not text:match("%S") then
		Log("invite: " .. name .. " - message is empty, no whisper")
		return
	end
	lastWhisper[name] = now
	SendWhisper(text, name)
	Log("invite: whispered " .. name .. ": " .. text)
end

-- Post-hook on C_PartyInfo.InviteUnit: the invite has already run (and
-- Blizzard's stays secure); this runs right after it, inside the same click.
local function OnInviteUnit(name)
	WhisperInvitee(name, false)
end

-------------------------------------------------------------------------------
-- Snapshot: what the addon can read for every listing, filter or not
-------------------------------------------------------------------------------

local function VerdictText(resultID)
	if not FilterActive() then return "n/a (no filter)" end
	local verdict = Verdict(resultID)
	if verdict == nil then return "UNREADABLE" end
	return verdict and "keep" or "drop"
end

local function DescribeResult(index, resultID)
	if issecret(resultID) then
		Log(string.format("  #%d id=<secret>", index))
		return
	end
	local parts = { string.format("  #%d id=%s", index, S(resultID)) }

	local info = C_LFGList.GetSearchResultInfo(resultID)
	if info == nil then
		parts[#parts + 1] = "info=nil"
	elseif issecret(info) then
		parts[#parts + 1] = "info=<secret table>"
	else
		parts[#parts + 1] = "name=" .. S(info.leaderName)
		parts[#parts + 1] = "members=" .. S(info.numMembers)
		parts[#parts + 1] = "self=" .. S(info.hasSelf)
		parts[#parts + 1] = "delisted=" .. S(info.isDelisted)
	end

	local member = C_LFGList.GetSearchResultPlayerInfo(resultID, 1)
	if member == nil then
		parts[#parts + 1] = "player=nil"
	elseif issecret(member) then
		parts[#parts + 1] = "player=<secret table>"
	else
		local roles = member.lfgRoles
		if roles == nil then
			parts[#parts + 1] = "lfgRoles=nil"
		elseif issecret(roles) then
			parts[#parts + 1] = "lfgRoles=<secret table>"
		else
			parts[#parts + 1] = string.format("roles T=%s H=%s D=%s", S(roles.tank), S(roles.healer), S(roles.dps))
		end
		parts[#parts + 1] = "class=" .. S(member.classFilename) .. " lvl=" .. S(member.level)
	end

	local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
	if counts == nil then
		parts[#parts + 1] = "counts=nil"
	elseif issecret(counts) then
		parts[#parts + 1] = "counts=<secret table>"
	else
		parts[#parts + 1] = string.format("counts T=%s H=%s D=%s open T=%s H=%s D=%s",
			S(counts.TANK), S(counts.HEALER), S(counts.DAMAGER),
			S(counts.TANK_REMAINING), S(counts.HEALER_REMAINING), S(counts.DAMAGER_REMAINING))
	end

	-- every member's class of a group (what "Hide groups with" reads)
	local members = info and not issecret(info) and Plain(info.numMembers)
	if members and members > 1 then
		local classes = {}
		for m = 1, members do
			local p = C_LFGList.GetSearchResultPlayerInfo(resultID, m)
			classes[m] = (p == nil and "nil") or (issecret(p) and "<secret>") or S(p.classFilename)
		end
		parts[#parts + 1] = "member classes=" .. table.concat(classes, ",")
	end

	parts[#parts + 1] = "verdict=" .. VerdictText(resultID)
	Log(table.concat(parts, "  "))
end

local function Snapshot(label)
	logBatching = true
	local frame = LFGBrowseFrame
	Log("---- SNAPSHOT (" .. label .. ") ----")
	Log(string.format("LFG window: loaded=%s shown=%s searching=%s  filter button=%s",
		S(frame ~= nil), S(frame and frame:IsShown()), S(frame and frame.searching), S(filterButton ~= nil)))
	local lockRaw = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
	local inInstance, instanceType = IsInInstance()
	Log(string.format("InChatMessagingLockdown=%s  issecretvalue exists=%s  inInstance=%s (%s)  inCombat=%s",
		S(lockRaw), S(issecretvalue ~= nil), S(inInstance), S(instanceType), S(InCombatLockdown())))
	Log(string.format("filter: %s  my roles: %s  our list: shown=%s, %s of %s listings, selected=%s, pause=%s",
		FilterSummary(), MyRolesText(), S(view ~= nil and view:IsShown()), S(shownCount), S(totalCount),
		S(selectedID), S(pausedReason)))
	Log(string.format("invite whisper: %s  message: %s  settings table: %s",
		WhisperOn() and "ON" or "off", MessageTemplate(), S(db ~= nil)))
	local total, results = C_LFGList.GetFilteredSearchResults()
	if issecret(results) then
		Log("GetFilteredSearchResults: total=" .. S(total) .. "  results=<secret table>")
	elseif results then
		Log(string.format("GetFilteredSearchResults: total=%s listed=%d", S(total), #results))
		for i = 1, #results do DescribeResult(i, results[i]) end
	else
		Log("GetFilteredSearchResults: total=" .. S(total) .. "  results=nil")
	end
	if frame and frame.results and not issecret(frame.results) then
		Log(string.format("Blizzard list table right now: %d rows", #frame.results))
	end
	Log("---- end snapshot ----")
	logBatching = false
	RefreshPanel()
end

-------------------------------------------------------------------------------
-- Debug panel (movable, copyable, never prints to chat)
-------------------------------------------------------------------------------

local function MakePanelButton(parent, text, x, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(100, 22)
	button:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", x, 12)
	button:SetText(text)
	button:SetScript("OnClick", onClick)
	return button
end

local function BuildPanel()
	local frame = CreateFrame("Frame", "ArcLFGFilterDebug", UIParent, "BackdropTemplate")
	frame:SetSize(620, 440)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	frame:SetBackdropColor(0.05, 0.07, 0.11, 0.96)
	frame:SetBackdropBorderColor(0.2, 0.75, 0.9, 1)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 14, -10)
	title:SetText("Arc LFG Filter - Debug log")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -32)
	scroll:SetPoint("BOTTOMRIGHT", -32, 44)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(620 - 12 - 32)
	edit:SetScript("OnEscapePressed", edit.ClearFocus)
	scroll:SetScrollChild(edit)

	frame.Scroll, frame.Edit = scroll, edit

	MakePanelButton(frame, "Select All", 12, function()
		edit:SetFocus()
		edit:HighlightText()
	end)
	MakePanelButton(frame, "Snapshot", 118, function() Snapshot("button") end)
	MakePanelButton(frame, "Refresh", 224, RefreshPanel)
	MakePanelButton(frame, "Clear", 330, function()
		wipe(logLines)
		RefreshPanel()
	end)

	frame:SetScript("OnShow", RefreshPanel)
	panel = frame
end

local function ShowPanel()
	if not panel then BuildPanel() end
	panel:Show()
	RefreshPanel()
end

-------------------------------------------------------------------------------
-- Settings window (Arc theme: ALF_Theme.lua)
-------------------------------------------------------------------------------

local function RefreshSettings()
	if settingsWindow and settingsWindow:IsShown() then NS.AT.LayoutPage(settingsPage) end
end

local function ToggleWhisper()
	SetWhisperOn(not WhisperOn())
	RefreshSettings()
end

local function BuildSettings()
	local AT = NS.AT
	local COL, LAY = AT.COL, AT.LAY
	local win = AT.CreateWindow("ArcLFGFilterSettings", {
		title = "|cff3fc9f2Arc|r|cffd5e2f2 LFG Filter|r",
		version = C_AddOns.GetAddOnMetadata(ADDON, "Version"),
		w = 460, h = 290, minW = 400, minH = 270,
	})
	local pg = AT.NewPage(win)
	pg:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -40)
	pg:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 40)
	pg:Show()

	AT.Section(pg, "Invite whisper")
	AT.RowToggle(pg, "Whisper players when I invite them", WhisperOn, SetWhisperOn, nil,
		"When you invite a player from the Looking For Group list, they also get your message as a whisper. Off until you turn it on.")

	AT.Section(pg, "Message")
	local input = AT.RowInput(pg, "Message", TypedMessage, function(text)
		SetTypedMessage(text)
		RefreshSettings()
	end, nil, "Leave it empty to send the default message.", DEFAULT_MESSAGE, true)
	-- a whole sentence, not a short value: the field runs from the control
	-- column to the row's end (the engine's _colFill) instead of 160px
	input._colFill = true
	input._colCtrl:SetMaxLetters(MAX_TEMPLATE)

	-- live preview, re-read on every layout; grows like RowDesc when it wraps
	local preview = AT.AddRow(pg, LAY.descH)
	local fs = preview:CreateFontString(nil, "OVERLAY")
	fs:SetFont(STANDARD_TEXT_FONT, 11, "")
	fs:SetPoint("TOPLEFT", 10, -2)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(true)
	fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
	preview._sync = function()
		fs:SetText("Preview:  |cfff2f7ff" .. BuildMessage(MessageTemplate(), PreviewDungeon(), SAMPLE_NAME) .. "|r")
		local width = pg:GetWidth() or 0
		if width < 60 then return end
		fs:SetWidth(width - 36)
		local want = math.max(LAY.descH, math.floor((fs:GetStringHeight() or 12) + 8))
		if preview._h ~= want then
			preview._h = want
			preview:SetHeight(want)
		end
	end

	AT.RowDesc(pg, "{dungeon} becomes the dungeon and {name} the player's first name.")

	AT.AddDiscordFooter(win, "ArcLFGFilterDiscordCopy")
	-- CreateWindow owns OnShow via SetScript: hook it, never replace it
	win:HookScript("OnShow", function() AT.LayoutPage(pg) end)
	settingsWindow, settingsPage = win, pg
end

local function ShowSettings()
	if not settingsWindow then BuildSettings() end
	settingsWindow:Show()
	NS.AT.LayoutPage(settingsPage)
	-- the first pass runs before the anchors resolve; measure again next frame
	C_Timer.After(0, RefreshSettings)
end

-------------------------------------------------------------------------------
-- Whisper box: Send Message for the addon's own list. Opening Blizzard's chat
-- box from addon code would leave the chat frames addon-touched (the same
-- trap as the list), so the message is typed here and sent as a whisper.
-------------------------------------------------------------------------------

local function OpenWhisperBox(name)
	if not name then return end
	local AT = NS.AT
	local COL = AT.COL
	if not whisperBox then
		local win = AT.CreateWindow("ArcLFGFilterWhisper", {
			title = "|cff3fc9f2Arc|r|cffd5e2f2 Send Message|r",
			w = 380, h = 116, minW = 380, minH = 116, resizable = false,
		})
		local label = win:CreateFontString(nil, "OVERLAY")
		label:SetFont(STANDARD_TEXT_FONT, 12, "")
		label:SetPoint("TOPLEFT", 14, -42)
		label:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])

		local box = CreateFrame("EditBox", nil, win, "BackdropTemplate")
		box:SetPoint("TOPLEFT", 12, -62)
		box:SetPoint("TOPRIGHT", -104, -62)
		box:SetHeight(22)
		AT.Skin(box, COL.well)
		box:SetFont(STANDARD_TEXT_FONT, 12, "")
		box:SetTextInsets(6, 6, 0, 0)
		box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
		box:SetAutoFocus(false)
		box:SetMaxLetters(MAX_WHISPER)

		local hint = win:CreateFontString(nil, "OVERLAY")
		hint:SetFont(STANDARD_TEXT_FONT, 10, "")
		hint:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -6)
		hint:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
		hint:SetText("Enter sends, Esc closes.")

		local send = AT.MakeSmallButton(win, "Send", 84)
		send:SetPoint("LEFT", box, "RIGHT", 8, 0)

		local function Send()
			local text = ChatSafe(((box:GetText() or ""):match("^%s*(.-)%s*$")))
			if text == "" then return end
			lockSeen = LockState()
			if lockSeen ~= "no" then
				hint:SetText("The game is blocking addon messages right now.")
				Log("whisper box: lockdown=" .. lockSeen .. " - not sent")
				return
			end
			SendWhisper(text, win.target)
			Log("whisper box: sent to " .. win.target)
			box:SetText("")
			win:Hide()
		end
		box:SetScript("OnEnterPressed", Send)
		box:SetScript("OnEscapePressed", function() win:Hide() end)
		send:SetScript("OnClick", Send)
		win:HookScript("OnHide", function() box:ClearFocus() end)
		win.Label, win.Box, win.Hint = label, box, hint
		whisperBox = win
	end
	whisperBox.target = name
	whisperBox.Label:SetText("To " .. name)
	whisperBox.Hint:SetText("Enter sends, Esc closes.")
	whisperBox:Show()
	whisperBox.Box:SetFocus()
end

-------------------------------------------------------------------------------
-- Popup menus: this addon's own, drawn with Forever's menu art
-------------------------------------------------------------------------------
-- Blizzard's menu system (MenuUtil) is shared by every menu in the game.
-- Opening one from addon code left it running on this addon's taint, and
-- Blizzard's own LFG Category dropdown then could not search:
-- "[ADDON_ACTION_BLOCKED] AddOn 'ArcLFGFilter' tried to call the protected
-- function 'Search()'" from Menu.lua Pick (2026-09-21). So the funnel and row
-- menus are drawn here, on this addon's frames, and never go near it. The
-- look copies Blizzard's MenuStyle1 (Mainline MenuTemplates / MenuVariants):
-- common-dropdown-bg at .925 alpha overhanging 10/3, insets 8/8/8/15, 20px
-- rows, 13px tooltip dividers, square and radial ticks with the yellow marks,
-- the chat expand arrow for submenus and the quest title highlight.
--
-- The builder mirrors the subset of Blizzard's menu description API this
-- addon (and its companion) uses - CreateTitle / CreateButton / CreateCheckbox
-- / CreateRadio / CreateDivider, SetResponse / SetEnabled / AddInitializer -
-- so the generators read the same. Defaults as Blizzard: checkboxes stay
-- open and refresh, radios and buttons close unless SetResponse(REFRESH).
-- One kind of our own, CreateInput: a label with a small typed box (the
-- Minimum level, Arc 2026-09-21: "I want this to be a user input").

local REFRESH = (MenuResponse and MenuResponse.Refresh) or "refresh"
local POPUP_ROW_H, POPUP_DIVIDER_H = 20, 13
local POPUP_INSET_L, POPUP_INSET_T, POPUP_INSET_R, POPUP_INSET_B, POPUP_PAD_W = 8, 8, 8, 15, 20
local POPUP_INPUT_H, POPUP_INPUT_W, POPUP_INPUT_GAP = 24, 36, 12

local PopupNode = {}
PopupNode.__index = PopupNode

local function NewPopupNode(kind, text)
	return setmetatable({ kind = kind, text = text, children = {}, enabled = true, inits = {} }, PopupNode)
end

function PopupNode:Add(kind, text)
	local node = NewPopupNode(kind, text)
	self.children[#self.children + 1] = node
	return node
end

function PopupNode:CreateTitle(text)
	return self:Add("title", text)
end

function PopupNode:CreateDivider()
	return self:Add("divider")
end

function PopupNode:CreateButton(text, callback, data)
	local node = self:Add("button", text)
	node.callback, node.data = callback, data
	return node
end

function PopupNode:CreateCheckbox(text, isSelected, setSelected, data)
	local node = self:Add("checkbox", text)
	node.isSelected, node.setSelected, node.data = isSelected, setSelected, data
	node.response = REFRESH
	return node
end

function PopupNode:CreateRadio(text, isSelected, setSelected, data)
	local node = self:Add("radio", text)
	node.isSelected, node.setSelected, node.data = isSelected, setSelected, data
	return node
end

-- A label with a typed box on the right. get() gives the text to show and
-- set(text) runs on every keystroke; the menu stays open and refreshes, and
-- the box keeps what is being typed until it loses focus. opts: numeric,
-- maxLetters, width, placeholder (shown while the box is empty).
function PopupNode:CreateInput(text, get, set, opts)
	local node = self:Add("input", text)
	node.get, node.set, node.opts = get, set, opts or {}
	return node
end

function PopupNode:SetResponse(response)
	self.response = response
end

function PopupNode:SetEnabled(on)
	self.enabled = on and true or false
end

function PopupNode:AddInitializer(fn)
	self.inits[#self.inits + 1] = fn
end

local popup = { panels = {}, openPath = {} } -- panels[level], 1 = the root
local hookedOwners = setmetatable({}, { __mode = "k" })
local RefreshPopup, ClosePopup -- defined below; rows call them

local function TextWidth(fs)
	return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0
end

local function MouseOverPopup()
	for _, panel in pairs(popup.panels) do
		if panel:IsShown() and panel:IsMouseOver() then return true end
	end
	return false
end

-- Hides the panels from `level` down.
local function ClosePopupFrom(level)
	for l, panel in pairs(popup.panels) do
		if l >= level then panel:Hide() end
	end
end

local function PopupPanel(level)
	local panel = popup.panels[level]
	if panel then return panel end
	panel = CreateFrame("Frame", level == 1 and "ArcLFGFilterPopup" or nil, UIParent)
	panel:SetFrameStrata("FULLSCREEN_DIALOG")
	panel:SetToplevel(true)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel.level = level
	local bg = panel:CreateTexture(nil, "BACKGROUND")
	bg:SetAtlas("common-dropdown-bg")
	bg:SetPoint("TOPLEFT", -10, 3)
	bg:SetPoint("BOTTOMRIGHT", 10, -3)
	bg:SetAlpha(0.925)
	panel.rows = {}
	panel:Hide()
	if level == 1 then
		tinsert(UISpecialFrames, "ArcLFGFilterPopup") -- Escape closes it
		-- a click anywhere else closes it, like Blizzard's menus
		panel:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
		panel:SetScript("OnHide", function(self)
			self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
			ClosePopupFrom(2)
			popup.generator, popup.owner = nil, nil
		end)
		panel:SetScript("OnEvent", function()
			if MouseOverPopup() then return end
			if popup.owner and popup.owner:IsMouseOver() then return end -- its click toggles
			ClosePopup()
		end)
	end
	popup.panels[level] = panel
	return panel
end

local PopupRowEnter, PopupRowLeave, PopupRowClick -- defined below

local function PopupRow(panel, i)
	local row = panel.rows[i]
	if row then return row end
	row = CreateFrame("Button", nil, panel)
	row.panel = panel
	row:SetHeight(POPUP_ROW_H)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.highlight = row:CreateTexture(nil, "BACKGROUND")
	row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	row.highlight:SetBlendMode("ADD")
	row.highlight:SetAllPoints()
	row.highlight:Hide()
	row.tick = row:CreateTexture(nil, "ARTWORK")
	row.mark = row:CreateTexture(nil, "ARTWORK", nil, 1)
	row.fontString = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.fontString:SetJustifyH("LEFT")
	row.fontString:SetWordWrap(false)
	row.arrow = row:CreateTexture(nil, "ARTWORK")
	row.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
	row.arrow:SetSize(16, 16)
	row.arrow:SetPoint("RIGHT")
	row.divider = row:CreateTexture(nil, "ARTWORK")
	row.divider:SetTexture("Interface\\Common\\UI-TooltipDivider-Transparent")
	row.divider:SetPoint("LEFT")
	row.divider:SetPoint("RIGHT")
	row.divider:SetHeight(POPUP_DIVIDER_H)
	row:SetScript("OnEnter", PopupRowEnter)
	row:SetScript("OnLeave", PopupRowLeave)
	row:SetScript("OnClick", PopupRowClick)
	panel.rows[i] = row
	return row
end

-- The box of an input entry, made on first use and kept with its row. It is
-- a plain EditBox wearing the game's input border (the atlases of Blizzard's
-- InputBoxVisualTemplate), so no Blizzard template or script runs on it.
local function PopupInput(row)
	local box = row.input
	if box then return box end
	box = CreateFrame("EditBox", nil, row)
	box.row = row
	box:SetSize(POPUP_INPUT_W, 20)
	box:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlight")
	box:SetJustifyH("CENTER")
	box:SetTextInsets(2, 2, 0, 0)
	local left = box:CreateTexture(nil, "BACKGROUND")
	left:SetAtlas("common-search-border-left")
	left:SetSize(8, 20)
	left:SetPoint("LEFT")
	local right = box:CreateTexture(nil, "BACKGROUND")
	right:SetAtlas("common-search-border-right")
	right:SetSize(8, 20)
	right:SetPoint("RIGHT")
	local middle = box:CreateTexture(nil, "BACKGROUND")
	middle:SetAtlas("common-search-border-middle")
	middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
	middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
	box.placeholder = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	box.placeholder:SetPoint("CENTER")
	-- the mouse can reach the box without crossing its label: resting on it
	-- still closes a submenu opened from another entry
	box:SetScript("OnEnter", function(self) PopupRowEnter(self.row) end)
	box:SetScript("OnLeave", function(self) PopupRowLeave(self.row) end)
	box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	box:SetScript("OnEditFocusLost", function(self)
		self:HighlightText(0, 0)
		-- show what is in effect ("07" becomes 7, a cleared box the placeholder)
		local node = self.row.node
		if node and node.kind == "input" and node.get then self:SetText(node.get() or "") end
		self.placeholder:SetShown(self:GetText() == "")
	end)
	box:SetScript("OnTextChanged", function(self, userInput)
		self.placeholder:SetShown(self:GetText() == "")
		if not userInput then return end
		local node = self.row.node
		if not (node and node.kind == "input" and node.enabled and node.set) then return end
		node.set(self:GetText())
		RefreshPopup()
	end)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		ClosePopup()
	end)
	-- the keyboard is never kept once the menu is gone
	box:SetScript("OnHide", function(self) self:ClearFocus() end)
	row.input = box
	return box
end

-- Draws one entry; returns the width its content needs.
local function FillPopupRow(row, node)
	row.node = node
	local kind = node.kind
	row.tick:Hide()
	row.mark:Hide()
	row.arrow:Hide()
	row.divider:Hide()
	row.highlight:Hide()
	if row.input and kind ~= "input" then row.input:Hide() end
	if kind == "divider" then
		row:SetHeight(POPUP_DIVIDER_H)
		row.fontString:Hide()
		row.divider:Show()
		row:EnableMouse(false)
		return 0
	end
	row:SetHeight(POPUP_ROW_H)
	row:EnableMouse(kind ~= "title")
	local font = "GameFontHighlight"
	if kind == "title" then font = "GameFontNormal" elseif not node.enabled then font = "GameFontDisable" end
	row.fontString:SetFontObject(font)
	row.fontString:SetText(node.text or "")
	row.fontString:ClearAllPoints()
	row.fontString:Show()
	local width = TextWidth(row.fontString)
	if kind == "checkbox" or kind == "radio" then
		local on = node.isSelected and node.isSelected(node.data)
		row.tick:ClearAllPoints()
		row.mark:ClearAllPoints()
		if kind == "checkbox" then
			row.tick:SetAtlas("common-dropdown-ticksquare", true)
			row.tick:SetPoint("LEFT")
			row.mark:SetAtlas("common-dropdown-icon-checkmark-yellow", true)
			row.mark:SetPoint("CENTER", row.tick, "CENTER", 2, 1)
			row.fontString:SetPoint("LEFT", row.tick, "RIGHT", 7, 1)
			width = width + (row.tick:GetWidth() or 0) + 7
		else
			row.tick:SetAtlas("common-dropdown-tickradial", true)
			row.tick:SetPoint("LEFT", -3, 0)
			row.mark:SetAtlas("common-dropdown-icon-radialtick-yellow", true)
			row.mark:SetPoint("TOPLEFT", row.tick, "TOPLEFT")
			row.fontString:SetPoint("LEFT", row.tick, "RIGHT", 1, 0)
			width = width + (row.tick:GetWidth() or 0) - 2
		end
		row.tick:Show()
		row.mark:SetShown(on and true or false)
	elseif kind == "input" then
		local opts, box = node.opts, PopupInput(row)
		row:SetHeight(POPUP_INPUT_H)
		row.fontString:SetPoint("LEFT")
		box:SetWidth(opts.width or POPUP_INPUT_W)
		box:SetNumeric(opts.numeric and true or false)
		box:SetMaxLetters(opts.maxLetters or 0)
		box:SetEnabled(node.enabled)
		box.placeholder:SetText(opts.placeholder or "")
		-- a refresh while typing must not overwrite the typing
		if not box:HasFocus() then box:SetText(node.get and node.get() or "") end
		box.placeholder:SetShown(box:GetText() == "")
		box:Show()
		width = width + POPUP_INPUT_GAP + (opts.width or POPUP_INPUT_W)
	else
		row.fontString:SetPoint("LEFT")
	end
	if #node.children > 0 then
		row.arrow:Show()
		width = width + 16
	end
	for _, init in ipairs(node.inits) do init(row, node) end
	return width
end

-- Lays out one panel: the root at the click, a submenu beside its row.
local function RenderPopupPanel(level, node, anchorRow)
	local panel = PopupPanel(level)
	panel.node = node
	local y, widest, count = -POPUP_INSET_T, 50, 0
	for i, child in ipairs(node.children) do
		local row = PopupRow(panel, i)
		local width = FillPopupRow(row, child)
		row.index = i
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", panel, "TOPLEFT", POPUP_INSET_L, y)
		row:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -POPUP_INSET_R, y)
		row:Show()
		y = y - row:GetHeight()
		if width > widest then widest = width end
		count = i
	end
	for i = count + 1, #panel.rows do
		panel.rows[i]:Hide()
		panel.rows[i].node = nil
	end
	panel:SetSize(widest + POPUP_PAD_W + POPUP_INSET_L + POPUP_INSET_R, -y + POPUP_INSET_B)
	panel:ClearAllPoints()
	if anchorRow then
		panel:SetPoint("TOPLEFT", anchorRow, "TOPRIGHT", POPUP_INSET_R + 10, POPUP_INSET_T)
	else
		panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", popup.x or 0, popup.y or 0)
	end
	panel:Show()
	panel:Raise()
	return panel
end

local function OpenPopupSubmenu(row)
	local panel = row.panel
	local level = panel.level
	ClosePopupFrom(level + 2)
	for l = level, #popup.openPath do popup.openPath[l] = nil end
	popup.openPath[level] = row.index
	RenderPopupPanel(level + 1, row.node, row)
end

function PopupRowEnter(row)
	local node = row.node
	if not node or node.kind == "title" or node.kind == "divider" then return end
	if node.enabled and node.kind ~= "input" then row.highlight:Show() end
	if #node.children > 0 then
		OpenPopupSubmenu(row)
	else
		-- resting on a plain entry closes a submenu opened from this panel
		local level = row.panel.level
		ClosePopupFrom(level + 1)
		for l = level, #popup.openPath do popup.openPath[l] = nil end
	end
end

function PopupRowLeave(row)
	row.highlight:Hide()
end

function PopupRowClick(row)
	local node = row.node
	if not node or not node.enabled or node.kind == "title" or node.kind == "divider" then return end
	if #node.children > 0 then
		OpenPopupSubmenu(row)
		return
	end
	local kind = node.kind
	if kind == "input" then
		-- a click on the label types into the box
		if row.input then row.input:SetFocus() end
		return
	end
	if kind == "checkbox" and node.isSelected and node.isSelected(node.data) then
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
	else
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	end
	if kind == "checkbox" or kind == "radio" then
		if node.setSelected then node.setSelected(node.data) end
	elseif node.callback then
		node.callback(node.data)
	end
	if node.response == REFRESH then RefreshPopup() else ClosePopup() end
end

-- Rebuilds every open panel from the generator, keeping open submenus open.
function RefreshPopup()
	if not popup.generator then return end
	local root = NewPopupNode("root")
	popup.generator(popup.owner, root)
	local node, panel = root, RenderPopupPanel(1, root, nil)
	for level = 1, #popup.openPath do
		local child = node.children[popup.openPath[level]]
		if not (child and #child.children > 0) then
			ClosePopupFrom(level + 1)
			for l = level, #popup.openPath do popup.openPath[l] = nil end
			break
		end
		panel = RenderPopupPanel(level + 1, child, panel.rows[popup.openPath[level]])
		node = child
	end
end

function ClosePopup()
	ClosePopupFrom(1)
	popup.generator, popup.owner = nil, nil
	wipe(popup.openPath)
end

local function PopupOpenFor(owner)
	return popup.owner == owner and popup.panels[1] ~= nil and popup.panels[1]:IsShown()
end

-- Opens a menu at the cursor. `generator(owner, root)` fills it.
local function OpenPopup(owner, generator)
	ClosePopup()
	popup.owner, popup.generator = owner, generator
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale() or 1
	popup.x, popup.y = x / scale, y / scale
	PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	RefreshPopup()
	-- a menu never outlives what it belongs to (the window closing, a row
	-- being recycled)
	if owner and owner.HookScript and not hookedOwners[owner] then
		hookedOwners[owner] = true
		owner:HookScript("OnHide", function(self)
			if popup.owner == self then ClosePopup() end
		end)
	end
end
NS.OpenPopup = OpenPopup

-------------------------------------------------------------------------------
-- Button badge and menu status
-------------------------------------------------------------------------------

local function StatusText()
	if not FilterActive() then return "Showing everyone" end
	if pausedReason then return STATUS_WIDEST end
	return string.format("Showing %d of %d", shownCount, totalCount)
end

local function UpdateButton()
	if not filterButton then return end
	local badge = filterButton.Badge
	if FilterActive() then
		filterButton:LockHighlight()
		if pausedReason then
			badge:SetText("!")
			badge:SetTextColor(1, 0.3, 0.3)
		else
			badge:SetText(tostring(shownCount))
			badge:SetTextColor(1, 1, 1)
		end
		badge:Show()
	else
		filterButton:UnlockHighlight()
		badge:Hide()
	end
end

-------------------------------------------------------------------------------
-- The addon's own list, over Blizzard's while a filter is on
-------------------------------------------------------------------------------

local RebuildView -- defined below; the category headers call it

local function CanInvite(entry)
	if not (entry and entry.name and entry.solo) or entry.delisted or entry.self then return false end
	return (not IsInGroup() or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) and true or false
end

local function InviteEntry(entry)
	if not CanInvite(entry) then return end
	Log("our list: invite " .. entry.name)
	C_PartyInfo.InviteUnit(entry.name)
end

local function SelectedEntry()
	if not selectedID then return nil end
	for _, row in ipairs(viewRows) do
		if row:IsShown() and row.entry and row.entry.id == selectedID then return row.entry end
	end
	return nil
end

local function PaintSelection()
	for _, row in ipairs(viewRows) do
		row.Selected:SetShown(row:IsShown() and row.entry ~= nil and row.entry.id == selectedID)
	end
end

local function UpdateViewButtons()
	if not view then return end
	local entry = SelectedEntry()
	view.SendButton:SetEnabled(entry ~= nil and entry.name ~= nil)
	view.InviteButton:SetEnabled(CanInvite(entry))
end

local function ShowRowMenu(row)
	local entry = row.entry
	NS.OpenPopup(row, function(owner, root)
		root:CreateTitle(entry.name)
		root:CreateButton(SEND_MESSAGE or "Send Message", function() OpenWhisperBox(entry.name) end)
		local invite = root:CreateButton(GROUP_INVITE or "Group Invite", function() InviteEntry(entry) end)
		invite:SetEnabled(CanInvite(entry))
	end)
end

local function RowOnClick(row, button)
	local entry = row.entry
	if not entry or entry.delisted or entry.self then return end
	PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	if button == "RightButton" then
		ShowRowMenu(row)
		return
	end
	if selectedID == entry.id then selectedID = nil else selectedID = entry.id end
	PaintSelection()
	UpdateViewButtons()
end

local function TableReadable(t)
	for _, v in pairs(t) do
		if issecret(v) then return false end
	end
	return true
end

-- The hover card. Blizzard's LFGBrowseSearchEntryTooltip is theirs: filling
-- it from here would leave it addon-touched, so this is GameTooltip with the
-- same content in the same order - delisted / new-player notes, the members
-- (role icon, class-coloured name, spec when the game gives one, level; the
-- leader marked with the crown), the comment, the member count, the
-- activities (yours in blue) and the bosses already defeated. Every field
-- is secret-guarded.
local ROLE_ATLAS = {
	TANK    = "groupfinder-icon-role-large-tank",
	HEALER  = "groupfinder-icon-role-large-heal",
	DAMAGER = "groupfinder-icon-role-large-dps",
}
local LEADER_ICON     = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:14:14|t"
local MEMBER_LIST_MAX = 10 -- Blizzard lists the members only up to this size

local function Icon(atlas)
	return string.format("|A:%s:14:14|a", atlas)
end

local function ClassColored(name, classFile)
	local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if c and c.colorStr then return "|c" .. c.colorStr .. name .. "|r" end
	return name
end

-- One member: role icon + name (+ crown) on the left, spec + level right.
local function AddMemberLine(member, isLeader)
	if not member or issecret(member) then return end
	local name = Plain(member.name)
	if not name then return end
	local classFile, level = Plain(member.classFilename), Plain(member.level)
	local role, spec = Plain(member.assignedRole), Plain(member.specName)
	local left = ClassColored(name, classFile)
	if role and ROLE_ATLAS[role] then left = Icon(ROLE_ATLAS[role]) .. " " .. left end
	if isLeader then left = left .. " " .. LEADER_ICON end
	local right = level and ((LEVEL_ABBR or "Lvl") .. " " .. level) or ""
	if spec and spec ~= "" then right = spec .. "   " .. right end
	GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 0.65, 0.65, 0.65)
end

local function RowOnEnter(row)
	local entry = row.entry
	if not entry then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	local info = LockState() == "no" and C_LFGList.GetSearchResultInfo(entry.id)
	if not info or issecret(info) then
		GameTooltip:SetText(entry.name or "?", 1, 1, 1)
		GameTooltip:AddLine("Details are hidden right now.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
		return
	end
	local color = NORMAL_FONT_COLOR
	local leader = C_LFGList.GetSearchResultLeaderInfo(entry.id)
	local leaderClass = leader and not issecret(leader) and Plain(leader.classFilename)
	if leaderClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[leaderClass] then color = RAID_CLASS_COLORS[leaderClass] end
	GameTooltip:SetText(entry.name or "?", color.r, color.g, color.b)
	if entry.delisted then GameTooltip:AddLine(LFG_LIST_ENTRY_DELISTED or "Delisted", 1, 0.2, 0.2) end
	if Plain(info.newPlayerFriendly) then
		GameTooltip:AddLine(Icon("newplayerchat-chaticon-newcomer") .. " "
			.. (LFG_LIST_NEW_PLAYER_FRIENDLY_HEADER or "New Player Friendly"), 0.1, 1, 0.1)
	end

	local members = Plain(info.numMembers)
	if members == 1 then
		local member = C_LFGList.GetSearchResultPlayerInfo(entry.id, 1)
		if member and not issecret(member) then
			local level, classFile = Plain(member.level), Plain(member.classFilename)
			local spec = Plain(member.specName)
			if level and classFile then
				local line = string.format("%s %s %s", LEVEL or "Level", level, ClassLabel(classFile))
				if spec and spec ~= "" then line = line .. " (" .. spec .. ")" end
				GameTooltip:AddLine(line, 1, 1, 1)
			end
			local roles = member.lfgRoles
			if roles and not issecret(roles) then
				local parts = {}
				for _, role in ipairs(ROLES) do
					local on = roles[role.solo]
					if not issecret(on) and on then parts[#parts + 1] = Icon(ROLE_ATLAS[role.key]) .. " " .. role.label end
				end
				if #parts > 0 then GameTooltip:AddLine("Roles:  " .. table.concat(parts, "  "), 0.9, 0.9, 0.9) end
			end
		end
	elseif members and members <= MEMBER_LIST_MAX then
		-- the leader first, then everyone else in the game's order
		local list = {}
		for m = 1, members do
			local member = C_LFGList.GetSearchResultPlayerInfo(entry.id, m)
			if member and not issecret(member) and Plain(member.isLeader) then
				table.insert(list, 1, member)
			elseif member then
				list[#list + 1] = member
			end
		end
		for i, member in ipairs(list) do
			AddMemberLine(member, i == 1 and not issecret(member) and Plain(member.isLeader))
		end
	end

	local comment = Plain(info.comment)
	if comment and comment ~= "" then
		GameTooltip:AddLine(LFG_LIST_COMMENT_FORMAT and string.format(LFG_LIST_COMMENT_FORMAT, comment) or comment, 0.8, 0.8, 0.8, true)
	end

	if members and members > 1 then
		local counts = C_LFGList.GetSearchResultMemberCounts(entry.id)
		local readable = counts and not issecret(counts)
		local tank = readable and Plain(counts.TANK)
		local healer = readable and Plain(counts.HEALER)
		local dps = readable and Plain(counts.DAMAGER)
		if tank and healer and dps then
			GameTooltip:AddLine(string.format("%d players: %d tank, %d healer, %d DPS", members, tank, healer, dps), 1, 1, 1)
		else
			GameTooltip:AddLine(string.format("%d players", members), 1, 1, 1)
		end
	end

	local ids = IDList(info.activityIDs)
	if ids then
		local mine = MyActivityIDs()
		for _, id in ipairs(ids) do
			local name = ActivityName(id)
			if name then
				local c = (mine and ListHas(mine, id)) and BRIGHTBLUE_FONT_COLOR or GRAY_FONT_COLOR
				GameTooltip:AddLine(name, c.r, c.g, c.b)
			end
		end
		-- bosses this group already killed (Blizzard shows them for a single dungeon)
		if #ids == 1 and C_LFGList.GetSearchResultEncounterInfo then
			local killed = C_LFGList.GetSearchResultEncounterInfo(entry.id)
			if killed and not issecret(killed) and #killed > 0 then
				GameTooltip:AddLine(LFG_LIST_BOSSES_DEFEATED or "Bosses Defeated:", 1, 0.82, 0)
				for _, boss in ipairs(killed) do
					if not issecret(boss) then GameTooltip:AddLine(boss, 1, 0.1, 0.1) end
				end
			end
		end
	end
	GameTooltip:Show()
end

local function RowOnLeave()
	GameTooltip:Hide()
end

local function NewRow()
	local row = CreateFrame("Button", nil, view.Content)
	row:SetHeight(ROW_H)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetColorTexture(1, 1, 1, 0.04)
	bg:SetPoint("TOPLEFT", 3, -2)
	bg:SetPoint("BOTTOMRIGHT", -3, 0)

	row.PartyIcon = row:CreateTexture(nil, "ARTWORK")
	row.PartyIcon:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
	row.PartyIcon:SetSize(24, 24)
	row.PartyIcon:SetPoint("TOPLEFT", 8, -4)

	row.Name = row:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	row.Name:SetJustifyH("LEFT")
	row.Name:SetMaxLines(1)
	row.Name:SetHeight(14)

	row.Level = row:CreateFontString(nil, "ARTWORK", "GameFontDisableLeft")
	row.Level:SetMaxLines(1)
	row.Level:SetHeight(14)
	row.Level:SetPoint("BOTTOMLEFT", row.Name, "BOTTOMRIGHT", 4, 0)

	row.ClassIcon = row:CreateTexture(nil, "ARTWORK")
	row.ClassIcon:SetSize(24, 24)
	row.ClassIcon:SetPoint("BOTTOMLEFT", row.Level, "BOTTOMRIGHT", 3, -5)

	row.NewPlayer = row:CreateTexture(nil, "ARTWORK")
	row.NewPlayer:SetAtlas("newplayerchat-chaticon-newcomer")
	row.NewPlayer:SetSize(20, 20)
	row.NewPlayer:Hide()

	row.Activity = row:CreateFontString(nil, "ARTWORK", "GameFontDisableLeft")
	row.Activity:SetHeight(15)
	row.Activity:SetPoint("BOTTOMLEFT", 10, 5)

	row.Selected = row:CreateTexture(nil, "OVERLAY")
	row.Selected:SetAtlas("groupfinder-highlightbar-yellow")
	row.Selected:SetBlendMode("ADD")
	row.Selected:SetPoint("TOPLEFT", 3, -3)
	row.Selected:SetPoint("BOTTOMRIGHT", -3, -1)
	row.Selected:Hide()

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAtlas("groupfinder-highlightbar-blue")
	highlight:SetBlendMode("ADD")
	highlight:SetPoint("TOPLEFT", 3, -3)
	highlight:SetPoint("BOTTOMRIGHT", -3, -1)

	-- Blizzard's role display, used purely as art: its delist button would
	-- run Blizzard's listing code from an addon-made frame, so it stays off
	if view.hasDisplay then
		local display = CreateFrame("Frame", nil, row, DISPLAY_TEMPLATE)
		display:SetPoint("RIGHT", row, "RIGHT", -2, -1)
		display.showDelistButton = false
		if display.DelistButton then
			display.DelistButton:Hide()
			display.DelistButton:EnableMouse(false)
		end
		row.Display = display
	end

	row:SetScript("OnClick", RowOnClick)
	row:SetScript("OnEnter", RowOnEnter)
	row:SetScript("OnLeave", RowOnLeave)
	return row
end

local function NewHeader()
	local header = CreateFrame("Button", nil, view.Content)
	header:SetHeight(HEADER_H)

	local bg = header:CreateTexture(nil, "BACKGROUND")
	bg:SetColorTexture(0.3, 0.3, 0.3, 0.2)
	bg:SetPoint("TOPLEFT", 3, -8)
	bg:SetPoint("BOTTOMRIGHT", -3, 0)

	header.Label = header:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	header.Label:SetJustifyH("LEFT")
	header.Label:SetSize(200, 18)
	header.Label:SetPoint("LEFT", 8, -4)

	header.Expand = header:CreateTexture(nil, "ARTWORK")
	header.Expand:SetAtlas("QuestLog-icon-Expand")
	header.Collapse = header:CreateTexture(nil, "ARTWORK")
	header.Collapse:SetAtlas("QuestLog-icon-shrink")
	for _, icon in ipairs({ header.Expand, header.Collapse }) do
		icon:SetSize(18, 18)
		icon:SetPoint("RIGHT", -8, -4)
		icon:SetVertexColor(0.8, 0.8, 0.8, 1)
	end

	local highlight = header:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAtlas("groupfinder-highlightbar-blue")
	highlight:SetBlendMode("ADD")
	highlight:SetPoint("TOPLEFT", 3, -7)
	highlight:SetPoint("BOTTOMRIGHT", -3, -1)

	header:SetScript("OnClick", function(self)
		collapsed[self.category] = not collapsed[self.category] or nil
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		RebuildView()
	end)
	return header
end

-- One row, built the way Blizzard's LFGBrowseSearchEntry_Update builds
-- theirs, minus their tooltip. Called only after a fully readable verdict
-- pass, and every field is still secret-guarded.
local function FillRow(row, id, info)
	local isSolo = Plain(info.numMembers) == 1
	local hasSelf = Plain(info.hasSelf) and true or false
	local delisted = Plain(info.isDelisted) and true or false
	local name = Plain(info.leaderName)
	row.entry = { id = id, name = name, solo = isSolo, self = hasSelf, delisted = delisted }

	local soloRoles
	if isSolo then
		row.PartyIcon:Hide()
		local member = C_LFGList.GetSearchResultPlayerInfo(id, 1)
		local readable = member and not issecret(member)
		local classFile = readable and Plain(member.classFilename)
		local level = readable and Plain(member.level)
		local atlas = classFile and ("groupfinder-icon-class-" .. classFile:lower())
		if classFile and level and C_Texture.GetAtlasInfo(atlas) then
			row.Level:SetText((LEVEL_ABBR or "Lvl") .. " " .. level)
			row.Level:Show()
			row.ClassIcon:SetAtlas(atlas, false)
			row.ClassIcon:Show()
		else
			row.Level:Hide()
			row.ClassIcon:Hide()
		end
		row.Name:SetPoint("TOPLEFT", row.PartyIcon, "TOPLEFT", 1, -5)
		row.NewPlayer:SetPoint("LEFT", row.ClassIcon, "RIGHT", 2, 0)
		local roles = readable and member.lfgRoles
		if roles and not issecret(roles)
			and not (issecret(roles.tank) or issecret(roles.healer) or issecret(roles.dps)) then
			soloRoles = roles
		end
	else
		row.PartyIcon:Show()
		row.Level:Hide()
		row.ClassIcon:Hide()
		row.Name:SetPoint("TOPLEFT", row.PartyIcon, "TOPRIGHT", 0, -5)
		row.NewPlayer:SetPoint("LEFT", row.Name, "RIGHT", 2, 0)
	end

	-- activity line: yours first (blue), a count when several, and grey
	-- when the listing is not in the activity filter
	local ids = {}
	for _, aid in ipairs(IDList(info.activityIDs) or {}) do
		if not issecret(aid) then ids[#ids + 1] = aid end
	end
	local matching = {}
	for _, aid in ipairs(MyActivityIDs() or {}) do
		if not issecret(aid) and ListHas(ids, aid) then matching[#matching + 1] = aid end
	end
	local shown = (#matching > 0) and matching or ids
	local activityText
	if hasSelf then
		activityText = LFG_SELF_LISTING or "Your listing"
	elseif #shown == 1 then
		activityText = ActivityName(shown[1]) or ""
	else
		local fmt = (#matching > 0) and LFGBROWSE_ACTIVITY_MATCHING_COUNT or LFGBROWSE_ACTIVITY_COUNT
		activityText = string.format(fmt or "%d activities", #shown)
	end
	local picked = PickedActivityIDs()
	local matchesFilter = true
	if picked and #picked > 0 then
		matchesFilter = false
		for _, aid in ipairs(ids) do
			if ListHas(picked, aid) then matchesFilter = true break end
		end
	end

	local nameColor = NORMAL_FONT_COLOR
	local leader = C_LFGList.GetSearchResultLeaderInfo(id)
	local leaderClass = leader and not issecret(leader) and Plain(leader.classFilename)
	if leaderClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[leaderClass] then nameColor = RAID_CLASS_COLORS[leaderClass] end
	local levelColor, activityColor = GRAY_FONT_COLOR, GRAY_FONT_COLOR
	if delisted or not matchesFilter then
		nameColor, levelColor, activityColor = DELISTED_COLOR, DELISTED_COLOR, DELISTED_COLOR
	elseif hasSelf then
		activityColor = LIGHTGREEN_FONT_COLOR
	elseif #matching > 0 then
		activityColor = BRIGHTBLUE_FONT_COLOR
	end

	row.Name:SetWidth(0)
	row.Name:SetText(name or "")
	row.Name:SetTextColor(nameColor.r, nameColor.g, nameColor.b)
	if row.Name:GetWidth() > NAME_MAX then row.Name:SetWidth(NAME_MAX) end
	row.Level:SetTextColor(levelColor.r, levelColor.g, levelColor.b)
	row.ClassIcon:SetDesaturated(delisted)
	row.Activity:SetText(activityText)
	row.Activity:SetTextColor(activityColor.r, activityColor.g, activityColor.b)
	row.NewPlayer:SetShown(Plain(info.newPlayerFriendly) and true or false)
	row.NewPlayer:SetDesaturated(delisted)

	if row.Display then
		local counts = C_LFGList.GetSearchResultMemberCounts(id)
		if not counts or issecret(counts) or not TableReadable(counts) then counts = nil end
		local displayType, maxPlayers = LFGBrowseUtil_GetBestDisplayTypeForActivityIDs(ids)
		-- Blizzard's updater returns early without a display type, which
		-- would leave a pooled row showing its previous listing's roles
		row.Display:SetShown(displayType ~= nil)
		if displayType then
			LFGBrowseGroupDataDisplay_Update(row.Display, displayType, maxPlayers, counts, delisted,
				isSolo, soloRoles, Plain(info.comment) or "", hasSelf)
		end
	end
end

local function FillHeader(header, category)
	header.category = category
	if category == "players" then
		header.Label:SetText(LFG_LIST_CATEGORY_SOLO_PLAYERS or "Players")
	else
		header.Label:SetText(LFG_LIST_CATEGORY_GROUPS or "Groups")
	end
	local shut = collapsed[category] and true or false
	header.Expand:SetShown(shut)
	header.Collapse:SetShown(not shut)
end

-- Blizzard's list keeps the scrollbar out of the way until it is needed.
local function PlaceScroll(needBar)
	local scroll = view.Scroll
	scroll:ClearAllPoints()
	scroll:SetPoint("TOPLEFT", view, "TOPLEFT", 3, -3)
	scroll:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", needBar and -18 or -2, 3)
	view.Bar:SetShown(needBar)
	if not needBar then scroll:SetVerticalScroll(0) end
end

-- Lays out the kept listings in Blizzard's order, with Blizzard's
-- Players / Groups headers (collapsible here too).
local function LayoutView(kept)
	local content = view.Content
	local showHeaders = LFGVANILLA_SETTING_BROWSE_SHOW_COLLAPSIBLE_CATEGORIES
	local y, rowCount, headerCount, lastCategory = 0, 0, 0, nil
	local selectedHere = false
	local function Place(frame, height)
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
		frame:Show()
		y = y + height
	end
	for _, id in ipairs(kept) do
		-- Verdict keeps a listing it has no info for (it cannot judge one);
		-- there is nothing to draw for it either
		local info = C_LFGList.GetSearchResultInfo(id)
		if info and not issecret(info) then
			local category
			if not info.hasSelf then category = (info.numMembers <= 1) and "players" or "groups" end
			if showHeaders and category and category ~= lastCategory then
				lastCategory = category
				headerCount = headerCount + 1
				local header = viewHeaders[headerCount] or NewHeader()
				viewHeaders[headerCount] = header
				FillHeader(header, category)
				Place(header, HEADER_H)
			end
			if not (category and collapsed[category]) then
				rowCount = rowCount + 1
				local row = viewRows[rowCount] or NewRow()
				viewRows[rowCount] = row
				FillRow(row, id, info)
				Place(row, ROW_H)
				if row.entry.id == selectedID then selectedHere = true end
			end
		end
	end
	for i = rowCount + 1, #viewRows do
		viewRows[i]:Hide()
		viewRows[i].entry = nil
	end
	for i = headerCount + 1, #viewHeaders do viewHeaders[i]:Hide() end
	if not selectedHere then selectedID = nil end

	-- the scroll area is 21px narrower than the list with a scrollbar, 5px
	-- without (Blizzard's own ScrollBox insets)
	local needBar = y > (view:GetHeight() or 0) - 6
	PlaceScroll(needBar)
	content:SetHeight(math.max(1, y))
	content:SetWidth(math.max(1, (view:GetWidth() or 0) - (needBar and 21 or 5)))
	view.Note:SetShown(#kept == 0)
	PaintSelection()
	UpdateViewButtons()
end

local function HideView()
	if view and view:IsShown() then view:Hide() end
	UpdateButton()
end

-- Rebuilds the addon's list from Blizzard's CURRENT results (read, never
-- written): judge every listing first and step aside if any is unreadable.
function RebuildView()
	rebuildQueued = false
	local frame = LFGBrowseFrame
	if not (view and frame) then return end
	if not FilterActive() then
		pausedReason = nil
		HideView()
		return
	end
	if not frame:IsVisible() or frame.searching or frame.searchFailed then
		HideView()
		return
	end
	local results = frame.results
	if issecret(results) or type(results) ~= "table" then
		pausedReason = "hidden"
		HideView()
		Log("our list: Blizzard's results are unreadable - Blizzard's list shows")
		return
	end
	local n = #results
	totalCount = n
	if n == 0 then
		pausedReason, shownCount = nil, 0
		HideView()
		return
	end
	lockSeen = LockState()
	if lockSeen ~= "no" then
		pausedReason = "lockdown"
		HideView()
		Log(string.format("our list: %d listings - PAUSED, lockdown=%s, Blizzard's list shows", n, lockSeen))
		return
	end
	local kept = {}
	for i = 1, n do
		local id = results[i]
		local verdict
		if not issecret(id) then verdict = Verdict(id) end
		if verdict == nil then
			pausedReason = "hidden"
			HideView()
			Log(string.format("our list: %d listings - PAUSED, listing #%d unreadable, Blizzard's list shows", n, i))
			return
		end
		if verdict then kept[#kept + 1] = id end
	end
	pausedReason = nil
	shownCount = #kept
	view:Show()
	LayoutView(kept)
	UpdateButton()
	Log(string.format("our list: %d listings, filter %s - showing %d", n, FilterSummary(), shownCount))
end

-- Coalesced: many events in one frame cost one rebuild, from our own timer.
-- A rebuild that runs first (Blizzard's redraw) clears the flag and cancels it.
local function RequestRebuild()
	if rebuildQueued then return end
	rebuildQueued = true
	C_Timer.After(0, function()
		if rebuildQueued then RebuildView() end
	end)
end

local function BuildView(frame)
	local v = CreateFrame("Frame", nil, frame)
	v:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", 0, 0)
	v:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", 0, 0)
	-- well above Blizzard's rows, which sit a few levels inside their ScrollBox
	local under = (frame.ScrollBox and frame.ScrollBox:GetFrameLevel()) or frame:GetFrameLevel()
	v:SetFrameLevel(under + 20)
	-- nothing reaches Blizzard's rows underneath: clicks, hover or the wheel
	v:EnableMouse(true)
	v:EnableMouseWheel(true)
	v:SetScript("OnMouseWheel", function() end)
	v:Hide()
	view = v

	-- the same art as Blizzard's Inset, over a solid base so none of the
	-- list underneath shows through
	local base = v:CreateTexture(nil, "BACKGROUND", nil, -8)
	base:SetColorTexture(0, 0, 0, 1)
	base:SetPoint("TOPLEFT", 3, -3)
	base:SetPoint("BOTTOMRIGHT", -3, 3)
	local art = v:CreateTexture(nil, "BACKGROUND", nil, -7)
	art:SetAtlas("groupfinder-background")
	art:SetPoint("TOPLEFT", 3, -3)
	art:SetPoint("BOTTOMRIGHT", -3, 3)

	local scroll = CreateFrame("ScrollFrame", nil, v)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	local bar = CreateFrame("EventFrame", nil, v, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 2, -4)
	bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 0, 2)
	ScrollUtil.InitScrollFrameWithScrollBar(scroll, bar)
	scroll:SetPanExtent(ROW_H)
	scroll:EnableMouseWheel(true)
	v.Scroll, v.Content, v.Bar = scroll, content, bar
	PlaceScroll(false)

	local note = v:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	note:SetPoint("TOP", 0, -40)
	note:SetText("No listings match your filter.")
	v.Note = note

	-- our Send Message / Group Invite, exactly over Blizzard's (which only
	-- ever act on Blizzard's own selection)
	local send = CreateFrame("Button", nil, v, "UIPanelButtonTemplate")
	send:SetAllPoints(frame.SendMessageButton)
	send:SetText(SEND_MESSAGE or "Send Message")
	send:SetScript("OnClick", function()
		local entry = SelectedEntry()
		if entry then OpenWhisperBox(entry.name) end
	end)
	local invite = CreateFrame("Button", nil, v, "UIPanelButtonTemplate")
	invite:SetAllPoints(frame.GroupInviteButton)
	invite:SetText(GROUP_INVITE or "Group Invite")
	invite:SetScript("OnClick", function() InviteEntry(SelectedEntry()) end)
	v.SendButton, v.InviteButton = send, invite

	v.hasDisplay = not (C_XMLUtil and C_XMLUtil.GetTemplateInfo)
		or C_XMLUtil.GetTemplateInfo(DISPLAY_TEMPLATE) ~= nil
	UpdateViewButtons()
end

-------------------------------------------------------------------------------
-- Menu
-------------------------------------------------------------------------------

-- A filter change starts the list from the top.
local function Changed()
	if view then view.Scroll:SetVerticalScroll(0) end
	RebuildView()
end

local function IsRoleOn(key)
	return active[key] == true
end

local function ToggleRole(key)
	active[key] = not active[key] or nil
	Log("menu: " .. key .. " -> " .. (active[key] and "ON" or "off"))
	Changed()
end

local function IsShowMode(key)
	return showMode == key
end

local function SetShowMode(key)
	showMode = key
	Log("menu: show " .. key)
	Changed()
end

local function IsOpenSpotOn()
	return openSpotOnly
end

local function ToggleOpenSpot()
	openSpotOnly = not openSpotOnly
	Log("menu: groups with a spot for my role -> " .. (openSpotOnly and "ON" or "off"))
	Changed()
end

local function IsClassOn(classFile)
	return classActive[classFile] == true
end

local function ToggleClass(classFile)
	classActive[classFile] = not classActive[classFile] or nil
	Log("menu: class " .. classFile .. " -> " .. (classActive[classFile] and "ON" or "off"))
	Changed()
end

local function ClearClasses()
	wipe(classActive)
	Log("menu: any class")
	Changed()
end

-- The lowest level a solo player may be (Arc, 2026-09-21: "I only want to see
-- people level 18+ or 50+"), typed into the menu's Minimum level box ("I want
-- this to be a user input"). Empty, 0 or 1 = any level.
local function MinLevelText()
	return minLevel and tostring(minLevel) or ""
end

local function SetMinLevel(text)
	local level = tonumber(text)
	level = (level and level > 1) and math.floor(level) or nil
	if level == minLevel then return end -- "0" after empty, "07" after "7"
	minLevel = level
	Log("menu: player level " .. (minLevel and (minLevel .. "+") or "any"))
	Changed()
end

local function IsGroupClassHidden(classFile)
	return groupExclude[classFile] == true
end

local function ToggleGroupClass(classFile)
	groupExclude[classFile] = not groupExclude[classFile] or nil
	Log("menu: hide groups with " .. classFile .. " -> " .. (groupExclude[classFile] and "ON" or "off"))
	Changed()
end

local function ClearGroupClasses()
	wipe(groupExclude)
	Log("menu: groups with any class")
	Changed()
end

-- Every class this game has: the class lists always offer all of them, at 0
-- when nobody of a class is listed right now (Arc, 2026-09-21: "always show
-- all classes"). The list is Blizzard's own CLASS_SORT_ORDER, which the game
-- loads per game type (Forever's holds the nine classic classes). Counting
-- GetClassInfo up to GetNumClasses() left Druid out: Forever answers 9, but
-- class IDs have gaps and Druid is 11 (Arc: "when there is no druid available
-- I still want the option"). The ID walk is only a fallback.
local function GameClasses()
	local list, seen = {}, {}
	local function Add(classFile)
		if type(classFile) == "string" and not seen[classFile] then
			seen[classFile] = true
			list[#list + 1] = classFile
		end
	end
	if type(CLASS_SORT_ORDER) == "table" then
		for _, classFile in ipairs(CLASS_SORT_ORDER) do
			if not issecret(classFile) then Add(classFile) end
		end
	end
	if #list == 0 and GetClassInfo then
		for classID = 1, 30 do -- no count to stop at: the IDs have gaps
			local _, classFile = GetClassInfo(classID)
			if not issecret(classFile) then Add(classFile) end
		end
	end
	return list
end

local function MemberClass(resultID, index)
	local member = C_LFGList.GetSearchResultPlayerInfo(resultID, index)
	if not member or issecret(member) then return nil end
	local classFile = member.classFilename
	if issecret(classFile) then return nil end
	return classFile
end

-- A class list for a menu: every class the game has, plus any seen in the
-- results or already ticked (in case the game's list misses one), with
-- counts from the current (unfiltered) results - solo players for the
-- player list, groups with at least one member of the class for the group
-- list. Your own listing is not counted. Read-only.
local function ClassChoices(forGroups, ticked)
	local counts, order = {}, {}
	for _, classFile in ipairs(GameClasses()) do counts[classFile] = 0 end
	local _, results = C_LFGList.GetFilteredSearchResults()
	if results and not issecret(results) then
		for i = 1, #results do
			local id = results[i]
			local info = not issecret(id) and C_LFGList.GetSearchResultInfo(id)
			local members = info and not issecret(info) and Plain(info.numMembers)
			local hasSelf = info and not issecret(info) and Plain(info.hasSelf)
			if members and not hasSelf then
				if not forGroups and members == 1 then
					local classFile = MemberClass(id, 1)
					if classFile then counts[classFile] = (counts[classFile] or 0) + 1 end
				elseif forGroups and members > 1 then
					local seen = {}
					for m = 1, members do
						local classFile = MemberClass(id, m)
						if classFile and not seen[classFile] then
							seen[classFile] = true
							counts[classFile] = (counts[classFile] or 0) + 1
						end
					end
				end
			end
		end
	end
	for classFile in pairs(ticked) do counts[classFile] = counts[classFile] or 0 end
	for classFile in pairs(counts) do order[#order + 1] = classFile end
	return SortClasses(order), counts
end

-- Class-coloured checkboxes "Mage (2)" for one of the two class lists.
local function AddClassBoxes(menu, forGroups, ticked, isOn, toggle)
	local choices, counts = ClassChoices(forGroups, ticked)
	if #choices == 0 then
		menu:CreateTitle("No classes found")
	end
	for _, classFile in ipairs(choices) do
		local label = ClassLabel(classFile)
		local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
		if color and color.colorStr then label = "|c" .. color.colorStr .. label .. "|r" end
		menu:CreateCheckbox(string.format("%s (%d)", label, counts[classFile]), isOn, toggle, classFile)
	end
end

local function ClearAll()
	wipe(active)
	wipe(classActive)
	wipe(groupExclude)
	showMode = "both"
	openSpotOnly = false
	minLevel = nil
	Log("menu: reset filter")
	Changed()
end

local function BuildMenu(owner, root)
	root:CreateTitle("Show")
	for _, mode in ipairs(SHOW_MODES) do
		local radio = root:CreateRadio(mode.label, IsShowMode, SetShowMode, mode.key)
		radio:SetResponse(REFRESH) -- stay open, like the checkboxes
	end
	root:CreateDivider()
	root:CreateTitle("Players signed up as")
	for _, role in ipairs(ROLES) do
		root:CreateCheckbox(role.label, IsRoleOn, ToggleRole, role.key)
	end
	-- Class submenu: combines with the role ticks (DPS + Mage = DPS mages).
	local classMenu = root:CreateButton(AnyClassTicked() and ("Class: " .. ClassNames(classActive)) or "Class: any")
	local anyClass = classMenu:CreateButton("Any class", ClearClasses)
	anyClass:SetResponse(REFRESH)
	AddClassBoxes(classMenu, false, classActive, IsClassOn, ToggleClass)
	-- Typed minimum level; combines with the rest. Empty = any level.
	root:CreateInput("Minimum level", MinLevelText, SetMinLevel,
		{ numeric = true, maxLetters = 2, placeholder = "any" })
	root:CreateDivider()
	root:CreateTitle("Groups")
	root:CreateCheckbox("Has a spot for me (" .. MyRolesText() .. ")", IsOpenSpotOn, ToggleOpenSpot)
	-- Hide groups that have anyone of a ticked class (Arc, 2026-09-21: "if I
	-- don't want a group that has a hunter, a rogue or a warrior").
	local groupMenu = root:CreateButton(AnyGroupExclusion()
		and ("Hide groups with: " .. ClassNames(groupExclude)) or "Hide groups with: none")
	local allGroups = groupMenu:CreateButton("Allow all classes", ClearGroupClasses)
	allGroups:SetResponse(REFRESH)
	AddClassBoxes(groupMenu, true, groupExclude, IsGroupClassHidden, ToggleGroupClass)
	root:CreateDivider()
	root:CreateTitle("Invites")
	root:CreateCheckbox("Whisper when I invite", WhisperOn, ToggleWhisper)
	root:CreateButton("Edit invite message", ShowSettings)
	for _, extend in ipairs(NS.menuExtras) do extend(root) end
	root:CreateDivider()
	root:CreateButton("Reset filter", ClearAll)
	-- Built at the widest text so it never truncates; the initializer re-runs
	-- on every refresh, which keeps the line live.
	local status = root:CreateTitle(STATUS_WIDEST)
	status:AddInitializer(function(frame)
		frame.fontString:SetText(StatusText())
		if FilterActive() and pausedReason then
			frame.fontString:SetTextColor(1, 0.35, 0.35)
		else
			frame.fontString:SetTextColor(0.7, 0.7, 0.7)
		end
	end)
end

-- The active filter as one plain line per rule, for the button tooltip (the
-- debug log keeps the compact FilterSummary).
local function SummaryLines()
	local lines = {}
	if showMode == "players" then
		lines[#lines + 1] = "Show: players only"
	elseif showMode == "groups" then
		lines[#lines + 1] = "Show: groups only"
	end
	if showMode ~= "groups" then
		if AnyRoleTicked() then lines[#lines + 1] = "Players signed up as: " .. ActiveNames() end
		if AnyClassTicked() then lines[#lines + 1] = "Player classes: " .. ClassNames(classActive) end
		if minLevel then lines[#lines + 1] = "Player level: " .. minLevel .. "+" end
	end
	if showMode ~= "players" then
		if openSpotOnly then lines[#lines + 1] = "Groups with a spot for: " .. MyRolesText() end
		if AnyGroupExclusion() then lines[#lines + 1] = "Hiding groups with: " .. ClassNames(groupExclude) end
	end
	return lines
end

-- Titled "Advanced Filter" (Arc, 2026-09-21): it filters groups as well as
-- players now, so "Player filter" undersold it.
local function ShowTooltip(button)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	GameTooltip:SetText("Advanced Filter", 1, 1, 1)
	if not FilterActive() then
		GameTooltip:AddLine("Filter players by role, class and level, show only players or only groups, find groups with a spot for your role, or hide groups that have a class you don't want.", nil, nil, nil, true)
	else
		for _, line in ipairs(SummaryLines()) do
			GameTooltip:AddLine(line, 1, 0.82, 0, true)
		end
		if pausedReason then
			GameTooltip:AddLine("Paused: Blizzard is not letting addons read the list right now, so the normal list is shown.", 1, 0.35, 0.35, true)
		else
			GameTooltip:AddLine(string.format("Showing %d of %d listings.", shownCount, totalCount), 1, 1, 1)
		end
	end
	if WhisperOn() then
		GameTooltip:AddLine("Invite whisper is on.", 0.25, 0.79, 0.95)
	end
	for _, add in ipairs(NS.tooltipExtras) do add(GameTooltip) end
	GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

-- Read-only post-hook on Blizzard's UpdateResults: their results table is
-- final by now. Our list is rebuilt right here, in the same frame Blizzard
-- drew theirs, so their full list never shows for a frame before ours covers
-- it (a one-frame timer gave Arc "everyone, then poof" on every refresh).
-- Safe: hooksecurefunc hands the caller back its secure state after the
-- hook, and the rebuild only reads Blizzard's fields and writes our frames.
local function OnBlizzardRedraw()
	local frame = LFGBrowseFrame
	local results = frame.results
	if results and not issecret(results) then
		Log(string.format("blizzard: list rebuilt, %d listings (searching=%s)", #results, S(frame.searching)))
	end
	if FilterActive() then
		RebuildView()
	elseif view and view:IsShown() then
		view:Hide()
	end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		UpdateViewButtons()
	elseif FilterActive() then
		RequestRebuild()
	end
end)

local function Setup()
	local frame = LFGBrowseFrame
	if filterButton then return end
	if not (frame and frame.RefreshButton and frame.Inset and frame.SendMessageButton and frame.GroupInviteButton) then
		Log("setup: the Looking For Group browse frame is not what this addon expects - nothing installed")
		return
	end

	hooksecurefunc(frame, "UpdateResults", OnBlizzardRedraw)
	BuildView(frame)
	for _, event in ipairs({ "LFG_LIST_SEARCH_RESULT_UPDATED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE" }) do
		if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event) then
			events:RegisterEvent(event)
		end
	end

	-- Same square art, size and press nudge as Blizzard's refresh button.
	local button = CreateFrame("Button", nil, frame)
	button:SetSize(32, 32)
	button:SetPoint("LEFT", frame.RefreshButton, "RIGHT", -2, 0)
	button:SetNormalTexture("Interface\\Buttons\\UI-SquareButton-Up")
	button:SetPushedTexture("Interface\\Buttons\\UI-SquareButton-Down")
	button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

	local icon = button:CreateTexture(nil, "ARTWORK", nil, 5)
	icon:SetSize(16, 16)
	icon:SetPoint("CENTER", button, "CENTER", -1, 0)
	local hasFunnel = C_Texture.GetAtlasInfo(FILTER_ATLAS) ~= nil
	icon:SetAtlas(hasFunnel and FILTER_ATLAS or FALLBACK_ATLAS, false)
	button.Icon = icon

	local badge = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	badge:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 5)
	badge:Hide()
	button.Badge = badge

	button:SetScript("OnMouseDown", function(self) self.Icon:SetPoint("CENTER", self, "CENTER", -2, -1) end)
	button:SetScript("OnMouseUp", function(self) self.Icon:SetPoint("CENTER", self, "CENTER", -1, 0) end)
	button:SetScript("OnClick", function(self)
		GameTooltip_Hide()
		-- our own menu, never Blizzard's (see "Popup menus"); a second click closes it
		if PopupOpenFor(self) then
			ClosePopup()
		else
			NS.OpenPopup(self, BuildMenu)
		end
	end)
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", GameTooltip_Hide)
	filterButton = button

	Log(string.format("setup: own list built (role display=%s), read-only hook on UpdateResults; funnel icon=%s",
		S(view.hasDisplay), S(hasFunnel)))
	Log("setup: classes the game lists: " .. table.concat(GameClasses(), ", "))
end

-- Our own ADDON_LOADED brings the saved settings; the Looking For Group UI is
-- load-on-demand and gets its button whenever it arrives.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
	if name == ADDON then
		LoadSettings()
	elseif name == "Blizzard_GroupFinder_VanillaStyle" then
		Setup()
	end
	if db and filterButton then self:UnregisterEvent("ADDON_LOADED") end
end)
if C_AddOns.IsAddOnLoaded("Blizzard_GroupFinder_VanillaStyle") then
	Setup()
end

-- Invites: a post-hook, so the invite itself always runs first, untouched.
if C_PartyInfo and C_PartyInfo.InviteUnit then
	hooksecurefunc(C_PartyInfo, "InviteUnit", OnInviteUnit)
end

-- The read-only API a companion addon uses (see NS.menuExtras at the top):
-- judge a listing with the current filter, ask whether any player rule is
-- set, whisper someone it just invited, and write to the debug log.
NS.Verdict = Verdict
NS.HasPlayerRules = HasPlayerRules
NS.FilterSummary = FilterSummary
NS.WhisperInvite = function(name) WhisperInvitee(name, true) end
NS.ActivityName = ActivityName
NS.Log = Log

-- /arclfg          open the settings window (invite whisper)
-- /arclfg debug    open the debug log
-- /arclfg snap     open the debug log and take a snapshot of every listing
SLASH_ARCLFG1 = "/arclfg"
SlashCmdList.ARCLFG = function(msg)
	msg = (msg or ""):lower()
	if msg:match("snap") then
		ShowPanel()
		Snapshot("/arclfg snap")
	elseif msg:match("debug") or msg:match("log") then
		ShowPanel()
	else
		ShowSettings()
	end
end
