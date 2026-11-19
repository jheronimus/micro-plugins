VERSION = "0.2.0"

-- complete: interactive completion engine for Micro plugins.
-- Owns completion session lifecycle, prefix filtering, ephemeral ghost
-- text overlay, and raw-mode candidate popup via the float plugin.
-- Callers (e.g. lsp) supply candidates and replace range start; the engine
-- stays protocol-agnostic.
--
-- API (via shared global table):
--   complete.start(bp, spec)
--       spec = { range = {start = Loc, ["end"] = Loc},
--                items = { { label, insertText, detail, entry } },
--                onAccept = fn(item), onSelect = fn(item), onClose = fn() }
--   complete.isActive()
--   complete.cycle(delta) / accept() / dismiss()

local micro = import("micro")
local buffer = import("micro/buffer")
local util = import("micro/util")

local overlayOk, overlay = pcall(function()
	return import("micro/overlay")
end)

local SCROLL_STEP = 3
local PAGE_STEP = 5
local WHEEL_UP = 256
local WHEEL_DOWN = 512

local session = nil
local overlayHandle = nil

-- ========== ghost text rendering ==========

local function isCursorAtSession(bp, start)
	local cur = bp.Buf:GetActiveCursor()
	return cur.Y == start.Y and cur.X >= start.X
end

