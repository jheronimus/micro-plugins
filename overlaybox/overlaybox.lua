VERSION = "0.1.0"

-- overlaybox: a boxed overlay widget for Micro plugins, built on the
-- micro/overlay immediate-mode API (upstream PR #3733). Provides the
-- floating-box UX (word wrap, border, title, scrollbar, active item,
-- keyboard cycling, mouse wheel scrolling, auto-dismiss) that the raw
-- API deliberately leaves to the plugin side.
--
-- API (called from other plugins via the shared global table):
--   overlaybox.show(opts)  opts = { anchor = "top-right"|"cursor"|"center",
--       title, lines = {...} or content = "text", width, maxHeight,
--       border = true, autoclose = true, activeItem = nil|0,
--       onAccept = fn(idx), onSelect = fn(idx), onClose = fn()
--       (idx in activeItem/onAccept/onSelect is a 0-based index into the
--       caller's lines, not the wrapped display lines)
--   overlaybox.hide()
--   overlaybox.isActive()
--   overlaybox.cycle(delta)   -- move active item (Tab handlers etc.)
--   overlaybox.scroll(delta)
--
-- While a box is open, the plugin's pre<Action> hooks block the keys it
-- consumes (cycling, accept, scroll, escape) and close the box on other
-- keys when autoclose is set, letting the key pass through.

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
		for _, wl in ipairs(wrapLine(entry.text or "", innerW)) do
			box.wrapped[#box.wrapped + 1] = {
				text = wl,
				bold = entry.bold,
				italic = entry.italic,
				color = entry.color,
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
			local curLoc = bp.Buf:GetActiveCursor().Loc
			local sl = overlay.BufPaneScreenLoc(bp, buffer.Loc(curLoc.X, curLoc.Y))
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
	return style
end

local function drawContent()
	local r = box.rect
	local startY = box.border and r.y + 1 or r.y
	local startX = box.border and r.x + 1 or r.x
	for i = 0, box.innerH - 1 do
		local idx = box.scrollY + i + 1
		if idx > box.totalLines then
			break
		end
		local entry = box.wrapped[idx]
		local style = styleForEntry(entry)
		-- activeItem is a source-item index; every wrapped line belonging
		-- to that item is highlighted
		if box.activeItem ~= nil and entry.srcIndex - 1 == box.activeItem then
			style = style:Reverse(true)
		end
		overlay.DrawText(entry.text, startX, startY + i, box.innerW, 1, style)
	end
end

local function draw()
	if box == nil then
		return
	end
	layout()
	clampScroll()
	position()
	overlay.DrawRect(box.rect.x, box.rect.y, box.rect.w, box.rect.h, overlay.Style())
	if box.border then
		drawBorder()
		drawTitle()
	end
	drawContent()
end

local function mouseInside(te)
	if box == nil or box.rect == nil or te == nil then
		return false
	end
	local mx, my = te:Position()
	local r = box.rect
	return mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
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
		onAccept = opts.onAccept,
		onSelect = opts.onSelect,
		onClose = opts.onClose,
		anchor = opts.anchor or "top-right",
		scrollY = 0,
		source = {},
	}
	if opts.lines ~= nil then
		for _, l in ipairs(opts.lines) do
			box.source[#box.source + 1] = l
		end
	else
		for seg in ((opts.content or "") .. "\n"):gmatch("(.-)\n") do
			box.source[#box.source + 1] = seg
		end
	end
	box.srcCount = #box.source
end

function hide()
	if box ~= nil and box.onClose ~= nil then
		local cb = box.onClose
		box.onClose = nil
		cb()
	end
	box = nil
end

function isActive()
	return box ~= nil
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

-- Keyboard hooks: consume the keys a box needs, dismiss on the rest.
function preEscape()
	if box == nil then
		return
	end
	hide()
	return false
end

function preCursorUp()
	if box == nil then
		return
	end
	if box.activeItem ~= nil then
		cycle(-1)
		return false
	end
	if box.autoclose then
		hide()
	end
end

function preCursorDown()
	if box == nil then
		return
	end
	if box.activeItem ~= nil then
		cycle(1)
		return false
	end
	if box.autoclose then
		hide()
	end
end

function preInsertNewline()
	if box == nil then
		return
	end
	if box.activeItem ~= nil then
		accept()
		return false
	end
	if box.autoclose then
		hide()
	end
end

local function dismissOnKey()
	if box ~= nil and box.autoclose then
		hide()
	end
end

function preBackspace()
	dismissOnKey()
end

function preDelete()
	dismissOnKey()
end

function preCursorLeft()
	dismissOnKey()
end

function preCursorRight()
	dismissOnKey()
end

function preRune()
	dismissOnKey()
end

function prePageUp()
	if box == nil then
		return
	end
	scroll(-PAGE_STEP)
	return false
end

function prePageDown()
	if box == nil then
		return
	end
	scroll(PAGE_STEP)
	return false
end

-- mouse-event hooks receive (bufpane, tcell event): PluginCB prepends the
-- bufpane, and te is nil when the action was triggered by a key binding
-- instead of the mouse
function preScrollUp(bp, te)
	if box == nil or not mouseInside(te) then
		return
	end
	scroll(-SCROLL_STEP)
	return false
end

function preScrollDown(bp, te)
	if box == nil or not mouseInside(te) then
		return
	end
	scroll(SCROLL_STEP)
	return false
end

function init()
	if not overlayOk then
		micro.Log("overlaybox: editor has no micro/overlay API, plugin disabled")
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
