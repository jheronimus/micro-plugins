VERSION = "1.0.0"

local micro = import("micro")
local config = import("micro/config")

config.RegisterCommonOption("markdown", "render", true)

local RULE_WIDTH = 40
local CACHE_MAX = 500

local function runeCount(str)
	local _, count = str:gsub("[^\128-\191]", "")
	return count
end

local function matchCodeOrStrike(sub, c)
	if c == "`" then
		local m = sub:match("^`([^`]+)`")
		if m then
			return m, #m + 2, { color = "special" }
		end
	elseif c == "~" then
		local ms = sub:match("^~~([^~]+)~~")
		if ms then
			return ms, #ms + 4, { strike = true }
		end
	end
	return nil
end

-- emphasis with CommonMark-ish flanking rules: an opener must be followed
-- by non-whitespace and a closer preceded by non-whitespace, and '_' only
-- opens at a word boundary — so `snake_case` and `2 * 3 * 4` stay raw
local function emphasisContent(s, pos, c, openLen)
	-- left-flanking: opener must be followed by non-whitespace
	if not s:sub(pos + openLen, pos + openLen):match("^%S") then
		return nil
	end
	-- '_' opens only at a word boundary, so snake_case stays raw
	if c == "_" and pos > 1 and s:sub(pos - 1, pos - 1):match("%w") then
		return nil
	end
	local closeIdx = s:find(string.rep(c, openLen), pos + openLen, true)
	if closeIdx == nil then
		return nil
	end
	local content = s:sub(pos + openLen, closeIdx - 1)
	-- right-flanking: closer must be preceded by non-whitespace
	if not content:sub(-1):match("^%S") then
		return nil
	end
	return content
end

local function matchEmphasis(s, pos)
	local c = s:sub(pos, pos)
	local openLen = (s:sub(pos, pos + 1) == c .. c) and 2 or 1
	local content = emphasisContent(s, pos, c, openLen)
	if content == nil then
		return nil
	end
	local span = { italic = true }
	if openLen == 2 then
		span = { bold = true }
	end
	return content, #content + 2 * openLen, span
end

local function matchLink(sub)
	local txt, url = sub:match("^%[([^%]]+)%]%(([^%)]+)%)")
	if txt and url then
		return txt, #txt + #url + 4, { underline = true, color = "blue" }
	end
	return nil
end

local function matchToken(s, pos)
	local sub = s:sub(pos)
	local c = s:sub(pos, pos)
	if c == "`" or c == "~" then
		return matchCodeOrStrike(sub, c)
	elseif c == "*" or c == "_" then
		return matchEmphasis(s, pos)
	elseif c == "[" then
		return matchLink(sub)
	end
	return nil
end

local function parseInline(line)
	local pos = 1
	local len = #line
	local out = {}
	local spans = {}
	local currentLen = 0

	while pos <= len do
		local content, advance, span = matchToken(line, pos)
		if content then
			local clen = runeCount(content)
			span.start = currentLen
			span.length = clen
			table.insert(spans, span)
			table.insert(out, content)
			currentLen = currentLen + clen
			pos = pos + advance
		else
			local ch = line:sub(pos, pos)
			local escaped
			if ch == "\\" and pos < len then
				local nxt = line:sub(pos + 1, pos + 1)
				-- backslash escapes the following punctuation character
				if nxt:match("^%p") then
					escaped = nxt
				end
			end
			if escaped then
				table.insert(out, escaped)
				currentLen = currentLen + 1
				pos = pos + 2
			else
				table.insert(out, ch)
				if (ch:byte() < 128) or (ch:byte() >= 192) then
					currentLen = currentLen + 1
				end
				pos = pos + 1
			end
		end
	end
	return table.concat(out), spans
end

-- rawText is a thematic break unless it is a setext h2 underline, i.e. the
-- previous rendered line was non-blank text
local function matchRule(rawText, prevLineText)
	if rawText:match("^%-%-%-+$") then
		if prevLineText ~= nil then
			return nil
		end
	elseif not rawText:match("^%*%*%*+$") then
		return nil
	end
	local div = string.rep("─", RULE_WIDTH)
	return {
		text = div,
		spans = { { start = 0, length = RULE_WIDTH, color = "divider" } },
	}
end

