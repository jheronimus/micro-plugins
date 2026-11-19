local micro = import("micro")
local util = import("micro/util")
local buffer = import("micro/buffer")
local fmt = import("fmt")

-- lastSelectedEntry is shared with events.lua (onAnyEvent surfaces the
-- selected candidate's detail through it)
lastSelectedEntry = nil

local function getEntryText(entry)
	if entry.textEdit and entry.textEdit.newText then
		return entry.textEdit.newText
	end
	return entry.label or ""
end

local function shouldIndent(bp, char, line)
	if bp.Cursor:HasSelection() then
		bp:IndentSelection()
		return true
	end
	if char == 0 then
		bp:IndentLine()
		return true
	end
	local cur = bp.Buf:GetActiveCursor()
	cur:SelectLine()
	local lineContent = util.String(cur:GetSelection())
	cur:ResetSelection()
	cur:GotoLoc(buffer.Loc(char, line))
	local startOfLine = "" .. lineContent:sub(1, char)
	if startOfLine:match("^%s+$") then
		bp:IndentLine()
		return true
	end
	return false
end

local function requestCompletion(bp, filetype, file)
	flushDocumentChange(bp, filetype)
	local send = withSend(filetype)
	local line, char = requestPosition(bp)
	send(
		"textDocument/completion",
		fmt.Sprintf(
			'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}',
			file,
			line,
			char
		),
		nil,
		completionActionResponse
	)
end

function completionAction(bp, auto)
	local filetype = bp.Buf:FileType()
	if complete.isActive() then
		complete.accept()
		return
	end

	if auto then
		if cmd[filetype] == nil then
			return
		end
		requestCompletion(bp, filetype, bp.Buf.AbsPath)
		return
	end

	if shouldIndent(bp, bp.Cursor.X, bp.Cursor.Y) then
		return
	end
	if cmd[filetype] == nil then
		bp:InsertTab()
		return
	end
	requestCompletion(bp, filetype, bp.Buf.AbsPath)
end

local function getTriggerChars(filetype)
	local cap = capabilities[filetype]
	if cap and cap.completionProvider then
		return cap.completionProvider.triggerCharacters
	end
	return nil
end

-- find the typed prefix ending at the cursor, split at the last trigger
-- or delimiter character; returns (prefix, rangeStart, found)
local function findPrefixByTriggers(bp, xy, triggerChars)
	local lineBytes = bp.Buf:LineBytes(xy.Y)
	if lineBytes == nil then
		return "", xy, false
	end
	local lineContent = util.String(lineBytes)
	local trimmed = lineContent:gsub("\r?\n$", "")
	local sub = trimmed:sub(1, xy.X)
	local reversed = string.reverse(sub)
	local delimChars = {
		" ",
		":",
		"/",
		"-",
		"\t",
		";",
		"(",
		")",
		"[",
		"]",
		"{",
		"}",
		",",
		"=",
		"+",
		"*",
		"&",
		"|",
		"!",
		"<",
		">",
		"?",
	}
	for i = 1, #reversed do
		local char = reversed:sub(i, i)
		local isTrigger = triggerChars and contains(triggerChars, char)
		if isTrigger or contains(delimChars, char) then
			local cut = #reversed - (i - 1)
			return trimmed:sub(cut + 1, xy.X), buffer.Loc(cut, xy.Y), true
		end
	end
	return sub, buffer.Loc(0, xy.Y), false
end

-- compute where the completion session's replace range starts: an
-- explicit textEdit.range wins; otherwise the typed prefix (including
-- trigger and delimiter characters) is the range. Returns rangeStart.
local function sessionRange(bp, results)
	local cursor = bp.Buf:GetActiveCursor()
	local xy = buffer.Loc(cursor.X, cursor.Y)
	local entry = results[1]
	if entry ~= nil and entry.textEdit ~= nil and entry.textEdit.range ~= nil then
		return buffer.Loc(entry.textEdit.range.start.character, entry.textEdit.range.start.line)
	end
	local triggerChars = getTriggerChars(bp.Buf:FileType())
	if triggerChars == nil then
		return xy
	end
	local prefix, start, found = findPrefixByTriggers(bp, xy, triggerChars)
	if not found and prefix ~= "" then
		start = buffer.Loc(xy.X - util.CharacterCountInString(prefix), xy.Y)
	end
	return start
end

local function startSession(bp, results)
	local rangeStart = sessionRange(bp, results)
	local items = {}
	for _, e in ipairs(results) do
		local detail = e.detail
		if detail == nil and e.labelDetails ~= nil then
			detail = e.labelDetails.description
		end
		items[#items + 1] = {
			label = e.label,
			insertText = getEntryText(e),
			detail = detail,
			entry = e,
		}
	end
	if #items == 0 then
		return
	end
	complete.start(bp, {
		range = { start = rangeStart, ["end"] = buffer.Loc(bp.Cursor.X, bp.Cursor.Y) },
		items = items,
		onAccept = function(item)
			if item.entry ~= nil and item.entry.additionalTextEdits then
				applyEditsToBuffer(bp, item.entry.additionalTextEdits)
			end
			flushDocumentChange(bp, bp.Buf:FileType())
		end,
		onSelect = function(item)
			lastSelectedEntry = item.entry
			showCompletionDetails(item.entry)
			if item.entry ~= nil and item.entry.documentation == nil and cmd[bp.Buf:FileType()] ~= nil then
				requestResolve(bp, bp.Buf:FileType(), item.entry)
			end
		end,
		onClose = function()
			lastSelectedEntry = nil
			flushDocumentChange(bp, bp.Buf:FileType())
		end,
	})
	if complete.isActive() and items[1] ~= nil then
		showCompletionDetails(items[1].entry)
		lastSelectedEntry = items[1].entry
	end
end

local function docExcerpt(entry, count)
	if entry == nil or entry.documentation == nil then
		return nil
	end
	local doc = entry.documentation.value or entry.documentation
	if type(doc) ~= "string" or doc == "" then
		return nil
	end
	return table.concat(firstLines(renderMarkdown(doc, 60), count), "  ·  ")
end

function showCompletionDetails(entry)
	if not entry then
		return
	end
	local text = entry.detail or ""
	local excerpt = docExcerpt(entry, 2)
	if excerpt ~= nil and excerpt ~= "" then
		text = text .. (text ~= "" and "  —  " or "") .. excerpt
	end
	if text ~= "" then
		micro.InfoBar():Message(text)
	end
end

function firstLines(entries, count)
	local parts = {}
	for _, line in ipairs(entries) do
		local text = (type(line) == "table") and line.text or line
		if text ~= "" then
			parts[#parts + 1] = text
			if #parts >= count then
				break
			end
		end
	end
	return parts
end

function resolveActionResponse(bp, data)
	local excerpt = data.result and docExcerpt(data.result, 3)
	if excerpt ~= nil and excerpt ~= "" then
		micro.InfoBar():Message(excerpt)
	end
end

function requestResolve(bp, filetype, entry)
	local send = withSend(filetype)
	send("completionItem/resolve", encodeJson(entry), nil, resolveActionResponse)
end

function completionActionResponse(bp, data)
	local results = data.result
	if results == nil then
		return
	end
	if results.items then
		results = results.items
	end

	table.sort(results, function(left, right)
		return (left.sortText or left.label) < (right.sortText or right.label)
	end)

	if #results == 0 then
		return
	end
	startSession(bp, results)
end