local function ghostSuffix(item, prefix)
	local text = item.insertText or item.label or ""
	if #prefix == 0 then
		return text
	end
	if text:sub(1, #prefix):lower() == prefix:lower() then
		return text:sub(#prefix + 1)
	end
	return nil
end

local function cursorLoc(cur)
	return buffer.Loc(cur.X, cur.Y)
end

local function getGhostText()
	if session == nil or #session.filtered == 0 then
		return nil
	end
	local bp = session.bp
	if bp == nil or bp.Buf == nil or not isCursorAtSession(bp, session.start) then
		return nil
	end
	local item = session.filtered[session.idx + 1]
	if item == nil then
		return nil
	end
	local cur = bp.Buf:GetActiveCursor()
	local prefix = util.String(bp.Buf:Substr(session.start, cursorLoc(cur)))
	return ghostSuffix(item, prefix)
end

local function ghostStyle()
	local style = overlay.Style()
	local cfg = overlay.GetColor("comment"):Decompose()
	style = style:Foreground(cfg)
	local clFg, clBg = overlay.GetColor("cursor-line"):Decompose()
	local bg = (clFg ~= 0) and clFg or clBg
	if bg ~= 0 then
		style = style:Background(bg)
	end
	return style
end

local function isPaneReady(bp)
	return bp ~= nil and session ~= nil and bp == session.bp and bp.Buf ~= nil
end

local function drawGhostText()
	if not overlayOk or overlay == nil or session == nil then
		return
	end
	local ghost = getGhostText()
	if ghost == nil or ghost == "" then
		return
	end
	local bp = micro.CurPane()
	if not isPaneReady(bp) then
		return
	end
	local cur = bp.Buf:GetActiveCursor()
	local sl = bp:ScreenLoc(cursorLoc(cur))
	if sl.X < 0 or sl.Y < 0 then
		return
	end
	overlay.DrawText(ghost, sl.X, sl.Y, util.CharacterCountInString(ghost), 1, ghostStyle())
end

-- ========== session mechanics ==========

local function advanceLoc(loc, text)
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\r?\n") do
		lines[#lines + 1] = line
	end
	if #lines <= 1 then
		return buffer.Loc(loc.X + util.CharacterCountInString(text), loc.Y)
	end
	return buffer.Loc(util.CharacterCountInString(lines[#lines]), loc.Y + #lines - 1)
end

local function floatUsable()
	return float ~= nil and float.available ~= nil and float.available()
end

local function itemLabel(item)
	if item.detail ~= nil and item.detail ~= "" then
		return item.label .. "  " .. item.detail
	end
	return item.label
end

local function bucketItem(item, prefix, lowerPrefix, exact, prefixMatch, fuzzy)
	local label = item.label or item.insertText or ""
	local lowerLabel = label:lower()
	if label:sub(1, #prefix) == prefix then
		exact[#exact + 1] = item
	elseif lowerLabel:sub(1, #prefix) == lowerPrefix then
		prefixMatch[#prefixMatch + 1] = item
	elseif lowerLabel:find(lowerPrefix, 1, true) then
		fuzzy[#fuzzy + 1] = item
	end
end

local function filterItems(items, prefix)
	if #prefix == 0 then
		return items
	end
	local lowerPrefix = prefix:lower()
	local exact, prefixMatch, fuzzy = {}, {}, {}
	for _, item in ipairs(items) do
		bucketItem(item, prefix, lowerPrefix, exact, prefixMatch, fuzzy)
	end
	local out = {}
	for _, it in ipairs(exact) do
		out[#out + 1] = it
	end
	for _, it in ipairs(prefixMatch) do
		out[#out + 1] = it
	end
	for _, it in ipairs(fuzzy) do
		out[#out + 1] = it
	end
	return out
end

local function redrawOverlay()
	if overlayOk and overlay ~= nil and overlay.Redraw ~= nil then
		overlay.Redraw()
	end
end

local function showMenu()
	if not floatUsable() or #session.filtered == 0 then
		if float ~= nil then
			float.hide()
		end
		return
	end
	local labels = {}
	for _, item in ipairs(session.filtered) do
		labels[#labels + 1] = itemLabel(item)
	end
	float.show({
		anchor = "cursor",
		loc = session.start,
		lines = labels,
		activeItem = session.idx,
		raw = true,
		border = true,
		onSelect = function(idx)
			if session ~= nil then
				session.idx = idx
				if session.cb.onSelect ~= nil and session.filtered[idx + 1] ~= nil then
					session.cb.onSelect(session.filtered[idx + 1])
				end
				redrawOverlay()
			end
		end,
	})
end

local function updateFilter(bp)
	if session == nil then
		return
	end
	local cur = bp.Buf:GetActiveCursor()
	if cur.Y ~= session.start.Y or cur.X < session.start.X then
		dismiss()
		return
	end
	local prefix = util.String(bp.Buf:Substr(session.start, cursorLoc(cur)))
	session.prefix = prefix
	session.filtered = filterItems(session.allItems, prefix)
	session.idx = 0
	showMenu()
	if session.filtered[1] ~= nil and session.cb.onSelect ~= nil then
		session.cb.onSelect(session.filtered[1])
	end
	redrawOverlay()
end

function start(bp, spec)
	dismiss()
	if spec == nil or spec.items == nil or #spec.items == 0 then
		return
	end
	local rangeStart = (spec.range and spec.range.start) or buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
	local cur = bp.Buf:GetActiveCursor()
	local prefix = ""
	if cur.Y == rangeStart.Y and cur.X >= rangeStart.X then
		prefix = util.String(bp.Buf:Substr(rangeStart, cursorLoc(cur)))
	end
	local filtered = filterItems(spec.items, prefix)
	session = {
		bp = bp,
		start = rangeStart,
		allItems = spec.items,
		filtered = filtered,
		prefix = prefix,
		idx = 0,
		cb = spec,
	}
	showMenu()
	if filtered[1] ~= nil and spec.onSelect ~= nil then
		spec.onSelect(filtered[1])
	end
	redrawOverlay()
end

function isActive()
	return session ~= nil
end

function dismiss()
	if session == nil then
		return
	end
	local closing = session
	session = nil
	if float ~= nil then
		float.hide()
	end
	if closing.cb.onClose ~= nil then
		closing.cb.onClose()
	end
	redrawOverlay()
end

function accept()
	if session == nil then
		return
	end
	local closing = session
	local item = closing.filtered[closing.idx + 1]
	session = nil
	if float ~= nil then
		float.hide()
	end
	if item ~= nil and closing.bp ~= nil and closing.bp.Buf ~= nil then
		local text = item.insertText or item.label or ""
		local bp = closing.bp
		local cur = bp.Buf:GetActiveCursor()
		bp.Buf:Replace(closing.start, cursorLoc(cur), text)
		bp.Cursor:GotoLoc(advanceLoc(closing.start, text))
		if closing.cb.onAccept ~= nil then
			closing.cb.onAccept(item)
		end
	end
	if closing.cb.onClose ~= nil then
		closing.cb.onClose()
	end
	redrawOverlay()
end

function cycle(delta)
	if session == nil or #session.filtered < 2 then
		return
	end
	session.idx = (session.idx + delta) % #session.filtered
	if float ~= nil and float.isActive() then
		float.cycle(delta)
	else
		local item = session.filtered[session.idx + 1]
		if item ~= nil and session.cb.onSelect ~= nil then
			session.cb.onSelect(item)
		end
		redrawOverlay()
	end
end

-- ========== keyboard hooks ==========

function preAutocomplete()
	if session == nil then
		return
	end
	accept()
	return false
end

function preCycleAutocompleteBack()
	if session == nil then
		return
	end
	cycle(-1)
	return false
end

-- ========== event capture ==========

local sessionKeys = {
	Escape = function()
		dismiss()
		return false
	end,
	Esc = function()
		dismiss()
		return false
	end,
	Up = function()
		if session ~= nil and #session.filtered > 0 then
			cycle(-1)
			return false
		end
		dismiss()
	end,
	Down = function()
		if session ~= nil and #session.filtered > 0 then
			cycle(1)
			return false
		end
		dismiss()
	end,
	Enter = function()
		if session ~= nil and #session.filtered > 0 then
			accept()
			return false
		end
		dismiss()
	end,
	Tab = function()
		if session ~= nil and #session.filtered > 0 then
			accept()
			return false
		end
		dismiss()
	end,
	Backtab = function()
		if session ~= nil and #session.filtered > 0 then
			cycle(-1)
			return false
		end
		dismiss()
	end,
	["Ctrl+N"] = function()
		if session ~= nil and #session.filtered > 0 then
			cycle(1)
			return false
		end
	end,
	["Ctrl+P"] = function()
		if session ~= nil and #session.filtered > 0 then
			cycle(-1)
			return false
		end
	end,
	PageUp = function()
		if float ~= nil and float.isActive() then
			float.scroll(-PAGE_STEP)
			return false
		end
	end,
	PageDown = function()
		if float ~= nil and float.isActive() then
			float.scroll(PAGE_STEP)
			return false
		end
	end,
}

local function handleSessionKey(info)
	local handler = sessionKeys[info.name]
	if handler ~= nil then
		return handler()
	end
end

local function handleSessionMouse(e, info)
	if info.buttons == 0 then
		return
	end
	if info.buttons == WHEEL_UP or info.buttons == WHEEL_DOWN then
		if float.containsMouse(e) then
			float.scroll((info.buttons == WHEEL_UP) and -SCROLL_STEP or SCROLL_STEP)
			return false
		end
		return
	end
	if float.containsMouse(e) then
		return false
	end
	dismiss()
end

function preAnyEvent(e)
	if session == nil or float == nil or float.eventInfo == nil then
		return
	end
	local info = float.eventInfo(e)
	if info.kind == "key" then
		return handleSessionKey(info)
	end
	if info.kind == "mouse" then
		return handleSessionMouse(e, info)
	end
end

function onAnyEvent()
	if session == nil then
		return
	end
	local bp = session.bp
	if bp == nil or bp.Buf == nil then
		dismiss()
		return
	end
	local cur = bp.Buf:GetActiveCursor()
	if cur.Y ~= session.start.Y or cur.X < session.start.X then
		dismiss()
		return
	end
	local prefix = util.String(bp.Buf:Substr(session.start, cursorLoc(cur)))
	if prefix ~= session.prefix then
		updateFilter(bp)
	end
end

function init()
	if overlayOk and overlay ~= nil and overlay.CreateOverlay ~= nil then
		overlayHandle = overlay.CreateOverlay(drawGhostText)
	end
end

function deinit()
	dismiss()
	if overlayOk and overlay ~= nil and overlayHandle ~= nil then
		overlay.DestroyOverlay(overlayHandle)
		overlayHandle = nil
	end
end