local function matchCheckbox(rawText)
	local pfx, mark, rest = rawText:match("^(%s*[-*]%s+)%[([%sxX])%]%s+(.*)$")
	if not pfx or not mark then
		return nil
	end
	local icon = (mark == " " and "☐ " or "☑ ")
	local isDone = mark ~= " "
	local innerText, innerSpans = parseInline(rest)
	local fullText = pfx .. icon .. innerText
	local startIdx = runeCount(pfx) + runeCount(icon)
	for _, s in ipairs(innerSpans) do
		s.start = s.start + startIdx
	end
	if isDone then
		table.insert(innerSpans, {
			start = startIdx,
			length = runeCount(innerText),
			strike = true,
			color = "comment",
		})
	end
	return { text = fullText, spans = innerSpans }
end

local function matchHeader(rawText)
	local headerPfx, title = rawText:match("^(#+)%s+(.*)$")
	if headerPfx and title then
		-- strip an ATX closing sequence: "# Title #"
		title = title:match("^(.-)%s*#+%s*$") or title
		local innerText, innerSpans = parseInline(title)
		local tlen = runeCount(innerText)
		table.insert(innerSpans, 1, {
			start = 0,
			length = tlen,
			bold = true,
			color = "constant",
		})
		return { text = innerText, spans = innerSpans }
	end
	return nil
end

local function matchQuote(rawText)
	local quote = rawText:match("^>%s*(.*)$")
	if quote then
		local innerText, innerSpans = parseInline(quote)
		local qprefix = "│ "
		local qlen = runeCount(qprefix)
		for _, s in ipairs(innerSpans) do
			s.start = s.start + qlen
		end
		table.insert(innerSpans, {
			start = 0,
			length = qlen + runeCount(innerText),
			italic = true,
			color = "comment",
		})
		return { text = qprefix .. innerText, spans = innerSpans }
	end
	return nil
end

local function parsePrefix(rawText, prevLineText)
	return matchRule(rawText, prevLineText) or matchCheckbox(rawText) or matchHeader(rawText) or matchQuote(rawText)
end

-- per-buffer render state for multi-line constructs. The transform is
-- called top-to-bottom for each window's visible lines on every frame;
-- a lineN reset restarts scanning. Best-effort: a frame that starts
-- mid-document cannot know about fences opened above it, and treats a
-- stray closing fence as a fresh opener so following text stays raw.
local renderState = {}

local function isFenceMarker(rawText)
	return rawText:match("^%s*```+") ~= nil or rawText:match("^%s*~~~+") ~= nil
end

-- advances the per-buffer render state for the current line; returns
-- prevLineText (nil when the previous line was blank) and whether the
-- line must render raw (fence markers and fenced code block content)
local function updateRenderState(bufPath, lineN, rawText)
	local st = renderState[bufPath]
	if st == nil or lineN <= st.line then
		st = { line = lineN, inFence = false, prevText = nil }
	end
	st.line = lineN
	if isFenceMarker(rawText) then
		st.inFence = not st.inFence
		return nil, true
	end
	local prevText = st.prevText
	st.prevText = rawText:match("^%s*$") and nil or rawText
	return prevText, st.inFence
end

-- results are cached per raw line text: the transform runs for every
-- visible line on every frame, and unchanged lines re-parse needlessly
local transformCache = {}
local cacheCount = 0

local function transformMarkdownLine(bufPath, filetype, lineN, rawText)
	if filetype ~= "markdown" or not config.GetGlobalOption("markdown.render") then
		return nil
	end

	local prevText, skip = updateRenderState(bufPath, lineN, rawText)
	if skip then
		return nil
	end

	local cached = transformCache[rawText]
	if cached ~= nil then
		return cached[1]
	end

	local result = parsePrefix(rawText, prevText)
	if result == nil then
		local text, spans = parseInline(rawText)
		if #spans > 0 or text ~= rawText then
			result = { text = text, spans = spans }
		end
	end

	if cacheCount > CACHE_MAX then
		transformCache = {}
		cacheCount = 0
	end
	cacheCount = cacheCount + 1
	transformCache[rawText] = { result }
	return result
end

function init()
	if micro.SetLineTransform then
		micro.SetLineTransform("markdown", transformMarkdownLine)
	end
end
