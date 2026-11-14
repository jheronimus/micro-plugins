VERSION = "1.0.0"

local micro = import("micro")
local config = import("micro/config")

config.RegisterCommonOption("markdown", "render", true)

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

local function matchEmphasis(sub, c)
	if c == "*" then
		local mb = sub:match("^%*%*([^*]+)%*%*")
		if mb then
			return mb, #mb + 4, { bold = true }
		end
		local mi = sub:match("^%*([^*]+)%*")
		if mi then
			return mi, #mi + 2, { italic = true }
		end
	elseif c == "_" then
		local mi = sub:match("^_([^_]+)_")
		if mi then
			return mi, #mi + 2, { italic = true }
		end
	end
	return nil
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
		return matchEmphasis(sub, c)
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
			table.insert(out, ch)
			if (ch:byte() < 128) or (ch:byte() >= 192) then
				currentLen = currentLen + 1
			end
			pos = pos + 1
		end
	end
	return table.concat(out), spans
end

local function matchRule(rawText)
	if rawText:match("^%-%-%-+$") or rawText:match("^%*%*%*+$") then
		local div = string.rep("─", 40)
		return {
			text = div,
			spans = { { start = 0, length = 40, color = "divider" } },
		}
	end
	return nil
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

local function parsePrefix(rawText)
	return matchRule(rawText) or matchCheckbox(rawText) or matchHeader(rawText) or matchQuote(rawText)
end

function transformMarkdownLine(_, filetype, _, isCursorLine, rawText)
	if filetype ~= "markdown" or isCursorLine then
		return nil
	end
	if not config.GetGlobalOption("markdown.render") then
		return nil
	end

	local pfxResult = parsePrefix(rawText)
	if pfxResult then
		return pfxResult
	end

	local text, spans = parseInline(rawText)
	if #spans == 0 and text == rawText then
		return nil
	end
	return { text = text, spans = spans }
end

function init()
	if micro.SetLineTransform then
		micro.SetLineTransform("markdown", transformMarkdownLine)
	end
end
