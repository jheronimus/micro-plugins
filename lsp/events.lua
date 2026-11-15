local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local util = import("micro/util")
local buffer = import("micro/buffer")
local fmt = import("fmt")
local overlayOk, overlay = pcall(import, "micro/overlay")
version = version or {}
rawDiagnostics = rawDiagnostics or {}

function getDiagnosticsForRange(uri, startLine, endLine)
	local uriDiags = rawDiagnostics[normalizeUri(uri)] or {}
	local matched = {}
	for _, d in ipairs(uriDiags) do
		if d.range and d.range.start and d.range["end"] then
			if d.range["end"].line >= startLine and d.range.start.line <= endLine then
				table.insert(matched, d)
			end
		end
	end
	return matched
end

local function sendDocumentChange(bp, filetype)
	local send = withSend(filetype)
	local uri = getUriFromBuf(bp.Buf)
	-- allow the document contents to be escaped properly for the JSON string
	local content = util.String(bp.Buf:Bytes())
		:gsub("\\", "\\\\")
		:gsub("\n", "\\n")
		:gsub("\r", "\\r")
		:gsub('"', '\\"')
		:gsub("\t", "\\t")
	-- increase change version
	version[uri] = (version[uri] or 0) + 1
	send(
		"textDocument/didChange",
		fmt.Sprintf(
			'{"textDocument": {"version": %.0f, "uri": "%s"}, "contentChanges": [{"text": "%s"}]}',
			version[uri],
			uri,
			content
		),
		true
	)
end

local function shouldTriggerCompletion(cap, ignored, r)
	if contains(ignored, "completion") or not cap.completionProvider then
		return false
	end
	local triggers = cap.completionProvider.triggerCharacters
	return triggers and contains(triggers, r)
end

local function shouldTriggerSignature(cap, ignored, r)
	if contains(ignored, "signature") or not cap.signatureHelpProvider then
		return false
	end
	local triggers = cap.signatureHelpProvider.triggerCharacters
	return triggers and contains(triggers, r)
end

local function checkTriggerCharacters(bp, filetype, r)
	if not (r and capabilities[filetype]) then
		return
	end
	local ignored = mysplit(config.GetGlobalOption("lsp.ignoreTriggerCharacters") or "", ",")
	local cap = capabilities[filetype]
	if shouldTriggerCompletion(cap, ignored, r) then
		completionAction(bp, true)
	elseif shouldTriggerSignature(cap, ignored, r) then
		signatureAction(bp)
	end
end

