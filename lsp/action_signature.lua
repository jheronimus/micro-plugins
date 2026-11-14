local micro = import("micro")
local fmt = import("fmt")

local function highlightParam(label, paramLabel)
	if type(paramLabel) ~= "string" or paramLabel == "" then
		return label
	end
	local s, e = label:find(paramLabel, 1, true)
	if s then
		return label:sub(1, s - 1) .. "[" .. paramLabel .. "]" .. label:sub(e + 1)
	end
	return label
end

local function formatSignature(sig, activeParam)
	if not sig or not sig.label then
		return ""
	end
	local label = sig.label
	local params = sig.parameters
	if not params or #params == 0 then
		return label
	end

	local pIdx = (activeParam or 0) + 1
	local activeP = params[pIdx]
	if activeP and activeP.label then
		return highlightParam(label, activeP.label)
	end
	return label
end

local function signatureActionResponse(bp, data)
	local res = data.result
	if not res or not res.signatures or #res.signatures == 0 then
		return
	end

	local sIdx = (res.activeSignature or 0) + 1
	local sig = res.signatures[sIdx] or res.signatures[1]
	local activeParam = res.activeParameter or (sig and sig.activeParameter) or 0
	local msg = formatSignature(sig, activeParam)

	if msg ~= "" then
		micro.InfoBar():Message(msg)
	end
end

function signatureAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end

	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X

	currentAction[filetype] = {
		method = "textDocument/signatureHelp",
		response = signatureActionResponse,
	}

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
