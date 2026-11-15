VERSION = "0.1.0"

-- complete: completion engine for Micro plugins. Owns the mechanics of a
-- completion session — auto-insert, cycle/swap, accept, dismiss — over a
-- replace range the caller declares, and draws its menu through the
-- float plugin in raw mode. Callers (e.g. lsp) supply candidates and
-- stay free of insertion and UI logic; the engine stays free of
-- protocol knowledge.
--
-- API (called from other plugins via the shared global table):
--   complete.start(bp, spec)
--       spec = { range = {start = Loc, ["end"] = Loc},
--                items = { { label, insertText, detail } },
--                onAccept = fn(item), onSelect = fn(item),
--                onClose = fn() }
--       inserts the first candidate immediately and opens the menu when
--       there is more than one; replaces any open session (reverting it)
--   complete.isActive()
--   complete.cycle(delta) / accept() / dismiss()
--
-- Key semantics while a session is open: Tab / CursorDown cycle forward,
-- Shift-Tab / CursorUp cycle back, Enter accepts, Escape dismisses,
-- other keys dismiss without blocking (the buffer reverts to the
-- pre-session text and cursor first, so the key lands on the user's own
-- input). Mouse wheel over the menu scrolls it; anywhere else it passes
-- through to the buffer.

local micro = import("micro")
local buffer = import("micro/buffer")
local util = import("micro/util")

local SCROLL_STEP = 3 -- mouse wheel lines
local PAGE_STEP = 5 -- PageUp/PageDown lines

local session = nil

-- ========== session mechanics ==========

local function advanceLoc(loc, text)
	local parts = {}
	for seg in (text .. "\n"):gmatch("(.-)\n") do
		parts[#parts + 1] = seg
	end
	local lineCount = #parts - 1
	local lastLen = util.CharacterCountInString(parts[#parts])
	if lineCount == 0 then
		return buffer.Loc(loc.X + lastLen, loc.Y)
	end
	return buffer.Loc(lastLen, loc.Y + lineCount)
end

local function rangeText(bp, range)
	local cursor = bp.Buf:GetActiveCursor()
	cursor:SetSelectionStart(range.start)
	cursor:SetSelectionEnd(range["end"])
	local text = util.String(cursor:GetSelection())
	cursor:ResetSelection()
	return text
end

-- swap the currently inserted text for another candidate's text
local function applyItem(bp, item)
	local text = item.insertText or item.label
	bp.Buf:Replace(session.range.start, buffer.Loc(bp.Cursor.X, bp.Cursor.Y), text)
	bp.Cursor:GotoLoc(advanceLoc(session.range.start, text))
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

function start(bp, spec)
	dismiss()
	if not floatUsable() then
		return
	end
	if spec == nil or spec.items == nil or #spec.items == 0 then
		return
	end

	local original = rangeText(bp, spec.range)
	session = {
		range = spec.range,
		original = original,
		items = spec.items,
		idx = 0,
		cb = spec,
	}
	applyItem(bp, session.items[1])

	if #spec.items > 1 then
		local labels = {}
		for _, item in ipairs(spec.items) do
			labels[#labels + 1] = itemLabel(item)
		end
		float.show({
			anchor = "cursor",
			lines = labels,
			activeItem = 0,
			raw = true,
			border = true,
			onSelect = function(idx)
				if session ~= nil and session.cb.onSelect ~= nil then
					session.cb.onSelect(session.items[idx + 1])
				end
			end,
		})
	end
end

function isActive()
	return session ~= nil
end

-- stop the session and restore the declared range and cursor to the
-- pre-session state, so anything typed next lands on the user's own
-- input; fires onClose
function dismiss()
	if session == nil then
		return
	end
	local closing = session
	session = nil
	local bp = micro.CurPane()
	bp.Buf:Replace(closing.range.start, buffer.Loc(bp.Cursor.X, bp.Cursor.Y), closing.original)
	bp.Cursor:GotoLoc(closing.range["end"])
	if float ~= nil then
		float.hide()
	end
	if closing.cb.onClose ~= nil then
		closing.cb.onClose()
	end
end

-- keep the currently selected candidate in the buffer and close
function accept()
	if session == nil then
		return
	end
	local closing = session
	local item = closing.items[closing.idx + 1]
	session = nil
	if float ~= nil then
		float.hide()
	end
	if closing.cb.onAccept ~= nil then
		closing.cb.onAccept(item)
	end
end

function cycle(delta)
	if session == nil or #session.items < 2 then
		return
	end
	session.idx = (session.idx + delta) % #session.items
	applyItem(micro.CurPane(), session.items[session.idx + 1])
	if float ~= nil and float.isActive() then
		float.cycle(delta)
	end
end

-- ========== keyboard hooks ==========

function preAutocomplete()
	if session == nil then
		return
	end
	cycle(1)
	return false
end

function preCycleAutocompleteBack()
	if session == nil then
		return
	end
	cycle(-1)
	return false
end

function preCursorDown()
	if session == nil then
		return
	end
	cycle(1)
	return false
end

function preCursorUp()
	if session == nil then
		return
	end
	cycle(-1)
	return false
end

function preInsertNewline()
	if session == nil then
		return
	end
	accept()
	return false
end

function preEscape()
	if session == nil then
		return
	end
	dismiss()
	return false
end

-- editing keys dismiss without blocking: the buffer reverts first, so
-- the key applies to the user's own input
function preRune()
	dismiss()
end

function preBackspace()
	dismiss()
end

function preDelete()
	dismiss()
end

function preCursorLeft()
	dismiss()
end

function preCursorRight()
	dismiss()
end

-- a mouse press means the user clicked elsewhere in the buffer: dismiss
-- (the buffer reverts first, then MousePress moves the cursor)
function preMousePress()
	if session == nil then
		return
	end
	dismiss()
end

function prePageUp()
	if session == nil then
		return
	end
	float.scroll(-PAGE_STEP)
	return false
end

function prePageDown()
	if session == nil then
		return
	end
	float.scroll(PAGE_STEP)
	return false
end

-- mouse-event hooks receive (bufpane, tcell event): PluginCB prepends
-- the bufpane, and te is nil when the action was triggered by a key
-- binding instead of the mouse
function preScrollUp(bp, te)
	if session == nil or not float.containsMouse(te) then
		return
	end
	float.scroll(-SCROLL_STEP)
	return false
end

function preScrollDown(bp, te)
	if session == nil or not float.containsMouse(te) then
		return
	end
	float.scroll(SCROLL_STEP)
	return false
end

function deinit()
	dismiss()
end
