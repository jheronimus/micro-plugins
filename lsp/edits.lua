local micro = import("micro")
local buffer = import("micro/buffer")

function sortEdits(edits)
	table.sort(edits, function(left, right)
		local lEnd = left.range["end"]
		local rEnd = right.range["end"]
		if lEnd.line ~= rEnd.line then
			return lEnd.line > rEnd.line
		end
		if lEnd.character ~= rEnd.character then
			return lEnd.character > rEnd.character
		end
		local lStart = left.range.start
		local rStart = right.range.start
		if lStart.line ~= rStart.line then
			return lStart.line > rStart.line
		end
		return lStart.character > rStart.character
	end)
end

local function countNewlines(str)
	local count = 0
	for _ in str:gmatch("\n") do
		count = count + 1
	end
	return count
end

function applySingleEdit(pane, edit)
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

function applyEditsToBuffer(pane, edits)
	if not edits or #edits == 0 then
		return
	end
	sortEdits(edits)
	local origX = pane.Cursor.X
	local origY = pane.Cursor.Y
	local lineDelta = 0

	for _, edit in ipairs(edits) do
		if edit.range["end"].line <= origY then
			local deletedLines = edit.range["end"].line - edit.range.start.line
			local addedLines = countNewlines(edit.newText or "")
			lineDelta = lineDelta + (addedLines - deletedLines)
		end
		applySingleEdit(pane, edit)
	end

	local newY = origY + lineDelta
	if newY < 0 then
		newY = 0
	end
	pane.Cursor:GotoLoc(buffer.Loc(origX, newY))
end

function collectChanges(result)
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

local function applyToOtherBuffer(bp, path, edits)
	local otherBuf, err = buffer.NewBufferFromFile(path)
	if err == nil then
		bp:AddTab()
		local newPane = micro.CurPane()
		newPane:OpenBuffer(otherBuf)
		applyEditsToBuffer(newPane, edits)
		newPane:Save()
	end
end

function applyAllChanges(bp, fileEdits, label)
	local totalFiles = 0
	local currentPath = bp.Buf.AbsPath

	for path, edits in pairs(fileEdits) do
		totalFiles = totalFiles + 1
		if path == currentPath then
			applyEditsToBuffer(bp, edits)
			onRune(bp)
		else
			applyToOtherBuffer(bp, path, edits)
		end
	end

	if totalFiles > 0 then
		micro.InfoBar():Message("Applied: " .. label)
	else
		micro.InfoBar():Message("No changes to apply")
	end
end
