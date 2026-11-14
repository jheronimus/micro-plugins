local micro = import("micro")
local fmt = import("fmt")
local util = import("micro/util")
local buffer = import("micro/buffer")

local function escapeJsonStr(s)
	if not s then
		return ""
	end
	return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

local function serializeDiagnostic(d)
	local sLine = d.range.start.line
	local sChar = d.range.start.character
	local eLine = d.range["end"].line
	local eChar = d.range["end"].character
	local msg = escapeJsonStr(d.message or "")
	local codePart = ""
	if d.code ~= nil then
		codePart = fmt.Sprintf(', "code": "%s"', escapeJsonStr(tostring(d.code)))
	end
	local sourcePart = ""
	if d.source ~= nil then
		sourcePart = fmt.Sprintf(', "source": "%s"', escapeJsonStr(tostring(d.source)))
	end
	return fmt.Sprintf(
		'{"range": {"start": {"line": %.0f, "character": %.0f}, "end": {"line": %.0f, "character": %.0f}}, "message": "%s"%s%s}',
		sLine,
		sChar,
		eLine,
		eChar,
		msg,
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

local function buildPromptText(results)
	local parts = {}
	for idx, act in ipairs(results) do
		local title = act.title or "Action " .. idx
		if #title > 35 then
			title = title:sub(1, 32) .. "..."
		end
		parts[#parts + 1] = string.format("[%d] %s", idx, title)
	end
	return table.concat(parts, "  ") .. "  Select (1-" .. #results .. "): "
end

local function handleActionSelection(bp, results, resp, canceled)
	if canceled or not resp or resp == "" then
		return
	end
	local idx = tonumber(resp)
	if idx and results[idx] then
		applyCodeAction(bp, results[idx])
	else
		micro.InfoBar():Message("Invalid selection: " .. resp)
	end
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

	local promptStr = buildPromptText(results)
	micro.InfoBar():Prompt(promptStr, "1", "codeaction", nil, function(resp, canceled)
		handleActionSelection(bp, results, resp, canceled)
	end)
end

local function getActionRange(bp)
	local cursor = bp.Buf:GetActiveCursor()
	if bp.Cursor:HasSelection() then
		local selStart = cursor.CurSelection[1]
		local selEnd = cursor.CurSelection[2]
		return selStart.Y, selStart.X, selEnd.Y, selEnd.X
	end
	local line = cursor.Y
	local lineLen = #util.String(bp.Buf:LineBytes(line))
	return line, 0, line, lineLen
end

function codeAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		micro.InfoBar():Message("LSP not active for " .. filetype)
		return
	end

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
