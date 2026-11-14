local micro = import("micro")
local util = import("micro/util")
local buffer = import("micro/buffer")
local fmt = import("fmt")

-- currentResults/completionStart/lastSelectedEntry are shared with
-- events.lua (onAnyEvent reads lastSelectedEntry) and overlaybox callbacks.
local currentResults = nil
local completionStart = nil
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

local function requestCompletion(bp, filetype, file, line, char)
	flushDocumentChange(bp, filetype)
	local send = withSend(filetype)
	currentAction[filetype] = { method = "textDocument/completion", response = completionActionResponse }
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

local function isCycling(bp, auto)
	return not auto and overlaybox ~= nil and overlaybox.isActive() and currentResults ~= nil
end

function completionAction(bp, auto)
	local filetype = bp.Buf:FileType()
	local cursor = bp.Buf:GetActiveCursor()

	if isCycling(bp, auto) then
		overlaybox.cycle(1)
		return
	end

	if auto then
		if cmd[filetype] == nil then
			return
		end
		if overlaybox ~= nil and overlaybox.isActive() then
			overlaybox.hide()
		end
		requestCompletion(bp, filetype, bp.Buf.AbsPath, cursor.Y, cursor.X)
		return
	end

	if shouldIndent(bp, cursor.X, cursor.Y) then
		return
	end
	if cmd[filetype] == nil then
		bp:InsertTab()
		return
	end
	requestCompletion(bp, filetype, bp.Buf.AbsPath, cursor.Y, cursor.X)
end

local function getTriggerChars(filetype)
	local cap = capabilities[filetype]
	if cap and cap.completionProvider then
		return cap.completionProvider.triggerCharacters
	end
	return nil
end

