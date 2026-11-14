local micro = import("micro")
local config = import("micro/config")
local util = import("micro/util")
local buffer = import("micro/buffer")
local fmt = import("fmt")

local lastCompletion = {}
local currentResults = nil
local showCompletionDetails = nil

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
	local send = withSend(filetype)
	lastCompletion = { file, line, char }
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

function completionAction(bp)
	if bp.Buf.HasSuggestions then
		bp.Buf:CycleAutocomplete(true)
		if currentResults and #currentResults > 0 then
			local idx = bp.Buf.CurSuggestion
			local entry = currentResults[(idx % #currentResults) + 1]
			if entry then
				if entry.additionalTextEdits then
					pendingCompletionEdits = entry.additionalTextEdits
				else
					pendingCompletionEdits = nil
				end
				showCompletionDetails(bp, entry)
			end
		end
		return
	end

	local filetype = bp.Buf:FileType()
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X

	if shouldIndent(bp, char, line) then
		return
	end

	if cmd[filetype] == nil then
		bp:InsertTab()
		return
	end

	requestCompletion(bp, filetype, file, line, char)
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

local function createBufferComplete(results)
	return function(buf)
		local completions = {}
		local labels = {}
		for _, entry in ipairs(results) do
			completions[#completions + 1] = getEntryText(entry)
			labels[#labels + 1] = entry.label
		end
		return completions, labels
	end
end

local function getDocumentationText(entry)
	if not entry or (not entry.detail and not entry.documentation) then
		return nil
	end
	local doc = ""
	if entry.documentation then
		doc = entry.documentation.value or entry.documentation
	end
	local detail = entry.detail or ""
	return fmt.Sprintf("%s\n\n%s", detail, doc)
end

local function showDocInSplit(bp, msg)
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
end

showCompletionDetails = function(bp, entry)
	local msg = getDocumentationText(entry)
	if not msg then
		return
	end
	if config.GetGlobalOption("lsp.autocompleteDetails") then
		showDocInSplit(bp, msg)
	else
		local doc = ""
		if entry.documentation then
			doc = entry.documentation.value or entry.documentation
		end
		micro.InfoBar():Message(entry.detail or doc)
	end
end

local function performCompletion(bp, results)
	local xy = buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
	local start = xy
	if bp.Cursor:HasSelection() then
		bp.Cursor:DeleteSelection()
	end
	local prefix = ""
	local reversed = ""
	local found = false
	local entry = results[1]

	local hasRange = results[1] and results[1].textEdit and results[1].textEdit.range
	if not hasRange then
		prefix, start, reversed, found, results = resolvePrefixAndRangeWithoutEdit(bp, xy, results)
	else
		start = resolveRangeWithEdit(bp, xy, entry, reversed, found)
	end

	deletePrefix(bp, prefix)
	bp.Buf:Autocomplete(createBufferComplete(results))
	bp.Cursor:ResetSelection()

	if entry and entry.additionalTextEdits then
		pendingCompletionEdits = entry.additionalTextEdits
	else
		pendingCompletionEdits = nil
	end

	showCompletionDetails(bp, entry)
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
	performCompletion(bp, results)
end
