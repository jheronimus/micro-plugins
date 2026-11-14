local micro = import("micro")
local fmt = import("fmt")
local config = import("micro/config")
local buffer = import("micro/buffer")

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

local function isSpecialLine(trimmed, line)
	if trimmed:sub(1, 1) == "#" or trimmed == "---" or trimmed == "***" then
		return true
	end
	if trimmed:match("^[-*+]%s") or trimmed:match("^%d+%.%s") then
		return true
	end
	return line:match("^%s%s%s%s") ~= nil or line:match("^\t") ~= nil
end

local function reflowDoc(text, limit)
	local lines = {}
	for s in (text .. "\n"):gmatch("(.-)\r?\n") do
		table.insert(lines, s)
	end

	local out = {}
	local para = {}
	local inCode = false

	local function flushPara()
		if #para == 0 then
			return
		end
		local words = {}
		for w in table.concat(para, " "):gmatch("%S+") do
			table.insert(words, w)
		end
		for _, l in ipairs(wrapWords(words, limit)) do
			table.insert(out, l)
		end
		para = {}
	end

	for _, line in ipairs(lines) do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed:sub(1, 3) == "```" then
			flushPara()
			inCode = not inCode
			table.insert(out, line)
		elseif inCode or trimmed == "" or isSpecialLine(trimmed, line) then
			flushPara()
			table.insert(out, line)
		else
			table.insert(para, trimmed)
		end
	end
	flushPara()
	return table.concat(out, "\n")
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
		if micro.ShowOverlay then
			micro.ShowOverlay({
				anchor = "top-right",
				title = "Documentation",
				content = reflowDoc(msg, 72),
				border = true,
				autoclose = true,
				width = 76,
				maxHeight = 28,
			})
		elseif config.GetGlobalOption("lsp.autocompleteDetails") and #mysplit(msg, "\n") > 1 then
			if not splitBP then
				local tmpName = ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"):random(32)
				local logBuf = buffer.NewBuffer(msg, tmpName)
				splitBP = bp:HSplitBuf(logBuf)
				bp:NextSplit()
			else
				splitBP:SelectAll()
				splitBP.Cursor:DeleteSelection()
				splitBP.Cursor:ResetSelection()
				splitBP.Buf:insert(buffer.Loc(1, 1), msg)
			end
		else
			micro.InfoBar():Message(msg)
		end
	end
end
