VERSION = "0.2.0"

-- float: a floating window primitive for Micro plugins, built on the
-- micro/overlay immediate-mode API (upstream PR #3733). Anything that
-- needs a floating window — menus, documentation popups, completion
-- lists — draws through this plugin. It provides the window UX (word
-- wrap, border, title, scrollbar, active item, mouse wheel scrolling,
-- auto-dismiss) that the raw API deliberately leaves to the plugin side.
--
-- API (called from other plugins via the shared global table):
--   float.show(opts)  opts = { anchor = "top-right"|"cursor"|"center",
--       title, lines = {...} or content = "text", width, maxHeight,
--       border = true, autoclose = true, raw = false, activeItem = nil|0,
--       onAccept = fn(idx), onSelect = fn(idx), onClose = fn()
--       (idx in activeItem/onAccept/onSelect is a 0-based index into the
--       caller's lines, not the wrapped display lines)
--   float.hide()
--   float.isActive()
--   float.rect()         -- current window rect or nil (for other overlays)
--   float.cycle(delta)   -- move active item (Tab handlers etc.)
--   float.scroll(delta)
--
-- Two modes:
--   menu mode (default): the plugin's pre<Action> hooks block the keys
--       it consumes (cycling, accept, scroll, escape) and close the box
--       on other keys when autoclose is set, letting the key pass
--       through. For simple consumers — menus, popups.
--   raw mode (opts.raw): all key hooks are inert — the caller owns the
--       keyboard and drives cycle/scroll/accept/hide itself. For
--       engines, like the complete plugin, that implement their own key
--       semantics on top of the window.

local micro = import("micro")
-- micro/overlay only exists in editors carrying the overlay API (the fork
-- or upstream PR #3733); degrade to an inert plugin on older binaries.
-- The whole probe runs inside pcall: editors without the API may return
-- nil or panic when touching the missing package.
local overlayOk, overlay = pcall(function()
	local ov = import("micro/overlay")
	if ov == nil or ov.CreateOverlay == nil then
		return nil
	end
	return ov
end)
if not overlayOk or overlay == nil then
	overlayOk = false
	overlay = nil
end
local buffer = import("micro/buffer")
local config = import("micro/config")

local handle = nil
local box = nil

-- box geometry and interaction constants
local WIDTH_PADDING = 4 -- border (2) + text padding (2), added to content width
local MIN_WIDTH = 10
local SCROLL_STEP = 3 -- mouse wheel lines
local PAGE_STEP = 5 -- PageUp/PageDown lines

local function runeLen(s)
	local _, count = s:gsub("[^\128-\191]", "")
	return count
end

local function splitRunes(s)
	local runes = {}
	for r in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		runes[#runes + 1] = r
	end
	return runes
end

local function wrapLine(s, limit)
	if limit <= 0 or runeLen(s) <= limit then
		return { s }
	end
	local out = {}
	local runes = splitRunes(s)
	while #runes > limit do
		local cut = limit
		for i = limit, 1, -1 do
			if runes[i] == " " then
				cut = i
				break
			end
		end
		out[#out + 1] = table.concat(runes, "", 1, cut)
		local nextIdx = (runes[cut + 1] == " ") and cut + 1 or cut
		local rest = {}
		for i = nextIdx + 1, #runes do
			rest[#rest + 1] = runes[i]
		end
		runes = rest
	end
	if #runes > 0 then
		out[#out + 1] = table.concat(runes)
	end
	return out
end

-- Terminal area available to buffer panes, derived from the infobar view
-- (screen size is not exposed to Lua; see micro#3733 discussion).
local function screenSize()
	local view = micro.InfoBar():GetView()
	if view == nil then
		return 80, 24
	end
	local tabbar = (micro.Tabs() ~= nil and #micro.Tabs().List > 1) and 1 or 0
	local statusline = config.GetGlobalOption("statusline") and 1 or 0
	local infobar = config.GetGlobalOption("infobar") ~= false and 1 or 0
	return view.Width, view.Y + 1 - tabbar - statusline - infobar
end

local function computeWidth()
	local sw = screenSize()
	local w = box.width
	if w <= 0 then
		for _, l in ipairs(box.source) do
			if runeLen(l) > w then
				w = runeLen(l)
			end
		end
		w = w + WIDTH_PADDING
	end
	if w > sw - 2 then
		w = sw - 2
	end
	if w < MIN_WIDTH then
		w = MIN_WIDTH
	end
	return w
end

local function computeHeight(sh)
	local contentH = box.totalLines
	if box.border then
		contentH = contentH + 2
	end
	if box.maxHeight > 0 and contentH > box.maxHeight then
		contentH = box.maxHeight
	elseif box.maxHeight == 0 and contentH > sh - 4 then
		contentH = sh - 4
	end
	if contentH > sh - 2 then
		contentH = sh - 2
	end
	return contentH
end

-- wrap box.source to the given inner width
local function wrapSource(innerW)
	box.wrapped = {}
	box.firstWrapped = {}
	for si, l in ipairs(box.source) do
		local entry = (type(l) == "table") and l or { text = tostring(l) }
		local wrapped = wrapLine(entry.text or "", innerW)
		for _, wl in ipairs(wrapped) do
			box.wrapped[#box.wrapped + 1] = {
				text = wl,
				bold = entry.bold,
				italic = entry.italic,
				strike = entry.strike,
				color = entry.color,
				-- styled segments only survive when no re-wrap happened
				segments = (#wrapped == 1) and entry.segments or nil,
				srcIndex = si,
			}
		end
		if box.firstWrapped[si] == nil then
			box.firstWrapped[si] = #box.wrapped
		end
	end
	box.totalLines = #box.wrapped
end

-- layout is cached across frames: re-wrapping only happens when the width
-- changes (e.g. terminal resize)
local function layout()
	local sw, sh = screenSize()
	box.w = computeWidth()
	local innerW = box.border and box.w - 2 or box.w
	if box.wrapped == nil or box.innerW ~= innerW then
		box.innerW = innerW
		wrapSource(innerW)
	end
	box.h = computeHeight(sh)
	box.innerH = box.border and box.h - 2 or box.h
end

local function position()
	local sw, sh = screenSize()
	local x, y
	if box.anchor == "center" then
		x, y = math.floor((sw - box.w) / 2), math.floor((sh - box.h) / 2)
	elseif box.anchor == "cursor" then
		local bp = micro.CurPane()
		local cx, cy = sw - box.w - 1, 1
		if bp ~= nil and bp.Buf ~= nil then
			local curLoc = box.loc or bp.Buf:GetActiveCursor().Loc
			local sl = bp:ScreenLoc(buffer.Loc(curLoc.X, curLoc.Y))
			cx, cy = sl.X, sl.Y + 1
			if cy + box.h >= sh - 1 then
				cy = sl.Y - box.h
			end
		end
		x, y = cx, cy
		if x + box.w >= sw then
			x = sw - box.w - 1
		end
	else
		x, y = sw - box.w - 1, 1
	end
	box.rect = { x = math.max(x, 0), y = math.max(y, 0), w = box.w, h = box.h }
end

local function clampScroll()
	if box.activeItem ~= nil and box.innerH > 0 and box.firstWrapped[box.activeItem + 1] ~= nil then
		local itemTop = box.firstWrapped[box.activeItem + 1] - 1
		if itemTop < box.scrollY then
			box.scrollY = itemTop
		elseif itemTop >= box.scrollY + box.innerH then
			box.scrollY = itemTop - box.innerH + 1
		end
	end
	local maxScroll = math.max(box.totalLines - box.innerH, 0)
	box.scrollY = math.max(math.min(box.scrollY, maxScroll), 0)
end

-- Frame with side borders; the right column doubles as the scrollbar.
-- No track — the border itself is the track — and a proportional thumb
-- (sized to the visible/total ratio, the way VS Code and Neovim
-- scrollbar plugins render it) drawn over the border in the comment
-- color, only when the content actually overflows.
-- The box owns its background: take only the foreground from a theme
-- group. Themes (e.g. the default monokai) define groups like comment
-- with a background, and DrawText fills its whole width with that
-- background, which would paint a band across the row.
local function groupStyle(name)
	local fg = overlay.GetColor(name):Decompose()
	return overlay.Style():Foreground(fg)
end

local function drawBorder()
	local r = box.rect
	local style = groupStyle("divider")
	overlay.DrawText("┌" .. string.rep("─", r.w - 2) .. "┐", r.x, r.y, r.w, 1, style)
	overlay.DrawText("└" .. string.rep("─", r.w - 2) .. "┘", r.x, r.y + r.h - 1, r.w, 1, style)
	for row = 1, r.h - 2 do
		overlay.DrawText("│", r.x, r.y + row, 1, 1, style)
		overlay.DrawText("│", r.x + r.w - 1, r.y + row, 1, 1, style)
	end
	local maxScroll = math.max(box.totalLines - box.innerH, 0)
	if maxScroll == 0 then
		return
	end
	local trackH = r.h - 2
	local thumbH = math.max(1, math.floor((trackH * box.innerH) / box.totalLines))
	local thumbY = math.floor((box.scrollY * (trackH - thumbH)) / maxScroll)
	local thumbStyle = groupStyle("comment")
	for i = 0, thumbH - 1 do
		overlay.DrawText("▌", r.x + r.w - 1, r.y + 1 + thumbY + i, 1, 1, thumbStyle)
	end
end

local function drawTitle()
	if box.title == "" or not box.border then
		return
	end
	local r = box.rect
	overlay.DrawText(" " .. box.title .. " ", r.x + 2, r.y, r.w - 4, 1, overlay.Style():Bold(true))
end

local function styleForEntry(entry)
	local style = overlay.Style()
	if entry.color ~= nil then
		style = groupStyle(entry.color)
	end
	if entry.bold then
		style = style:Bold(true)
	end
	if entry.italic then
		style = style:Italic(true)
	end
	if entry.strike then
		style = style:StrikeThrough(true)
	end
	return style
end

local function drawSegments(entry, startX, y, maxWidth, active)
	local x = startX
	for _, seg in ipairs(entry.segments) do
		local style = styleForEntry(seg)
		if active then
			style = style:Reverse(true)
		end
		-- DrawText fills its whole width with the style background, so the
		-- fill must end at the inner edge: a full-width fill per segment
		-- would paint a band past the window border (and each later
		-- segment's fill would still erase nothing left of its own x)
		overlay.DrawText(seg.text, x, y, maxWidth - (x - startX), 1, style)
		x = x + runeLen(seg.text)
	end
end

-- one visible wrapped line: styled segments or a plain styled row
local function drawEntry(entry, x, y, active)
	if active and not box.raw then
		overlay.SetCursor(x, y)
	end
	if entry.segments ~= nil then
		drawSegments(entry, x, y, box.innerW, active)
		return
	end
	local style = styleForEntry(entry)
	if active then
		style = style:Reverse(true)
	end
	overlay.DrawText(entry.text, x, y, box.innerW, 1, style)
end

local function drawContent()
	local r = box.rect
	local startY = box.border and r.y + 1 or r.y
	local startX = box.border and r.x + 1 or r.x
	-- cursor policy: menus put the terminal cursor on the active item
	-- (focus indicator, inverted cell in fake-cursor mode); windows
	-- without an active item hide it — nothing can be typed under them
	-- since every editing key dismisses; raw mode claims nothing so the
	-- buffer cursor stays where the user is typing
	if not box.raw then
		overlay.SetCursor(-1, -1)
	end
	for i = 0, box.innerH - 1 do
		local idx = box.scrollY + i + 1
		if idx > box.totalLines then
			break
		end
		local entry = box.wrapped[idx]
		-- activeItem is a source-item index; every wrapped line belonging
		-- to that item is highlighted
		local active = box.activeItem ~= nil and entry.srcIndex - 1 == box.activeItem
		drawEntry(entry, startX, startY + i, active)
	end
end

-- micro repaints only changed cells (displayBuffer stops at EOF and
-- BufWindow.Clear is never called), so cells this plugin stops drawing
-- keep their stale content forever. Any rect the window abandons must
-- be explicitly repainted with the buffer's own background style.
local lastRect = nil

local function clearRect(r)
	if r ~= nil then
		-- paint with the theme default background: rows below the buffer's end
		-- are never repainted by micro, so abandoned cells must blend with the
		-- buffer look; in-view cells are repainted by the next Display
		local bgStyle = overlay.GetColor("default")
		overlay.DrawRect(r.x, r.y, r.w, r.h, bgStyle)
	end
end

local function draw()
	if box == nil then
		return
	end
	layout()
	clampScroll()
	position()
	if
		lastRect ~= nil
		and (
			lastRect.x ~= box.rect.x
			or lastRect.y ~= box.rect.y
			or lastRect.w ~= box.rect.w
			or lastRect.h ~= box.rect.h
		)
	then
		clearRect(lastRect)
	end
	lastRect = box.rect
	overlay.DrawRect(box.rect.x, box.rect.y, box.rect.w, box.rect.h, overlay.Style())
	if box.border then
		drawBorder()
		drawTitle()
	end
	drawContent()
end

local function mouseInsidePoint(x, y)
	local r = box.rect
	return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

local function mouseInside(te)
	if box == nil or box.rect == nil or te == nil then
		return false
	end
	local mx, my = te:Position()
	return mouseInsidePoint(mx, my)
end

local function buildSource(opts)
	local source = {}
	if opts.lines ~= nil then
		for _, l in ipairs(opts.lines) do
			source[#source + 1] = l
		end
	else
		for seg in ((opts.content or "") .. "\n"):gmatch("(.-)\n") do
			source[#source + 1] = seg
		end
	end
	return source
end

function show(opts)
	hide()
	if opts == nil then
		return
	end
	box = {
		title = opts.title or "",
		width = opts.width or 0,
		maxHeight = opts.maxHeight or 0,
		border = opts.border ~= false,
		activeItem = opts.activeItem,
		autoclose = opts.autoclose ~= false,
		raw = opts.raw == true,
		onAccept = opts.onAccept,
		onSelect = opts.onSelect,
		onClose = opts.onClose,
		anchor = opts.anchor or "top-right",
		loc = opts.loc,
		scrollY = 0,
		source = {},
	}
	box.source = buildSource(opts)
	box.srcCount = #box.source
end

function hide()
	if box ~= nil and box.onClose ~= nil then
		local cb = box.onClose
		box.onClose = nil
		cb()
	end
	box = nil
	clearRect(lastRect)
	lastRect = nil
	if overlayOk and overlay.Redraw ~= nil then
		overlay.Redraw()
	end
end

function isActive()
	return box ~= nil
end

-- whether the editor carries the overlay API at all; engines that need a
-- visible window should degrade when it is false
function available()
	return overlayOk
end

-- whether a mouse event landed inside the window (menu scrolling)
function containsMouse(te)
	return mouseInside(te)
end

-- current window rect in screen coordinates, or nil when no window is
-- open; lets other overlays (e.g. lsp inline diagnostics) avoid painting
-- over the window
function rect()
	if box == nil or box.rect == nil then
		return nil
	end
	return box.rect
end

-- cycle/accept/onSelect/onAccept all deal in source-item indices (0-based),
-- matching what callers pass in opts.activeItem — not wrapped-line indices.
function cycle(delta)
	if box == nil or box.activeItem == nil or box.srcCount == 0 then
		return
	end
	box.activeItem = (box.activeItem + delta) % box.srcCount
	if box.onSelect ~= nil then
		box.onSelect(box.activeItem)
	end
end

function scroll(delta)
	if box == nil then
		return
	end
	box.scrollY = box.scrollY + delta
end

function accept()
	if box == nil or box.activeItem == nil then
		return
	end
	local idx = box.activeItem
	local cb = box.onAccept
	if cb ~= nil then
		cb(idx)
	end
	hide()
end

-- ========== event capture ==========

-- In raw mode capture is inert — the caller owns the keyboard.
local function hooksActive()
	return box ~= nil and not box.raw
end

-- tcell ButtonMask wheel bits (mouse.go: 1 << iota from Button1)
local WHEEL_UP = 256
local WHEEL_DOWN = 512

-- classify a raw tcell event for preAnyEvent handlers; returns a table:
--   key events:   { kind = "key", name = <tcell key name>, rune = <char> }
--                 rune keys carry the character in .rune (and .name); other
--                 names are tcell's ("Escape", "Enter", "Backspace2", "Up",
--                 "Ctrl+C", ...)
--   mouse events: { kind = "mouse", buttons = <mask>, x = <col>, y = <row> }
--   everything else (resize, paste, ...): { kind = "other" }
function eventInfo(e)
	local ok, key = pcall(function()
		return e:Key()
	end)
	if ok then
		local name = e:Name()
		local info = { kind = "key", name = name }
		if name:sub(1, 5) == "Rune[" then
			info.rune = name:sub(6, -2)
		end
		return info
	end
	local okm, buttons = pcall(function()
		return e:Buttons()
	end)
	if okm then
		local x, y = e:Position()
		return { kind = "mouse", buttons = buttons, x = x, y = y }
	end
	return { kind = "other" }
end

-- dismiss an autoclose window, leaving the event to reach the buffer
local function dismissOnKey()
	if box.autoclose then
		hide()
	end
end

-- keys that dismiss (autoclose) and then apply to the buffer
function isEditingKey(info)
	return info.rune ~= nil
		or info.name == "Backspace"
		or info.name == "Backspace2"
		or info.name == "Delete"
		or info.name == "Left"
		or info.name == "Right"
end

-- Up/Down/Enter move the active item when there is one; otherwise they
-- dismiss an autoclose window and reach the buffer
local function navigate(delta)
	if box.activeItem ~= nil then
		cycle(delta)
		return false
	end
	dismissOnKey()
	return
end

local function activate()
	if box.activeItem ~= nil then
		accept()
		return false
	end
	dismissOnKey()
	return
end

-- tcell names the escape key "Esc" (KeyNames[KeyESC]); both accepted
local function escapeHandler()
	hide()
	return false
end

local keyHandlers = {
	Escape = escapeHandler,
	Esc = escapeHandler,
	Up = function()
		return navigate(-1)
	end,
	Down = function()
		return navigate(1)
	end,
	Enter = function()
		return activate()
	end,
	PageUp = function()
		scroll(-PAGE_STEP)
		return false
	end,
	PageDown = function()
		scroll(PAGE_STEP)
		return false
	end,
}

local function handleKey(info)
	if isEditingKey(info) then
		dismissOnKey()
		return -- the key applies to the buffer
	end
	local handler = keyHandlers[info.name]
	if handler ~= nil then
		return handler()
	end
	-- no menu meaning: consume, so nothing edits the buffer behind the window
	return false
end

-- presses inside the window are consumed (unhandled they would land on
-- the buffer underneath the overlay); clicks outside dismiss autoclose
-- windows and still reach the buffer
local function handleMouse(info)
	if info.buttons == 0 then
		return -- release: the editor resets its own mouse state
	end
	local inside = mouseInsidePoint(info.x, info.y)
	if info.buttons == WHEEL_UP or info.buttons == WHEEL_DOWN then
		if inside then
			scroll((info.buttons == WHEEL_UP) and -SCROLL_STEP or SCROLL_STEP)
			return false
		end
		return -- wheel outside the window passes through
	end
	if inside then
		return false
	end
	dismissOnKey()
	return -- the click applies to the buffer
end

-- preAnyEvent captures input while a window is open: in menu mode the
-- window is modal (unknown keys are consumed instead of leaking into the
-- buffer); in raw mode every event passes through to the caller
function preAnyEvent(e)
	if not hooksActive() then
		return
	end
	local info = eventInfo(e)
	if info.kind == "key" then
		return handleKey(info)
	end
	if info.kind == "mouse" then
		return handleMouse(info)
	end
	-- resize, paste and other event kinds pass through
end

function init()
	if not overlayOk then
		micro.Log("float: editor has no micro/overlay API, plugin disabled")
		return
	end
	handle = overlay.CreateOverlay(draw)
end

function deinit()
	if handle ~= nil then
		overlay.DestroyOverlay(handle)
		handle = nil
	end
end
