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

local function getSigDoc(sig)
	if not sig or not sig.documentation then
		return nil
	end
	local doc = sig.documentation
	if type(doc) == "table" and doc.value then
		doc = doc.value
	end
	if type(doc) == "string" and doc ~= "" then
		return doc
	end
	return nil
end

local function resolveActiveSignature(res)
	if not res or not res.signatures or #res.signatures == 0 then
		return nil, 0
	end
	local sIdx = (res.activeSignature or 0) + 1
	local sig = res.signatures[sIdx] or res.signatures[1]
	local param = res.activeParameter or 0
	if param == 0 and sig and sig.activeParameter then
		param = sig.activeParameter
	end
	return sig, param
end

local function displaySignature(msg, sig)
	if float == nil then
		micro.InfoBar():Message(msg)
		return
	end
	local doc = getSigDoc(sig)
	local content = msg
	if doc then
		content = content .. "\n\n" .. doc
	end
	float.show({
		anchor = "cursor",
		content = content,
		border = true,
		autoclose = true,
		maxHeight = 8,
	})
end

local function signatureActionResponse(bp, data)
	local sig, activeParam = resolveActiveSignature(data.result)
	if not sig then
		return
	end
	local msg = formatSignature(sig, activeParam)
	if msg ~= "" then
		displaySignature(msg, sig)
	end
end

function signatureAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end

	flushDocumentChange(bp, filetype)

	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line, char = requestPosition(bp)

	send(
		"textDocument/signatureHelp",
		fmt.Sprintf(
			'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}',
			file,
			line,
			char
		),
		nil,
		signatureActionResponse
	)
end
