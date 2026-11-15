-- Pure CSV/TSV table renderer for the line-transform API.
--
-- This file deliberately imports nothing from micro: it is exercised
-- directly by tests/csv_run.lua under a plain Lua interpreter.
--
-- The contract mirrors lsp/render.lua's philosophy: csv/csv.lua owns the
-- micro integration (transform registration, commands, mouse remap) and
-- delegates all parsing, layout and offset math to this module.
--
-- Entry points:
--   parseLine(raw, delim) -> fields
--       quote-aware (RFC4180) field split; unterminated quotes absorb the
--       rest of the line; embedded newlines (multi-line records) are out
--       of scope — every line is one record
--   computeWidths(fieldsPerLine, delim, maxCol) -> widths
--       display rune-width per column, capped at maxCol
--   renderRow(fields, widths, delim, header, maxCol) -> text, spans
--       fields padded to their column widths; delimiters colored via
--       spans; the header row is bold; overlong fields truncate with an
--       ellipsis
--   displayToRawCol(fields, widths, delim, dispCol, maxCol) -> rawCol
--       maps a column in the rendered row to a byte-rune offset in the
--       raw line (for click-to-cell)
--   addColumn(raw, delim, col) -> raw
--   delColumn(raw, delim, col) -> raw
--       insert/remove field `col` (0-based) on one raw line
--
-- All column indices are 0-based; raw offsets are rune offsets (micro's
-- cursor X counts runes).

local M = {}

local ELLIPSIS = "…"

-- rune count for display width (ASCII cells are the common case; wide
-- runes would need runewidth and are a known limitation)
function runeLen(s)
	local _, count = s:gsub("[^\128-\191]", "")
	return count
end

-- quote-aware split of one raw line into fields
function parseLine(raw, delim)
	local fields = {}
	local field = ""
	local i = 1
	local inQuotes = false
	while i <= #raw do
		local c = raw:sub(i, i)
		if inQuotes then
			if c == '"' then
				if raw:sub(i + 1, i + 1) == '"' then
					field = field .. '"'
					i = i + 2
				else
					inQuotes = false
					i = i + 1
				end
			else
				field = field .. c
				i = i + 1
			end
		elseif c == '"' then
			inQuotes = true
			i = i + 1
		elseif c == delim then
			fields[#fields + 1] = field
			field = ""
			i = i + 1
		else
			field = field .. c
			i = i + 1
		end
	end
	fields[#fields + 1] = field
	return fields
end

-- display width per column over every parsed line, capped at maxCol
function computeWidths(fieldsPerLine, maxCol)
	local widths = {}
	for _, fields in ipairs(fieldsPerLine) do
		for ci, field in ipairs(fields) do
			local w = runeLen(field)
			if w > (widths[ci] or 0) then
				widths[ci] = w
			end
		end
	end
	for ci, w in ipairs(widths) do
		if w > maxCol then
			widths[ci] = maxCol
		end
	end
	return widths
end

-- iterate characters of a UTF-8 string (GopherLua has no utf8 lib)
local function runes(s)
	return s:gmatch("[\0-\127\192-\255][\128-\191]*")
end

-- truncate a field to maxCol display runes
local function fit(field, maxCol)
	if runeLen(field) <= maxCol then
		return field
	end
	local out = ""
	local n = 0
	for ch in runes(field) do
		if n >= maxCol - 1 then
			break
		end
		out = out .. ch
		n = n + 1
	end
	return out .. ELLIPSIS
end

-- render one row: fields padded to their column widths and joined by
-- the delimiter, with spans coloring the delimiters; header rows render
-- bold. Returns the display text and the span list; nil for no fields.
function renderRow(fields, widths, delim, header, maxCol)
	if fields == nil or #fields == 0 then
		return nil
	end

	local text = ""
	local spans = {}

	for ci = 1, #fields do
		local shown = fit(fields[ci], maxCol)
		text = text .. shown
		local pad = (widths[ci] or 0) - runeLen(shown)
		if pad > 0 then
			text = text .. string.rep(" ", pad)
		end
		if ci < #fields then
			spans[#spans + 1] = { start = runeLen(text), length = 1, color = "comment" }
			text = text .. delim
		end
	end
	if header then
		spans[#spans + 1] = { start = 0, length = runeLen(text), bold = true }
	end
	return text, spans
end

-- map a column in the rendered row to a rune offset in the raw line.
-- Padded display columns beyond a field's raw length map to the field's
-- last character; beyond the last field map to the line end.
function displayToRawCol(fields, widths, delim, dispCol, maxCol)
	local dispRun = 0
	local rawRun = 0
	local endRaw = 0
	for ci = 1, #fields do
		local rawLen = runeLen(fields[ci])
		local shownLen = widths[ci] or rawLen
		local fieldStart = dispRun

		if dispCol <= fieldStart + shownLen then
			local off = dispCol - fieldStart
			if off > rawLen then
				off = rawLen
			end
			return rawRun + off
		end

		rawRun = rawRun + rawLen
		dispRun = dispRun + shownLen
		endRaw = rawRun
		if ci < #fields then
			dispRun = dispRun + 1 -- delimiter cell
			rawRun = rawRun + 1
			endRaw = rawRun
		end
	end
	return endRaw
end

-- 1-based raw offsets of the top-level (unquoted) delimiters of a line;
-- the shared quote-aware scan behind the column operations
local function delimPositions(raw, delim)
	local positions = {}
	local i, inQuotes = 1, false
	while i <= #raw do
		local c = raw:sub(i, i)
		if inQuotes then
			if c == '"' then
				if raw:sub(i + 1, i + 1) == '"' then
					i = i + 2
				else
					inQuotes = false
					i = i + 1
				end
			else
				i = i + 1
			end
		elseif c == '"' then
			inQuotes = true
			i = i + 1
		elseif c == delim then
			positions[#positions + 1] = i
			i = i + 1
		else
			i = i + 1
		end
	end
	return positions
end

-- insert an empty field after column `col` (0-based) on one raw line:
-- a delimiter goes in right before the delimiter that follows field col
function addColumn(raw, delim, col)
	local fields = parseLine(raw, delim)
	if col < 0 or col >= #fields then
		return raw .. delim
	end
	local at = delimPositions(raw, delim)[col + 1] or (#raw + 1)
	return raw:sub(1, at - 1) .. delim .. raw:sub(at)
end

-- remove field `col` (0-based) on one raw line, eating the delimiter
-- that follows it (or, for the first field, the one that precedes it)
function delColumn(raw, delim, col)
	local fields = parseLine(raw, delim)
	if col < 0 or col >= #fields then
		return raw
	end
	local positions = delimPositions(raw, delim)
	if col == 0 then
		-- field plus its trailing delimiter
		local nextDelim = positions[1] or (#raw + 1)
		return raw:sub(nextDelim + 1)
	end
	-- field plus its leading delimiter; the delimiter after it belongs
	-- to the next field and stays
	local prevDelim = positions[col] or 0
	local nextDelim = positions[col + 1] or (#raw + 1)
	return raw:sub(1, prevDelim - 1) .. raw:sub(nextDelim)
end
