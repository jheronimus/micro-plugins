local micro = import("micro")
local fmt = import("fmt")
local util = import("micro/util")

local function serializeDiagnostic(d)
	local codePart = ""
	if d.code ~= nil then
		codePart = fmt.Sprintf(', "code": %s', encodeJson(tostring(d.code)))
	end
	local sourcePart = ""
	if d.source ~= nil then
		sourcePart = fmt.Sprintf(', "source": %s', encodeJson(tostring(d.source)))
	end
	return fmt.Sprintf(
		'{"range": {"start": {"line": %.0f, "character": %.0f}, "end": {"line": %.0f, "character": %.0f}}, "message": %s%s%s}',
		d.range.start.line,
		d.range.start.character,
		d.range["end"].line,
		d.range["end"].character,
		encodeJson(d.message or ""),
		codePart,
		sourcePart
	)
end

local function serializeDiagnostics(diags)
	local items = {}
	for _, d in ipairs(diags or {}) do
		if d.range and d.range.start and d.range["end"] then
			items[#items + 1] = serializeDiagnostic(d)
		end
	end
	return "[" .. table.concat(items, ", ") .. "]"
end

local function applyCodeAction(bp, action)
	if action.edit then
		local fileEdits = collectChanges(action.edit)
		applyAllChanges(bp, fileEdits, action.title or "code action")
		return
	end
	micro.InfoBar():Message("Code action has no direct edits: " .. (action.title or ""))
end

local function showCodeActionMenu(bp, results)
	if float == nil then
		micro.InfoBar():Message(results[1].title or "Code action available")
		applyCodeAction(bp, results[1])
		return
	end
	local lines = {}
	for idx, act in ipairs(results) do
		lines[#lines + 1] = string.format("%d. %s", idx, act.title or ("Action " .. idx))
	end
	float.show({
		anchor = "cursor",
		title = "Code Actions",
		lines = lines,
		border = true,
		autoclose = true,
		activeItem = 0,
		maxHeight = 10,
		onAccept = function(idx)
			if results[idx + 1] then
				applyCodeAction(bp, results[idx + 1])
			end
		end,
	})
end

local function codeActionResponse(bp, data)
	local results = data.result
	if not results or #results == 0 then
		micro.InfoBar():Message("No code actions available")
		return
	end

	if #results == 1 then
		applyCodeAction(bp, results[1])
		return
	end

	showCodeActionMenu(bp, results)
end

local function getActionRange(bp)
	local cursor = bp.Buf:GetActiveCursor()
	if bp.Cursor:HasSelection() then
		local selStart = cursor.CurSelection[1]
		local selEnd = cursor.CurSelection[2]
		local startText = util.String(bp.Buf:LineBytes(selStart.Y))
		local endText = util.String(bp.Buf:LineBytes(selEnd.Y))
		return selStart.Y, utf16Column(startText, selStart.X), selEnd.Y, utf16Column(endText, selEnd.X)
	end
	local line = cursor.Y
	local lineText = util.String(bp.Buf:LineBytes(line))
	return line, 0, line, utf16Column(lineText)
end

function codeAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		micro.InfoBar():Message("LSP not active for " .. filetype)
		return
	end

	flushDocumentChange(bp, filetype)
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local sLine, sChar, eLine, eChar = getActionRange(bp)
	local diags = getDiagnosticsForRange(file, sLine, eLine)
	local contextJson = fmt.Sprintf('{"diagnostics": %s}', serializeDiagnostics(diags))

	currentAction[filetype] = {
		method = "textDocument/codeAction",
		response = codeActionResponse,
	}

	send(
		currentAction[filetype].method,
		fmt.Sprintf(
			'{"textDocument": {"uri": "file://%s"}, "range": {"start": {"line": %.0f, "character": %.0f}, "end": {"line": %.0f, "character": %.0f}}, "context": %s}',
			file,
			sLine,
			sChar,
			eLine,
			eChar,
			contextJson
		)
	)
end
