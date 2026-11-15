VERSION = "0.1.0"

-- csv: renders CSV/TSV files as aligned tables through micro's
-- line-transform API (the primitive the markdown plugin PoCs). The row
-- under the cursor always renders raw, so cells are edited in place on
-- the real text; every other row renders as an aligned, span-colored
-- table. Erasing a cell's contents empties it without shifting other
-- cells; Enter at end of row adds a row (native InsertNewline); Tab
-- completion is whatever micro does natively — in a TSV an inserted tab
-- *is* a new column, which is inherent to tab-delimited editing. Ctrl+K
-- deletes the row (bound to DeleteLine here, since micro binds nothing
-- to Ctrl+K by default). Columns are managed with commands.
--
-- Model: csvview.nvim (non-destructive aligned display over raw text),
-- csv.vim (column commands).
--
-- Commands (command bar, Ctrl-e):
--   csv.addcol    insert an empty column after the cursor's column
--   csv.delcol    remove the cursor's column
--
-- Known limitations: multi-line (embedded-newline) records are not
-- supported — every line is one record; wide (CJK) runes count as one
-- display column. Files are detected by .csv/.tsv extension.

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local overlay = import("micro/overlay")

local MAX_COL = 32

-- ========== buffer/delimiter detection ==========

local function delimiterFor(bufName)
	if bufName:match("%.csv$") or bufName:match("%.CSV$") then
		return ","
	end
	if bufName:match("%.tsv$") then
		return "\t"
	end
	return nil
end

local function isTableBuf(bp)
	return delimiterFor(bp.Buf.Name) ~= nil or delimiterFor(bp.Buf.AbsPath) ~= nil
end

-- find the open buffer the transform was invoked for
local function getBuf(bufName)
	for _, b in ipairs(buffer.OpenBuffers()) do
		if b.Name == bufName or b.AbsPath == bufName then
			return b
		end
	end
	return nil
end

-- ========== parse/width cache ==========

-- fields are cached per raw line text (the transform runs for every
-- visible line on every frame; see the markdown PoC for the same scheme)
local parseCache = {}
local parseCount = 0
local PARSE_MAX = 4096

local function cachedFields(bufName, rawText, delim)
	local cache = parseCache[bufName]
	if cache == nil then
		cache = {}
		parseCache[bufName] = cache
	end
	local hit = cache[rawText]
	if hit ~= nil then
		return hit
	end
	if parseCount > PARSE_MAX then
		parseCache = {}
		parseCache[bufName] = cache
		parseCount = 0
	end
	local fields = parseLine(rawText, delim)
	cache[rawText] = fields
	parseCount = parseCount + 1
	return fields
end

-- column widths over the whole buffer; recomputed per frame from the
-- parse cache (a hash lookup per line — the parse itself only happens
-- for changed lines)
local function bufferWidths(b, delim)
	local fieldsPerLine = {}
	local n = b:LinesNum()
	for i = 0, n - 1 do
		fieldsPerLine[i + 1] = cachedFields(b.Name, b:Line(i), delim)
	end
	return computeWidths(fieldsPerLine, MAX_COL)
end

-- ========== line transform ==========

local function transformLine(bufName, filetype, lineN, rawText)
	local delim = delimiterFor(bufName)
	if delim == nil then
		return nil
	end
	local b = getBuf(bufName)
	if b == nil then
		return nil
	end

	local widths = bufferWidths(b, delim)
	local fields = cachedFields(bufName, rawText, delim)
	local text, spans = renderRow(fields, widths, delim, lineN == 0, MAX_COL)
	if text == nil then
		return nil
	end
	return { text = text, spans = spans }
end

-- ========== cursor's field / click-to-cell ==========

-- the raw buffer's cursor field (0-based) and delimiter, or nil if the
-- buffer is not a table
local function cursorField(bp)
	local delim = delimiterFor(bp.Buf.Name) or delimiterFor(bp.Buf.AbsPath)
	if delim == nil then
		return nil, nil
	end
	local fields = cachedFields(bp.Buf.Name, bp.Buf:Line(bp.Cursor.Loc.Y), delim)
	local col = 0
	for i, field in ipairs(fields) do
		col = col + runeLen(field)
		if bp.Cursor.Loc.X <= col then
			return i - 1, delim
		end
		col = col + 1 -- delimiter
	end
	return #fields - 1, delim
end

-- mouse press on a transformed (non-cursor) line: the window's
-- LocFromVisual maps through the raw text and would land at the wrong
-- column on padded rows — remap through the parse cache instead
function preMousePress(bp, te)
	if te == nil or bp == nil or not isTableBuf(bp) then
		return
	end
	local mx, my = te:Position()
	local origin = overlay.BufPaneScreenLoc(bp, buffer.Loc(0, my))
	local dispCol = mx - origin.X
	if dispCol < 0 then
		return
	end
	local delim = delimiterFor(bp.Buf.Name) or delimiterFor(bp.Buf.AbsPath)
	local fields = cachedFields(bp.Buf.Name, bp.Buf:Line(my), delim)
	local widths = bufferWidths(bp.Buf, delim)
	local rawX = displayToRawCol(fields, widths, delim, dispCol, MAX_COL)
	bp:GotoLoc(buffer.Loc(rawX, my))
	return false -- the remapped position replaces native MousePress
end

-- ========== commands ==========

function csvAddCol(bp)
	local col, delim = cursorField(bp)
	if col == nil then
		return
	end
	local b = bp.Buf
	for i = 0, b:LinesNum() - 1 do
		local line = b:Line(i)
		b:Replace(buffer.Loc(0, i), buffer.Loc(runeLen(line), i), addColumn(line, delim, col))
	end
	-- enter the new (empty) column on the cursor's row
	local fields = parseLine(b:Line(bp.Cursor.Loc.Y), delim)
	local rawX = 0
	for i = 1, col + 1 do
		rawX = rawX + runeLen(fields[i]) + 1
	end
	bp:GotoLoc(buffer.Loc(rawX, bp.Cursor.Loc.Y))
	micro.InfoBar():Message(("csv: column %d added"):format(col + 2))
end

function csvDelCol(bp)
	local col, delim = cursorField(bp)
	if col == nil then
		return
	end
	local b = bp.Buf
	for i = 0, b:LinesNum() - 1 do
		local line = b:Line(i)
		b:Replace(buffer.Loc(0, i), buffer.Loc(runeLen(line), i), delColumn(line, delim, col))
	end
	micro.InfoBar():Message(("csv: column %d removed"):format(col + 1))
end

-- ========== lifecycle ==========

function init()
	if micro.SetLineTransform == nil then
		micro.Log("csv: editor has no line-transform API, plugin disabled")
		return
	end
	micro.SetLineTransform("csv", transformLine)
	-- Ctrl+K deletes the current row; micro binds nothing to it by default,
	-- and TryBindKey will not override an existing user binding
	micro.TryBindKey("CtrlK", "DeleteLine", false)
	config.MakeCommand("csv.addcol", csvAddCol, config.NoComplete)
	config.MakeCommand("csv.delcol", csvDelCol, config.NoComplete)
end

function deinit()
	if micro.SetLineTransform ~= nil then
		micro.SetLineTransform("csv", nil)
	end
end