local function findPrefixByTriggers(bp, xy, triggerChars)
	local cur = bp.Buf:GetActiveCursor()
	cur:SelectLine()
	local lineContent = util.String(cur:GetSelection())
	local reversed = string.reverse(lineContent:gsub("\r?\n$", ""):sub(1, xy.X))
	local delimChars = { " ", ":", "/", "-", "\t", ";" }
	for i = 1, #reversed do
		local char = reversed:sub(i, i)
		if contains(triggerChars, char) or contains(delimChars, char) then
			local start = buffer.Loc(#reversed - (i - 1), bp.Cursor.Y)
			bp.Cursor:SetSelectionStart(start)
			bp.Cursor:SetSelectionEnd(xy)
			local prefix = util.String(cur:GetSelection())
			bp.Cursor:DeleteSelection()
			bp.Cursor:ResetSelection()
			return prefix, start, reversed, true
		end
	end
	return lineContent:gsub("\r?\n$", ""), xy, reversed, false
end

local function resolvePrefixAndRangeWithoutEdit(bp, xy, results)
	local prefix = ""
	local start = xy
	local reversed = ""
	local found = false
	local triggerChars = getTriggerChars(bp.Buf:FileType())
	if triggerChars then
		prefix, start, reversed, found = findPrefixByTriggers(bp, xy, triggerChars)
	end
	if prefix ~= "" then
		results = table.filter(results, function(e)
			return e.label:starts(prefix)
		end)
	end
	return prefix, start, reversed, found, results
end

local function applySelectionRange(bp, start, xy)
	bp.Cursor:SetSelectionStart(start)
	bp.Cursor:SetSelectionEnd(xy)
	bp.Cursor:DeleteSelection()
	bp.Cursor:ResetSelection()
end

local function resolveFallbackStart(reversed, cursorY)
	if reversed:starts(" ") or reversed:starts("\t") then
		return buffer.Loc(#reversed, cursorY)
	end
	return buffer.Loc(0, cursorY)
end

local function resolveRangeWithEdit(bp, xy, entry, reversed, found)
	if entry and entry.textEdit and entry.textEdit.range then
		local start = buffer.Loc(entry.textEdit.range.start.character, entry.textEdit.range.start.line)
		applySelectionRange(bp, start, xy)
		return start
	end
	local triggerChars = getTriggerChars(bp.Buf:FileType())
	if triggerChars and not found then
		local start = resolveFallbackStart(reversed, bp.Cursor.Y)
		applySelectionRange(bp, start, xy)
		return start
	end
	return xy
end

local function deletePrefix(bp, prefix)
	if #prefix > 0 then
		local xy = buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
		local nstart = buffer.Loc(bp.Cursor.X - #prefix, bp.Cursor.Y)
		bp.Cursor:GotoLoc(nstart)
		bp.Cursor:SetSelectionStart(nstart)
		bp.Cursor:SetSelectionEnd(xy)
		bp.Cursor:DeleteSelection()
	end
end

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

local function insertCompletion(bp, loc, text)
	bp.Buf:Insert(loc, text)
	bp.Cursor:GotoLoc(advanceLoc(loc, text))
end

local function replaceInserted(bp, entry)
	if completionStart == nil then
		return
	end
	local cur = bp.Buf:GetActiveCursor()
	local endLoc = buffer.Loc(cur.X, cur.Y)
	cur:SetSelectionStart(completionStart)
	cur:SetSelectionEnd(endLoc)
	cur:DeleteSelection()
	cur:ResetSelection()
	insertCompletion(bp, completionStart, getEntryText(entry))
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

local function applyEntry(bp, idx)
	local entry = currentResults and currentResults[idx + 1]
	if entry == nil or idx == 0 then
		return
	end
	replaceInserted(bp, entry)
	if entry.additionalTextEdits then
		applyEditsToBuffer(bp, entry.additionalTextEdits)
	end
end

local function startCompletion(bp, results)
	local xy = buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
	local start = xy
	local reversed = ""
	local found = false
	local entry = results[1]

	local hasRange = entry and entry.textEdit and entry.textEdit.range
	if not hasRange then
		local prefix
		prefix, start, reversed, found, results = resolvePrefixAndRangeWithoutEdit(bp, xy, results)
		-- findPrefixByTriggers already deleted the prefix when it matched a
		-- trigger character; only the untriggered prefix is still in-buffer
		if not found then
			deletePrefix(bp, prefix)
		end
	else
		start = resolveRangeWithEdit(bp, xy, entry, reversed, found)
	end
	entry = results[1]
	if entry == nil then
		-- every candidate was filtered out by the prefix match
		return
	end

	local text = getEntryText(entry)
	insertCompletion(bp, start, text)
	completionStart = start
	if entry.additionalTextEdits then
		applyEditsToBuffer(bp, entry.additionalTextEdits)
	end

	showCompletionDetails(entry)
	if overlaybox ~= nil and #results > 1 then
		showCompletionMenu(bp, bp.Buf:FileType(), results)
	end
end

function completionLabel(e)
	local detail = e.detail
	if detail == nil and e.labelDetails ~= nil then
		detail = e.labelDetails.description
	end
	if detail ~= nil and detail ~= "" then
		return e.label .. "  " .. detail
	end
	return e.label
end

function showCompletionMenu(bp, filetype, results)
	local labels = {}
	for _, e in ipairs(results) do
		labels[#labels + 1] = completionLabel(e)
	end
	overlaybox.show({
		anchor = "cursor",
		lines = labels,
		activeItem = 0,
		onSelect = function(idx)
			if currentResults == nil then
				return
			end
			local selected = currentResults[idx + 1]
			lastSelectedEntry = selected
			if selected ~= nil and selected.documentation == nil and cmd[filetype] ~= nil then
				requestResolve(bp, filetype, selected)
			end
		end,
		onAccept = function(idx)
			applyEntry(bp, idx)
		end,
		onClose = function()
			currentResults = nil
			completionStart = nil
			lastSelectedEntry = nil
		end,
	})
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
	currentAction[filetype] = { method = "completionItem/resolve", response = resolveActionResponse }
	send(currentAction[filetype].method, encodeJson(entry))
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

	currentResults = results
	if #results == 0 then
		return
	end
	startCompletion(bp, results)
end
