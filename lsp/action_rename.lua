local micro = import("micro")
local buffer = import("micro/buffer")
local fmt = import("fmt")

local function sortEdits(edits)
	table.sort(edits, function(left, right)
		return left.range["end"].line > right.range["end"].line
			or left.range["end"].line == right.range["end"].line and left.range["end"].character > right.range["end"].character
			or left.range["end"].line == right.range["end"].line
				and left.range["end"].character == right.range["end"].character
				and left.range.start.line == left.range["end"].line
				and left.range.start.character > right.range.start.character
	end)
end

local function applyEditsToBuffer(pane, edits)
	sortEdits(edits)
	local xy = buffer.Loc(pane.Cursor.X, pane.Cursor.Y)
	for _, edit in ipairs(edits) do
		local rStart = buffer.Loc(edit.range.start.character, edit.range.start.line)
		local rEnd = buffer.Loc(edit.range["end"].character, edit.range["end"].line)
		pane.Cursor:GotoLoc(rStart)
		pane.Cursor:SetSelectionStart(rStart)
		pane.Cursor:SetSelectionEnd(rEnd)
		pane.Cursor:DeleteSelection()
		pane.Cursor:ResetSelection()
		if edit.newText ~= "" then
			pane.Buf:insert(rStart, edit.newText)
		end
	end
	pane.Cursor:GotoLoc(xy)
end

local function normalizeUri(rawUri)
	return rawUri:gsub("^file://", ""):gsub("%%[a-f0-9][a-f0-9]", function(x)
		return string.char(tonumber(x:gsub("%%", ""), 16))
	end)
end

local function collectChanges(result)
	local fileEdits = {}
	if result.changes then
		for uri, edits in pairs(result.changes) do
			fileEdits[normalizeUri(uri)] = edits
		end
	elseif result.documentChanges then
		for _, docChange in ipairs(result.documentChanges) do
			if docChange.textDocument and docChange.edits then
				fileEdits[normalizeUri(docChange.textDocument.uri)] = docChange.edits
			end
		end
	end
	return fileEdits
end

local function applyAllChanges(bp, fileEdits, newName)
	local totalFiles = 0
	local currentPath = bp.Buf.AbsPath

	for path, edits in pairs(fileEdits) do
		totalFiles = totalFiles + 1
		if path == currentPath then
			applyEditsToBuffer(bp, edits)
			onRune(bp)
		else
			local otherBuf, err = buffer.NewBufferFromFile(path)
			if err == nil then
				bp:AddTab()
				local newPane = micro.CurPane()
				newPane:OpenBuffer(otherBuf)
				applyEditsToBuffer(newPane, edits)
				newPane:Save()
			end
		end
	end

	if totalFiles > 0 then
		micro.InfoBar():Message("Renamed to " .. newName .. " in " .. totalFiles .. " file(s)")
	else
		micro.InfoBar():Message("No occurrences found to rename")
	end
end

local function renameActionResponse(newName)
	return function(bp, data)
		if data.result == nil then
			micro.InfoBar():Message("No rename changes returned by LSP")
			return
		end
		local fileEdits = collectChanges(data.result)
		applyAllChanges(bp, fileEdits, newName)
	end
end

local function sendRename(bp, newName)
	local filetype = bp.Buf:FileType()
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X

	currentAction[filetype] = {
		method = "textDocument/rename",
		response = renameActionResponse(newName),
	}
	send(
		currentAction[filetype].method,
		fmt.Sprintf(
			'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}, "newName": "%s"}',
			file,
			line,
			char,
			newName
		)
	)
end

function renameAction(bp, args)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		micro.InfoBar():Message("LSP not active for " .. filetype)
		return
	end

	if args and #args > 0 then
		sendRename(bp, args[1])
	else
		micro.InfoBar():Prompt("New name: ", "", "rename", nil, function(resp, canceled)
			if canceled or resp == "" then
				return
			end
			sendRename(bp, resp)
		end)
	end
end
