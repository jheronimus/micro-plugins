local fmt = import("fmt")
local buffer = import("micro/buffer")

-- The references results buffer. referenceState is shared with
-- events.lua's preInsertNewline/preRune/preEscape hooks: one row per
-- result, with the target locations stored in a table instead of being
-- re-parsed from the row text on every Enter. Its name is defined once
-- here; nothing else may hard-code it.
REFERENCE_NAME = "References found"
referenceState = nil

-- close the results view: clear the state first so hooks don't re-trigger,
-- then close the buffer (its pane is removed wherever it lives); pcall
-- guards against the pane already being gone
function closeReferences()
	if referenceState == nil then
		return
	end
	local state = referenceState
	referenceState = nil
	if state.bp ~= nil then
		pcall(function()
			state.bp.Buf:Close()
		end)
	end
end

function referencesAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end

	flushDocumentChange(bp, filetype)
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line, char = requestPosition(bp)
	send(
		"textDocument/references",
		fmt.Sprintf(
			'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}, "context": {"includeDeclaration":true}}',
			file,
			line,
			char
		),
		nil,
		referencesActionResponse
	)
end

function referencesActionResponse(bp, data)
	local results = data.result
	if results == nil or #results == 0 then
		return
	end

	local msg = ""
	local locs = {}
	for row, ref in ipairs(results) do
		if msg ~= "" then
			msg = msg .. "\n"
		end
		local doc = (ref.uri or ref.targetUri)
		msg = msg
			.. "."
			.. doc:sub(#rootUri + 1, #doc)
			.. ":"
			.. ref.range.start.line
			.. ":"
			.. ref.range.start.character
		locs[row] = { path = doc, line = ref.range.start.line, char = ref.range.start.character }
	end

	local logBuf = buffer.NewBuffer(msg, REFERENCE_NAME)
	referenceState = { name = REFERENCE_NAME, locs = locs, bp = bp:HSplitBuf(logBuf) }
end
