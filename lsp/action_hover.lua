local micro = import("micro")
local fmt = import("fmt")

-- Renders gopls hover markdown into styled line entries for overlaybox:
-- headings bold, code blocks dimmed, links flattened to their label,
-- reference link definitions dropped, paragraphs re-wrapped.
local function wrapWords(words, limit)
	local lines = {}
	local cur = ""
	for _, w in ipairs(words) do
		if cur == "" then
			cur = w
		elseif #cur + 1 + #w <= limit then
			cur = cur .. " " .. w
		else
			table.insert(lines, cur)
			cur = w
		end
	end
	if cur ~= "" then
		table.insert(lines, cur)
	end
	return lines
end

local function flattenInline(s)
	-- [text][ref] and [text](url) -> text
	s = s:gsub("%[([^%]]*)%]%[[^%]]*%]", "%1")
	s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")
	-- **bold**, *italic*, `code` -> plain text
	s = s:gsub("%*%*([^*]+)%*%*", "%1")
	s = s:gsub("%*([^*]+)%*", "%1")
	s = s:gsub("`([^`]*)`", "%1")
	return s
end

local function isRefDef(line)
	return line:match("^%s*%[[^%]]*%]:%s*%S") ~= nil
end

-- classifies a non-blank, non-code line: returns "para" for plain
-- paragraph text, "drop" for link reference definitions, or the styled
-- entry for headings, rules, and list items
local function classifyLine(trimmed, width)
	if isRefDef(trimmed) then
		return "drop", nil
	end
	local title = trimmed:match("^#+%s+(.*)$")
	if title then
		return "entry", { text = flattenInline(title), bold = true }
	end
	if trimmed:match("^%-%-%-+$") or trimmed:match("^%*%*%*+$") then
		return "entry", { text = string.rep("─", width), color = "divider" }
	end
	if trimmed:match("^[-*+]%s") or trimmed:match("^%d+%.%s") then
		return "entry", flattenInline(trimmed)
	end
	return "para", nil
end

function renderMarkdown(text, width)
	local entries = {}
	local para = {}
	local inCode = false

	local function flushPara()
		if #para == 0 then
			return
		end
		for _, l in ipairs(wrapWords(para, width)) do
			entries[#entries + 1] = l
		end
		para = {}
	end

	for line in (text .. "\n"):gmatch("(.-)\r?\n") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed:sub(1, 3) == "```" then
			flushPara()
			inCode = not inCode
		elseif inCode then
			entries[#entries + 1] = { text = line, color = "comment" }
		elseif trimmed == "" then
			flushPara()
			entries[#entries + 1] = ""
		else
			local kind, entry = classifyLine(trimmed, width)
			if kind == "para" then
				table.insert(para, flattenInline(trimmed))
			else
				flushPara()
				if kind == "entry" then
					entries[#entries + 1] = entry
				end
			end
		end
	end
	flushPara()
	return entries
end

-- the hover action request and response
-- the hoverActionResponse is hooked up in
function hoverAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] ~= nil then
		local send = withSend(filetype)
		local file = bp.Buf.AbsPath
		local line = bp.Buf:GetActiveCursor().Y
		local char = bp.Buf:GetActiveCursor().X
		currentAction[filetype] = { method = "textDocument/hover", response = hoverActionResponse }
		send(
			currentAction[filetype].method,
			fmt.Sprintf(
				'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}',
				file,
				line,
				char
			)
		)
	end
end

function hoverActionResponse(bp, data)
	if data.result and data.result.contents ~= nil and data.result.contents ~= "" then
		local msg = ""
		if data.result.contents.value then
			msg = data.result.contents.value
		elseif #data.result.contents > 0 then
			msg = data.result.contents[1].value
		end
		if overlaybox ~= nil then
			overlaybox.show({
				anchor = "top-right",
				title = "Documentation",
				lines = renderMarkdown(msg, 72),
				border = true,
				autoclose = true,
				width = 76,
				maxHeight = 28,
			})
		else
			micro.InfoBar():Message(msg)
		end
	end
end
