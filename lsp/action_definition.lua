local micro = import("micro")
local buffer = import("micro/buffer")
local util = import("micro/util")
local fmt = import("fmt")
local go_os = import("os")

-- the definition action request and response
function definitionAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end

	flushDocumentChange(bp, filetype)
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line, char = requestPosition(bp)
	send(
		"textDocument/definition",
		fmt.Sprintf(
			'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}',
			file,
			line,
			char
		),
		nil,
		definitionActionResponse
	)
end

function definitionActionResponse(bp, data)
	local results = data.result
	if results == nil then
		return
	end
	local file = bp.Buf.AbsPath
	if results.uri ~= nil then
		-- single result
		results = { results }
	end
	if #results <= 0 then
		return
	end
	local uri = (results[1].uri or results[1].targetUri)
	local doc = normalizeUri(uri)
	local buf = bp.Buf
	if file ~= doc then
		-- it's from a different file, so open it as a new tab
		buf, _ = buffer.NewBufferFromFile(doc)
		bp:AddTab()
		micro.CurPane():OpenBuffer(buf)
		-- shorten the displayed name in status bar
		local name = buf:GetName()
		local wd, _ = go_os.Getwd()
		if name:starts(wd) then
			buf:SetName("." .. name:sub(#wd + 1, #name + 1))
		else
			if #name > 30 then
				buf:SetName("..." .. name:sub(-30, #name + 1))
			end
		end
	end
	local range = results[1].range or results[1].targetSelectionRange
	local lineText = util.String(buf:LineBytes(range.start.line))
	buf:GetActiveCursor():GotoLoc(buffer.Loc(runeColumn(lineText, range.start.character), range.start.line))
	bp:Center()
end