-- didChange notifications are debounced: mark the buffer dirty and send
-- its current text once after the editor has been idle for a moment
-- (Neovim's debounce_text_changes default is 150ms)
local changePending = {}

local function scheduleDocumentChange(bp, filetype)
	if changePending[filetype] then
		return
	end
	changePending[filetype] = true
	micro.After(150, function()
		changePending[filetype] = nil
		if cmd[filetype] ~= nil and bp ~= nil and bp.Buf ~= nil then
			sendDocumentChange(bp, filetype)
		end
	end)
end

-- send any pending document text right away; used before requests that
-- must observe the current buffer (completion, signature help)
function flushDocumentChange(bp, filetype)
	changePending[filetype] = nil
	if cmd[filetype] ~= nil and bp ~= nil and bp.Buf ~= nil then
		sendDocumentChange(bp, filetype)
	end
end

-- when a new character is types, the document changes
function onRune(bp, r)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end

	scheduleDocumentChange(bp, filetype)
	checkTriggerCharacters(bp, filetype, r)
end

-- alias functions for any kind of change to the document
function onMoveLinesUp(bp)
	onRune(bp)
end

function onMoveLinesDown(bp)
	onRune(bp)
end

function onDeleteWordRight(bp)
	onRune(bp)
end

function onDeleteWordLeft(bp)
	onRune(bp)
end

function onInsertNewline(bp)
	onRune(bp)
end

function onInsertSpace(bp)
	onRune(bp)
end

function onBackspace(bp)
	onRune(bp)
end

function onDelete(bp)
	onRune(bp)
end

function onInsertTab(bp)
	onRune(bp)
end

function onUndo(bp)
	onRune(bp)
end

function onRedo(bp)
	onRune(bp)
end

function onCut(bp)
	onRune(bp)
end

function onCutLine(bp)
	onRune(bp)
end

function onDuplicateLine(bp)
	onRune(bp)
end

function onDeleteLine(bp)
	onRune(bp)
end

function onIndentSelection(bp)
	onRune(bp)
end

function onOutdentSelection(bp)
	onRune(bp)
end

function onOutdentLine(bp)
	onRune(bp)
end

function onIndentLine(bp)
	onRune(bp)
end

function onPaste(bp)
	onRune(bp)
end

function onPlayMacro(bp)
	onRune(bp)
end

function onAutocomplete(bp)
	onRune(bp)
end

function preInsertNewline(bp)
	if bp.Buf.Path == "References found" then
		local cur = bp.Buf:GetActiveCursor()
		cur:SelectLine()
		local data = util.String(cur:GetSelection())
		local file, line, character = data:match("(./[^:]+):([^:]+):([^:]+)")
		if not file then
			return false
		end
		local doc, _ = file:gsub("^file://", "")
		local buf, _ = buffer.NewBufferFromFile(doc)
		bp:AddTab()
		micro.CurPane():OpenBuffer(buf)
		buf:GetActiveCursor():GotoLoc(buffer.Loc(character * 1, line * 1))
		micro.CurPane():Center()
		return false
	end
end

function preSave(bp)
	if config.GetGlobalOption("lsp.formatOnSave") then
		-- send the current document immediately so the format request sees
		-- the up-to-date text rather than waiting for the debounce
		local filetype = bp.Buf:FileType()
		if cmd[filetype] ~= nil then
			sendDocumentChange(bp, filetype)
		end
		formatAction(bp, function()
			bp:Save()
		end)
	end
end

function onSave(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end

	sendDocumentChange(bp, filetype)

	local send = withSend(filetype)
	local uri = getUriFromBuf(bp.Buf)

	send("textDocument/didSave", fmt.Sprintf('{"textDocument": {"uri": "%s"}}', uri), true)
end

function onBufferOpen(buf)
	local filetype = buf:FileType()
	micro.Log("ONBUFFEROPEN", filetype)
	if filetype ~= "unknown" and not cmd[filetype] then
		return startServer(filetype, handleInitialized, buf)
	end
	if cmd[filetype] then
		handleInitialized(buf, filetype)
	end
end

local function handleWorkspaceConfig(filetype, data)
	local res = fmt.Sprintf('{"jsonrpc": "2.0", "id": %.0f, "result": [{"enable": true}]}', data.id)
	shell.JobSend(cmd[filetype], fmt.Sprintf("Content-Length: %.0f\r\n\r\n%s", #res, res))
end

local function applyDiagnosticMessage(bp, diagnostic)
	local mtype = buffer.MTInfo
	if diagnostic.severity == 1 then
		mtype = buffer.MTError
	elseif diagnostic.severity == 2 then
		mtype = buffer.MTWarning
	end
	local mstart = buffer.Loc(diagnostic.range.start.character, diagnostic.range.start.line)
	local mend = buffer.Loc(diagnostic.range["end"].character, diagnostic.range["end"].line)

	if not isIgnoredMessage(diagnostic.message) then
		local msg = buffer.NewMessage("lsp", diagnostic.message, mstart, mend, mtype)
		bp:AddMessage(msg)
	end
end

local function collectPaneBuffers(tab, targetPath, matched)
	if not tab.Panes then
		return
	end
	for i = 1, #tab.Panes do
		local pane = tab.Panes[i]
		if pane.Buf and pane.Buf.AbsPath == targetPath then
			table.insert(matched, pane.Buf)
		end
	end
end

local function findBuffersByUri(targetUri)
	local targetPath = normalizeUri(targetUri)
	local matched = {}
	local tabs = micro.Tabs()
	if not tabs or not tabs.List then
		return matched
	end
	for i = 1, #tabs.List do
		local tab = tabs.List[i]
		collectPaneBuffers(tab, targetPath, matched)
	end
	return matched
end

local function isOutdatedDiagnostic(data)
	local docVersion = data.params.version
	local targetUri = data.params.uri
	return docVersion ~= nil and version[targetUri] ~= nil and docVersion < version[targetUri]
end

local function updateBufferDiagnostics(buf, diagnostics)
	buf:ClearMessages("lsp")
	for _, diagnostic in ipairs(diagnostics or {}) do
		applyDiagnosticMessage(buf, diagnostic)
	end
end

local function handlePublishDiagnostics(data)
	if not data.params or not data.params.uri then
		return
	end
	if isOutdatedDiagnostic(data) then
		micro.Log("Dropping outdated diagnostics for", data.params.uri)
		return
	end
	rawDiagnostics[normalizeUri(data.params.uri)] = data.params.diagnostics or {}
	local bufs = findBuffersByUri(data.params.uri)
	if #bufs == 0 and micro.CurPane() ~= nil and micro.CurPane().Buf ~= nil then
		local curBuf = micro.CurPane().Buf
		if normalizeUri(data.params.uri) == curBuf.AbsPath then
			table.insert(bufs, curBuf)
		end
	end
	for _, buf in ipairs(bufs) do
		updateBufferDiagnostics(buf, data.params.diagnostics)
	end
end

local function handleWindowShowMessage(filetype, data)
	if micro.CurPane() ~= nil and micro.CurPane().Buf ~= nil and filetype == micro.CurPane().Buf:FileType() then
		micro.InfoBar():Message(data.params.message)
	else
		micro.Log(filetype .. " message " .. data.params.message)
	end
end

local function handleCustomAction(filetype, data)
	local bp = micro.CurPane()
	micro.Log("Received message for ", filetype, data)
	currentAction[filetype].response(bp, data)
	currentAction[filetype] = {}
end

local function isPublishDiagnostics(method)
	return method == "textDocument/publishDiagnostics" or method == "textDocument\\/publishDiagnostics"
end

local function isApplyEdit(method)
	return method == "workspace/applyEdit" or method == "workspace\\/applyEdit"
end

-- server-initiated edit (e.g. from rename or organize imports); apply it
-- and reply to the server request with its own id
local function handleApplyEdit(filetype, data)
	local bp = micro.CurPane()
	if data.params == nil or data.params.edit == nil then
		return
	end
	if bp ~= nil and bp.Buf ~= nil then
		local fileEdits = collectChanges(data.params.edit)
		applyAllChanges(bp, fileEdits, "workspace edit")
	end
	if cmd[filetype] ~= nil and data.id ~= nil then
		local res = fmt.Sprintf('{"jsonrpc": "2.0", "id": %.0f, "result": {"applied": true}}', data.id)
		shell.JobSend(cmd[filetype], fmt.Sprintf("Content-Length: %.0f\r\n\r\n%s", #res, res))
	end
end

local function isShowMessage(method)
	return method == "window/showMessage" or method == "window\\/showMessage"
end

local function isLogMessage(method)
	return method == "window/logMessage" or method == "window\\/logMessage"
end

local function isCustomAction(filetype, data)
	local action = currentAction[filetype]
	return action and action.method and not data.method and action.response and data.jsonrpc
end

local function handleLspMessage(filetype, data, rawMessage)
	if data.method == "workspace/configuration" then
		handleWorkspaceConfig(filetype, data)
	elseif isApplyEdit(data.method) then
		handleApplyEdit(filetype, data)
	elseif isPublishDiagnostics(data.method) then
		handlePublishDiagnostics(data)
	elseif isCustomAction(filetype, data) then
		handleCustomAction(filetype, data)
	elseif isShowMessage(data.method) then
		handleWindowShowMessage(filetype, data)
	elseif isLogMessage(data.method) then
		micro.Log(data.params.message)
	elseif rawMessage:starts("Content-Length:") then
		if rawMessage:find('"') and not rawMessage:find('"result":null') then
			micro.Log("Unhandled message 1", filetype, rawMessage, currentAction[filetype])
		end
	else
		micro.Log("Unhandled message 2", filetype, rawMessage)
	end
end

local function extractNextMessage(msg)
	local s = msg:find("}%s*Content%-Length:")
	if s then
		local current = msg:sub(1, s)
		local nextMsg = msg:sub(s + 1):match("^%s*(.-)$")
		return current, nextMsg
	end
	return msg, nil
end

function onStdout(filetype)
	local message = ""
	local handler
	handler = function(text)
		if text:starts("Content-Length:") then
			message = text
		else
			message = message .. text
		end
		local currentMsg, nextMsg = extractNextMessage(message)
		message = currentMsg
		if not message:ends("}") then
			micro.Log("Message incomplete, ignoring for now...")
			return
		end
		local data = message:parse()
		if data == false then
			micro.Log("Parsing failed", message)
			return
		end

		micro.Log(filetype .. " <<< " .. (data.method or "no method"))
		handleLspMessage(filetype, data, message)

		if nextMsg and #nextMsg > 0 then
			handler(nextMsg)
		end
	end
	return handler
end

function onStderr(text)
	micro.Log("ONSTDERR", text)
	if not isIgnoredMessage(text) then
		micro.InfoBar():Message(text)
	end
end

function onExit(filetype)
	return function(str)
		currentAction[filetype] = nil
		cmd[filetype] = nil
		micro.Log("ONEXIT", filetype, str)
	end
end

-- Inline diagnostics drawn as an overlay (POC for the micro/overlay API;
-- no line transforms involved). For each visible buffer pane with
-- diagnostics, the highest-severity message per line is appended after
-- the end of that line, colored by severity.
local DIAG_MSG_MAX = 60

local function diagStyle(severity)
	local color = (severity == 1) and "red" or "yellow"
	local ok, style = pcall(overlay.StringToStyle, color)
	if not ok then
		return overlay.Style()
	end
	return style
end

local function bestDiagForLine(current, d)
	local msg = d.message or ""
	if isIgnoredMessage(msg) then
		return current
	end
	local severity = d.severity or 1
	if current ~= nil and current.severity <= severity then
		return current
	end
	return { message = msg:match("^[^\r\n]+") or msg, severity = severity }
end

local function firstDiagPerLine(diags)
	local byLine = {}
	for _, d in ipairs(diags) do
		if d.range and d.range.start then
			local line = d.range.start.line
			byLine[line] = bestDiagForLine(byLine[line], d)
		end
	end
	return byLine
end

local function drawPaneDiagnostics(bp)
	local diags = rawDiagnostics[bp.Buf.AbsPath] or {}
	if #diags == 0 then
		return
	end
	if not config.GetGlobalOption("lsp.inlineDiagnostics") then
		return
	end
	local view = bp:GetView()
	local byLine = firstDiagPerLine(diags)
	local cursorLine = -1
	if bp == micro.CurPane() then
		cursorLine = bp.Buf:GetActiveCursor().Y
	end
	for line, diag in pairs(byLine) do
		drawDiagSuffix(bp, line, diag, view, line == cursorLine)
	end
end

-- whether a suffix drawn at (x, y) spanning `width` cells would overlap
-- an open float window: this overlay draws after float's (later handles
-- paint on top), so overlapping suffixes are skipped rather than painting
-- over the window
local function overlapsFloat(x, y, width)
	local fr = (float ~= nil and float.rect ~= nil) and float.rect() or nil
	if fr == nil then
		return false
	end
	return y >= fr.y and y < fr.y + fr.h and x < fr.x + fr.w and x + width > fr.x
end

-- onCursorLine is rendered with the cursor-line background so the suffix
-- blends with micro's cursor-line highlight instead of painting an opaque
-- band over it. micro themes define such highlight groups as
-- 'color-link group "#color"' with the color in the foreground slot, so
-- the composed background comes from Decompose()'s fg (falling back to bg
-- for 'fg,bg' style definitions).
function drawDiagSuffix(bp, line, diag, view, onCursorLine)
	local lineLen = util.CharacterCountInString(util.String(bp.Buf:LineBytes(line)))
	local endPos = overlay.BufPaneScreenLoc(bp, buffer.Loc(lineLen, line))
	if endPos.Y < view.Y or endPos.Y >= view.Y + view.Height then
		return
	end
	local msg = diag.message
	if #msg > DIAG_MSG_MAX then
		msg = msg:sub(1, DIAG_MSG_MAX - 3) .. "..."
	end
	-- width must match the text exactly: DrawText fills its whole width
	-- with the style background, and an oversized fill would paint a band
	-- over any overlay drawn beneath (draw order between overlays is not
	-- guaranteed)
	local text = "  // " .. msg
	local width = util.CharacterCountInString(text)
	if overlapsFloat(endPos.X, endPos.Y, width) then
		return
	end
	local style = diagStyle(diag.severity)
	if onCursorLine then
		local fg, bg = overlay.GetColor("cursor-line"):Decompose()
		style = style:Background((fg ~= 0) and fg or bg)
	end
	overlay.DrawText(text, endPos.X, endPos.Y, width, 1, style)
end

function drawInlineDiagnostics()
	if overlay == nil or micro.CurPane() == nil then
		return
	end
	local tab = micro.CurTab()
	if tab == nil or tab.Panes == nil then
		return
	end
	for i = 1, #tab.Panes do
		local pane = tab.Panes[i]
		if pane.Buf ~= nil and pane.Buf.AbsPath ~= nil and pane.Buf:FileType() ~= "unknown" then
			drawPaneDiagnostics(pane)
		end
	end
end

-- Show the diagnostic for the line the cursor moved to in the info bar
-- (the overlay suffixes skip nothing, but a full untruncated message for
-- the active line is what Helix/Neovim surface on the cursor line).
local lastDiagLine = nil
local lastDiagPath = nil
-- lastShownEntry/lastSelectedEntry are cross-file state shared with
-- action_completion.lua: the completion menu updates lastSelectedEntry as
-- the user cycles, and onAnyEvent below surfaces its detail when it
-- changes.
lastShownEntry = nil

local function diagMessage(path, line)
	local diags = rawDiagnostics[path]
	if diags == nil then
		return nil
	end
	local diag = firstDiagPerLine(diags)[line]
	if diag == nil then
		return nil
	end
	return (diag.severity == 1 and "error: " or "warning: ") .. diag.message
end

local function currentBufferCursor()
	local bp = micro.CurPane()
	if bp == nil or bp.Buf == nil or bp.Buf.AbsPath == nil then
		return nil
	end
	return bp, bp.Buf.AbsPath, bp.Buf:GetActiveCursor().Y
end

function onAnyEvent()
	local bp, path, line = currentBufferCursor()
	if bp == nil then
		return
	end

	if float ~= nil and float.isActive() then
		-- completion menu is open: surface the selected item's detail and
		-- documentation. Messages set while an action runs are cleared by
		-- the action pipeline; onAnyEvent runs after it, so its message
		-- survives the draw.
		if lastSelectedEntry ~= nil and lastShownEntry ~= lastSelectedEntry then
			lastShownEntry = lastSelectedEntry
			showCompletionDetails(lastSelectedEntry)
		end
		return
	end
	if line == lastDiagLine and path == lastDiagPath then
		return
	end
	lastDiagLine = line
	lastDiagPath = path
	local msg = diagMessage(path, line)
	if msg ~= nil then
		micro.InfoBar():Message(msg)
	end
end
