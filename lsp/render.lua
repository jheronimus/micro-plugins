-- Pure CommonMark-subset renderer for LSP server documentation.
--
-- This file deliberately imports nothing from micro: it is exercised
-- directly by tests/run.lua under a plain Lua interpreter.
--
-- Entry points:
--   normalizeContents(contents) -> {kind, text} or nil
--       normalizes the four LSP hover shapes: MarkupContent,
--       MarkedString, MarkedString[], and a plain string (LSP 3.x
--       legacy). The kind decides how renderMarkdown is applied.
--   renderMarkdown(text, width) -> lines
--       renders markdown to a list of entries for float. Every
--       entry has .text; single-styled lines carry bold/italic/strike/
--       color, and wrapped prose lines carry .segments with per-word
--       styling. Lines are pre-wrapped to width so hanging indents
--       survive float's re-wrap.
--
-- Rendered subset: ATX and setext headings, fenced and indented code,
-- bullet and ordered lists (with nesting and task markers), block
-- quotes, thematic breaks, GFM tables, and inline code spans, emphasis,
-- strong, strikethrough, links/images rendered as their text, backslash
-- escapes, and HTML entities (pylsp emits &nbsp; indentation).

-- ========== text utilities ==========

local function runeCount(s)
	local _, count = s:gsub("[^\128-\191]", "")
	return count
end

