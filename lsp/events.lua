local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local util = import("micro/util")
local buffer = import("micro/buffer")
local fmt = import("fmt")
local version = {}

function preRune(bp, r)
	if splitBP ~= nil then
		pcall(function()
			splitBP:Unsplit()
		end)
		splitBP = nil
		local cur = bp.Buf:GetActiveCursor()
		cur:Deselect(false)
		cur:GotoLoc(buffer.Loc(cur.X + 1, cur.Y))
	end
end

local function sendDocumentChange(bp, filetype, r)
	local send = withSend(filetype)
	local uri = getUriFromBuf(bp.Buf)
	if r ~= nil then
		lastCompletion = {}
	end
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

local function shouldTriggerHover(cap, ignored, r)
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
		completionAction(bp)
	elseif shouldTriggerHover(cap, ignored, r) then
		hoverAction(bp)
	end
end

-- when a new character is types, the document changes
function onRune(bp, r)
	local filetype = bp.Buf:FileType()
	micro.Log("FILETYPE", filetype)
	if cmd[filetype] == nil then
		return
	end
	if splitBP ~= nil then
		pcall(function()
			splitBP:Unsplit()
		end)
		splitBP = nil
	end

	sendDocumentChange(bp, filetype, r)
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

function onEscape(bp)
	if splitBP ~= nil then
		pcall(function()
			splitBP:Unsplit()
		end)
		splitBP = nil
	end
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
	local filetype = bp.Buf:FileType()
	if filetype == "go" then
		return
	end
	if config.GetGlobalOption("lsp.formatOnSave") then
		onRune(bp)
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
	shell.JobSend(cmd[filetype], fmt.Sprintf("Content-Length: %.0f\n\n%s", #res, res))
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

local function handlePublishDiagnostics(data)
	local cur = micro.CurPane()
	if cur == nil or cur.Buf == nil then
		return
	end
	local bp = cur.Buf
	bp:ClearMessages("lsp")
	bp:AddMessage(buffer.NewMessage("lsp", "", buffer.Loc(0, 10000000), buffer.Loc(0, 10000000), buffer.MTInfo))
	local uri = getUriFromBuf(bp)
	if data.params.uri ~= uri then
		return
	end
	for _, diagnostic in ipairs(data.params.diagnostics) do
		applyDiagnosticMessage(bp, diagnostic)
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
	local cleanMsg = msg:gsub("}Content%-Length:", "}\0Content-Length:")
	local entries = mysplit(cleanMsg, "\0")
	if #entries > 1 then
		micro.Log("Found break")
		return entries[1], entries[2]
	end
	return cleanMsg, nil
end

function onStdout(filetype)
	local nextMessage = ""
	return function(text)
		if text:starts("Content-Length:") then
			message = text
		else
			message = message .. text
		end
		local currentMsg, nextMsg = extractNextMessage(message)
		message = currentMsg
		if nextMsg then
			nextMessage = nextMsg
		end
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

		if nextMessage then
			local nm = nextMessage
			nextMessage = nil
			onStdout(filetype)(nm)
		end
	end
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