local function splitLines(s)
	local lines = {}
	for line in (s .. "\n"):gmatch("(.-)\r?\n") do
		lines[#lines + 1] = line
	end
	return lines
end

local function trim(s)
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function concatText(segments)
	local parts = {}
	for _, seg in ipairs(segments) do
		parts[#parts + 1] = seg.text
	end
	return table.concat(parts)
end

-- ========== HTML entities and code points ==========

local entities = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	copy = "©",
	reg = "®",
	trade = "™",
	mdash = "—",
	ndash = "–",
	hellip = "…",
	laquo = "«",
	raquo = "»",
	lsquo = "‘",
	rsquo = "’",
	ldquo = "“",
	rdquo = "”",
	bull = "•",
	middot = "·",
	times = "×",
	deg = "°",
	plusmn = "±",
	frac12 = "½",
}

local function charFromCode(cp)
	if cp < 128 then
		return string.char(cp)
	end
	if cp < 2048 then
		return string.char(192 + math.floor(cp / 64), 128 + cp % 64)
	end
	if cp < 65536 then
		return string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
	end
	return string.char(
		240 + math.floor(cp / 262144),
		128 + math.floor(cp / 4096) % 64,
		128 + math.floor(cp / 64) % 64,
		128 + cp % 64
	)
end

local function decodeEntities(s)
	s = s:gsub("&#x([%x]+);", function(hex)
		local cp = tonumber(hex, 16)
		if cp == nil or cp > 1114111 then
			return "&#" .. hex .. ";"
		end
		return charFromCode(cp)
	end)
	s = s:gsub("&#([0-9]+);", function(dec)
		local cp = tonumber(dec, 10)
		if cp == nil or cp > 1114111 then
			return "&#" .. dec .. ";"
		end
		return charFromCode(cp)
	end)
	s = s:gsub("&(%a+);", function(name)
		return entities[name] or ("&" .. name .. ";")
	end)
	return s
end

-- &nbsp; runs are decoded at text-render time, not before block
-- classification: basedpyright/pylsp indent docstring sections with
-- them, and decoding early would turn those lines into indented code
-- blocks (dimmed) instead of prose
local function fin(s)
	return (s:gsub("&nbsp;", " "):gsub("&ensp;", " "):gsub("&thinsp;", " "))
end

-- ========== inline parsing ==========
-- Inline content becomes a flat list of styled chunks; the block layer
-- splits chunks into words and wraps them. Delimiter matching follows
-- the CommonMark flanking rules loosely: an opener must sit next to
-- non-whitespace and a closer too, and '_' never opens inside a word.

local parseInlineText

local function withStyle(base, key)
	local copy = {}
	for k, v in pairs(base) do
		copy[k] = v
	end
	copy[key] = true
	return copy
end

local function matchEscape(s, pos)
	local nxt = s:sub(pos + 1, pos + 1)
	if nxt ~= "" and nxt:match("%p") then
		return { { text = nxt } }, 2
	end
	return nil
end

local function matchCodeSpan(s, pos, base, depth)
	local n = 1
	while s:sub(pos + n, pos + n) == "`" do
		n = n + 1
	end
	local i = pos + n
	while i <= #s do
		if s:sub(i, i) == "`" then
			local j = i
			while s:sub(j + 1, j + 1) == "`" do
				j = j + 1
			end
			if j - i + 1 == n then
				local content = s:sub(pos + n, i - 1):gsub("\n", " ")
				content = (content:gsub("^%s(.-)%s$", "%1"))
				return { { text = content, code = true } }, j - pos + 1
			end
			i = j + 1
		else
			i = i + 1
		end
	end
	return nil
end

local function matchAutolink(s, pos)
	local uri = s:match("^<([hH][tT][tT][pP][sS]?://[^%s>]+)>", pos)
	if uri == nil then
		return nil
	end
	return { { text = uri } }, #uri + 2
end

-- matchLink renders the link text only: the overlay API has no
-- hyperlink support, so the URL is dropped (same choice as Helix)
local function matchLink(s, pos, base, depth)
	local label, url = s:match("^%[([^%]]*)%]%(([^%s()]*)%)", pos)
	if label == nil then
		return nil
	end
	local inner = parseInlineText(label, base, depth + 1)
	if #inner == 0 then
		inner = { { text = url } }
	end
	return inner, #label + #url + 4
end

local function matchImage(s, pos, base, depth)
	if s:sub(pos, pos) ~= "!" then
		return nil
	end
	local chunks, advance = matchLink(s, pos + 1, base, depth)
	if chunks == nil then
		return nil
	end
	return chunks, advance + 1
end

local function emphasisInner(s, pos, c, openLen)
	local closeIdx = s:find(string.rep(c, openLen), pos + openLen, true)
	if closeIdx == nil then
		return nil
	end
	local inner = s:sub(pos + openLen, closeIdx - 1)
	if not inner:sub(1, 1):match("^%S") or not inner:sub(-1):match("^%S") then
		return nil
	end
	if c == "_" and pos > 1 and s:sub(pos - 1, pos - 1):match("%w") then
		return nil
	end
	return inner, closeIdx
end

local function matchEmphasis(s, pos, base, depth)
	local c = s:sub(pos, pos)
	local openLen = (s:sub(pos, pos + 1) == c .. c) and 2 or 1
	local inner, closeIdx = emphasisInner(s, pos, c, openLen)
	if inner == nil then
		return nil
	end
	local chunks = parseInlineText(inner, withStyle(base, (openLen == 2) and "bold" or "italic"), depth + 1)
	return chunks, closeIdx + openLen - pos
end

local function matchStrike(s, pos, base, depth)
	if s:sub(pos, pos + 1) ~= "~~" then
		return nil
	end
	local closeIdx = s:find("~~", pos + 2, true)
	if closeIdx == nil then
		return nil
	end
	local inner = s:sub(pos + 2, closeIdx - 1)
	if not inner:sub(1, 1):match("^%S") or not inner:sub(-1):match("^%S") then
		return nil
	end
	local chunks = parseInlineText(inner, withStyle(base, "strike"), depth + 1)
	return chunks, closeIdx + 2 - pos
end

local inlineHandlers = {
	["\\"] = matchEscape,
	["`"] = matchCodeSpan,
	["<"] = matchAutolink,
	["!"] = matchImage,
	["["] = matchLink,
	["*"] = matchEmphasis,
	["_"] = matchEmphasis,
	["~"] = matchStrike,
}

local function mergeChunk(out, chunk)
	local prev = out[#out]
	local same = prev ~= nil
		and prev.bold == chunk.bold
		and prev.italic == chunk.italic
		and prev.strike == chunk.strike
		and prev.code == chunk.code
	if same then
		prev.text = prev.text .. chunk.text
	else
		out[#out + 1] = chunk
	end
	return out
end

function parseInlineText(s, base, depth)
	base = base or {}
	depth = (depth or 0) + 1
	if depth > 6 then
		return { { text = s, bold = base.bold, italic = base.italic, strike = base.strike, code = base.code } }
	end
	local out = {}
	local pending = nil
	local function flushPending()
		if pending ~= nil and pending ~= "" then
			mergeChunk(out, {
				text = pending,
				bold = base.bold,
				italic = base.italic,
				strike = base.strike,
				code = base.code,
			})
		end
		pending = nil
	end
	local pos = 1
	while pos <= #s do
		local handler = inlineHandlers[s:sub(pos, pos)]
		local chunks, advance
		if handler ~= nil then
			chunks, advance = handler(s, pos, base, depth)
		end
		if chunks ~= nil then
			flushPending()
			for _, chunk in ipairs(chunks) do
				mergeChunk(out, chunk)
			end
			pos = pos + advance
		else
			pending = (pending or "") .. s:sub(pos, pos)
			pos = pos + 1
		end
	end
	flushPending()
	return out
end

local function plainText(s)
	return concatText(parseInlineText(s, {}, 0))
end

-- ========== wrapping ==========
-- Splits styled chunks into words and greedy-wraps them to width,
-- merging adjacent words with identical styles into segments.

local function splitWords(chunks)
	local words = {}
	for _, chunk in ipairs(chunks) do
		-- code spans stay whole words, spaces included — breaking them
		-- would let the space between words lose its styling
		if chunk.code then
			words[#words + 1] = {
				text = chunk.text,
				bold = chunk.bold,
				italic = chunk.italic,
				strike = chunk.strike,
				code = chunk.code,
			}
		else
			for word in chunk.text:gmatch("%S+") do
				words[#words + 1] = {
					text = word,
					bold = chunk.bold,
					italic = chunk.italic,
					strike = chunk.strike,
					code = chunk.code,
				}
			end
		end
	end
	return words
end

local function wrapChunks(chunks, width)
	if width < 1 then
		width = 1
	end
	local lines = {}
	local segments = nil
	local lineLen = 0
	for _, word in ipairs(splitWords(chunks)) do
		local wl = runeCount(word.text)
		if segments ~= nil and lineLen + 1 + wl > width then
			lines[#lines + 1] = segments
			segments = nil
		end
		if segments == nil then
			segments = {}
			lineLen = 0
		end
		if #segments > 0 then
			table.insert(segments, { text = " " })
			lineLen = lineLen + 1
		end
		table.insert(segments, word)
		lineLen = lineLen + wl
	end
	if segments ~= nil then
		lines[#lines + 1] = segments
	end
	return lines
end

local function segmentsEntry(segments)
	return { text = concatText(segments), segments = segments }
end

-- blank line between adjacent blocks (Helix-style paragraph spacing);
-- only one, regardless of how many blank source lines separate them
local function separate(out)
	if #out > 0 and out[#out].text ~= "" then
		out[#out + 1] = { text = "" }
	end
end

-- emit wrapped lines for a list item: `prefix` leads the first line,
-- `hang` leads every continuation line
local function emitWrapped(out, chunks, width, prefix, hang)
	for li, segments in ipairs(wrapChunks(chunks, width)) do
		local lead = (li == 1) and prefix or hang
		local all = { { text = lead } }
		for _, seg in ipairs(segments) do
			all[#all + 1] = seg
		end
		out[#out + 1] = { text = lead .. concatText(segments), segments = all }
	end
end

-- ========== block parsing ==========

-- Lua patterns have no {0,3} quantifier; this prefix matches the 0-3
-- spaces CommonMark allows before structural markers
local LEAD3 = "^%s?%s?%s?"

local function flushPara(out, state, width)
	if state.para == nil then
		return
	end
	separate(out)
	for _, group in ipairs(state.para) do
		local text = concatText(group.chunks)
		-- a dash (or equals) run inside a hard-broken paragraph is a
		-- setext underline: promote the previous line to a heading
		if #out > 0 and out[#out].text ~= "" and (text:match("^%-%-+%s*$") or text:match("^=+%s*$")) then
			out[#out].bold = true
			out[#out].color = "constant"
			out[#out].segments = nil
		else
			local pad = string.rep(" ", group.indent)
			for _, segments in ipairs(wrapChunks(group.chunks, math.max(width - group.indent, 1))) do
				local all = {}
				if pad ~= "" then
					all[#all + 1] = { text = pad }
				end
				for _, seg in ipairs(segments) do
					all[#all + 1] = seg
				end
				out[#out + 1] = { text = pad .. concatText(segments), segments = all }
			end
		end
	end
	state.para = nil
	state.paraHard = false
end

local function fenceMarker(line)
	return line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
end

local function isFenceClose(line, marker)
	local c = marker:sub(1, 1)
	return line:match("^%s*" .. string.rep(c, #marker) .. "+%s*$") ~= nil
end

local CODE_INDENT = "  "

local function renderFenceBlock(out, lines, i, width, state)
	state.para = nil
	separate(out)
	for j = i + 1, #lines do
		if isFenceClose(lines[j], fenceMarker(lines[i])) then
			return j + 1
		end
		local content = fin(lines[j])
		if content ~= "" then
			content = CODE_INDENT .. content
		end
		out[#out + 1] = { text = content, color = "comment" }
	end
	return #lines + 1
end

local function renderBlankBlock(out, lines, i, width, state)
	flushPara(out, state, width)
	return i + 1
end

local function renderHeadingBlock(out, lines, i, width, state)
	state.para = nil
	separate(out)
	local content = lines[i]:match(LEAD3 .. "#+%s*(.-)%s*$")
	-- strip an ATX closing sequence ("# Title #"), which CommonMark
	-- requires to be preceded by whitespace
	content = content:match("^(.-)%s+#+%s*$") or content
	out[#out + 1] = { text = plainText(fin(content)), bold = true, color = "constant" }
	return i + 1
end

local function renderSetextBlock(out, lines, i, width, state)
	separate(out)
	local chunks = {}
	for _, group in ipairs(state.para) do
		for _, chunk in ipairs(group.chunks) do
			chunks[#chunks + 1] = chunk
		end
	end
	local parts = {}
	for _, word in ipairs(splitWords(chunks)) do
		parts[#parts + 1] = word.text
	end
	state.para = nil
	out[#out + 1] = { text = table.concat(parts, " "), bold = true, color = "constant" }
	return i + 1
end

local function isRule(line)
	return line:match(LEAD3 .. "%-%s*%-%s*%-[%-%s]*$") ~= nil
		or line:match(LEAD3 .. "%*%s*%*%s*%*[%*%s]*$") ~= nil
		or line:match(LEAD3 .. "_%s*_%s*_[%_%s]*$") ~= nil
end

local function renderRuleBlock(out, lines, i, width, state)
	state.para = nil
	separate(out)
	out[#out + 1] = { text = string.rep("─", width), color = "comment" }
	return i + 1
end

local function renderQuoteBlock(out, lines, i, width, state)
	state.para = nil
	separate(out)
	local quoted = {}
	while i <= #lines and lines[i]:match(LEAD3 .. ">") do
		quoted[#quoted + 1] = lines[i]:match(LEAD3 .. ">%s?(.*)$")
		i = i + 1
	end
	local text = plainText(fin(table.concat(quoted, " ")))
	if text ~= "" then
		for _, part in ipairs(wrapChunks({ { text = text } }, math.max(width - 2, 1))) do
			out[#out + 1] = { text = "│ " .. concatText(part), color = "comment", italic = true }
		end
	else
		out[#out + 1] = { text = "│", color = "comment", italic = true }
	end
	return i
end

local function listMarker(line)
	local indentStr, bullet, content = line:match("^(%s*)([%*%+%-])%s+(.+)$")
	local ordered = false
	if indentStr == nil then
		indentStr, bullet, content = line:match("^(%s*)(%d+[%.)])%s+(.+)$")
		ordered = indentStr ~= nil
	end
	if indentStr == nil then
		return nil
	end
	return indentStr, bullet, content, ordered
end

-- per-level list counters; a new marker type restarts its level, and
-- the marker type is the bullet character or the ordered delimiter —
-- not the number, which changes on every ordered item
local function nextMarkerText(state, level, bullet, ordered)
	local markerType = ordered and bullet:sub(-1, -1) or bullet
	if state.lastMarker[level] ~= markerType then
		state.counters[level] = 0
		state.lastMarker[level] = markerType
	end
	for deeper = level + 1, 9 do
		state.counters[deeper] = nil
		state.lastMarker[deeper] = nil
	end
	if not ordered then
		return "• "
	end
	state.counters[level] = (state.counters[level] or 0) + 1
	return tostring(state.counters[level]) .. ". "
end

local function renderListBlock(out, lines, i, width, state)
	state.para = nil
	if not state.listOpen then
		separate(out)
		state.listOpen = true
	end
	local indentStr, bullet, content, ordered = listMarker(lines[i])
	local level = math.floor(runeCount(indentStr) / 2)
	local markerText = nextMarkerText(state, level, bullet, ordered)
	-- task list markers replace the bullet (GFM)
	local taskMark, rest = content:match("^%[([ xX])%]%s+(.+)$")
	if taskMark ~= nil then
		markerText = (taskMark == " ") and "☐ " or "☑ "
		content = rest
	end
	local chunks = parseInlineText(fin(content), {}, 0)
	local hang = indentStr .. string.rep(" ", runeCount(markerText))
	emitWrapped(out, chunks, width, indentStr .. markerText, hang)
	return i + 1
end

local function splitRow(line)
	local inner = line:match("^%s*%|(.-)|?%s*$") or trim(line)
	local cells = {}
	for cell in (inner .. "|"):gmatch("(.-)|") do
		cells[#cells + 1] = trim(cell)
	end
	return cells
end

local function isTableSeparator(line)
	if not line:find("|", 1, true) then
		return false
	end
	for _, cell in ipairs(splitRow(line)) do
		if not cell:match("^:?%-+:?$") then
			return false
		end
	end
	return true
end

local function renderTableBlock(out, lines, i, width, state)
	state.para = nil
	separate(out)
	local header = splitRow(lines[i])
	i = i + 2 -- skip the separator row
	local rows = {}
	while i <= #lines and lines[i]:find("|", 1, true) do
		rows[#rows + 1] = splitRow(lines[i])
		i = i + 1
	end
	local widths = {}
	for c, cell in ipairs(header) do
		widths[c] = runeCount(cell)
	end
	for _, row in ipairs(rows) do
		for c = 1, math.min(#header, #row) do
			widths[c] = math.max(widths[c], runeCount(row[c]))
		end
	end
	local function emitRow(cells, bold)
		local parts = {}
		for c = 1, #header do
			local cell = plainText(fin(cells[c] or ""))
			local pad = string.rep(" ", widths[c] - runeCount(cell))
			parts[#parts + 1] = "│ " .. cell .. pad .. " "
		end
		parts[#parts + 1] = "│"
		out[#out + 1] = { text = table.concat(parts), bold = bold or nil }
	end
	emitRow(header, true)
	out[#out + 1] = { text = string.rep("─", runeCount(out[#out].text)), color = "comment" }
	for _, row in ipairs(rows) do
		emitRow(row, false)
	end
	return i
end

local function renderCodeBlock(out, lines, i, width, state)
	state.para = nil
	separate(out)
	local collected = {}
	while i <= #lines do
		local content = lines[i]:match("^    (.*)$") or lines[i]:match("^\t(.*)$")
		if content ~= nil then
			collected[#collected + 1] = content
			i = i + 1
		elseif lines[i]:match("^%s*$") and #collected > 0 then
			collected[#collected + 1] = ""
			i = i + 1
		else
			break
		end
	end
	while collected[#collected] == "" do
		collected[#collected] = nil
	end
	for _, line in ipairs(collected) do
		if line ~= "" then
			line = CODE_INDENT .. fin(line)
		end
		out[#out + 1] = { text = line, color = "comment" }
	end
	return i
end

local function renderParagraphBlock(out, lines, i, width, state)
	local expanded = fin(lines[i])
	local chunks = parseInlineText(trim(expanded))
	if state.para == nil or #state.para == 0 then
		state.para = { { chunks = chunks, indent = #expanded:match("^ *") } }
	elseif state.paraHard then
		table.insert(state.para, { chunks = chunks, indent = #expanded:match("^ *") })
	else
		-- soft break: continue the previous line
		local last = state.para[#state.para].chunks
		for _, chunk in ipairs(chunks) do
			table.insert(last, chunk)
		end
	end
	-- two trailing spaces are a markdown hard line break
	state.paraHard = lines[i]:match("%s%s$") ~= nil
	return i + 1
end

local function classifyStructural(line, state)
	if fenceMarker(line) ~= nil then
		return "fence"
	end
	if line:match("^%s*$") then
		return "blank"
	end
	if line:match(LEAD3 .. "#+") then
		return "heading"
	end
	if state.para ~= nil and line:match("^=+%s*$") then
		return "setext"
	end
	if state.para ~= nil and line:match("^%-+%s*$") then
		return "setext"
	end
	if isRule(line) then
		return "rule"
	end
	if line:match(LEAD3 .. ">") then
		return "quote"
	end
	return nil
end

local function classifyFlow(line, lines, i, state)
	if listMarker(line) ~= nil then
		return "list"
	end
	if line:find("|", 1, true) and lines[i + 1] ~= nil and isTableSeparator(lines[i + 1]) then
		return "table"
	end
	if state.para == nil and (line:match("^    %S") ~= nil or line:match("^\t%S") ~= nil) then
		return "code"
	end
	return "paragraph"
end

local blockRenderers = {
	fence = renderFenceBlock,
	blank = renderBlankBlock,
	heading = renderHeadingBlock,
	setext = renderSetextBlock,
	rule = renderRuleBlock,
	quote = renderQuoteBlock,
	list = renderListBlock,
	table = renderTableBlock,
	code = renderCodeBlock,
	paragraph = renderParagraphBlock,
}

-- ========== public entry points ==========

local function normalizeMarkup(contents)
	local kind = (contents.kind == "plaintext") and "plaintext" or "markdown"
	return { kind = kind, text = tostring(contents.value or "") }
end

local function normalizeMarkedString(contents)
	local value = tostring(contents.value or "")
	return { kind = "markdown", text = "```" .. tostring(contents.language) .. "\n" .. value .. "\n```" }
end

-- MarkedString[]: normalize each item and join
local function normalizeArray(contents)
	local parts, anyMarkdown = {}, false
	for _, item in ipairs(contents) do
		local normalized = normalizeContents(item)
		if normalized ~= nil and normalized.text ~= "" then
			anyMarkdown = anyMarkdown or (normalized.kind == "markdown")
			parts[#parts + 1] = normalized.text
		end
	end
	if #parts == 0 then
		return nil
	end
	local kind = anyMarkdown and "markdown" or "plaintext"
	return { kind = kind, text = table.concat(parts, "\n\n") }
end

function normalizeContents(contents)
	if type(contents) == "string" then
		return { kind = "plaintext", text = contents }
	end
	if type(contents) ~= "table" then
		return nil
	end
	if contents.kind ~= nil then
		return normalizeMarkup(contents)
	end
	if contents.language ~= nil then
		return normalizeMarkedString(contents)
	end
	if contents[1] == nil then
		return nil
	end
	return normalizeArray(contents)
end

local function renderBlocks(text, width)
	local out = {}
	local state = { para = nil, paraHard = false, counters = {}, lastMarker = {} }
	-- decode before classification: entity-produced indentation (&nbsp;
	-- runs from pylsp/basedpyright) must be visible to block parsing
	local lines = splitLines(decodeEntities(text))
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local kind = classifyStructural(line, state)
		if kind == nil then
			kind = classifyFlow(line, lines, i, state)
		end
		i = blockRenderers[kind](out, lines, i, width, state)
		if kind ~= "blank" then
			state.listOpen = (kind == "list")
		end
	end
	flushPara(out, state, width)
	return out
end

function renderMarkdown(text, width)
	if type(text) ~= "string" or text == "" then
		return {}
	end
	if width == nil or width < 10 then
		width = 40
	end
	local out = renderBlocks(text, width)
	-- drop trailing blank lines
	while #out > 0 and out[#out].text == "" do
		out[#out] = nil
	end
	return out
end
