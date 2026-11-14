local micro = import("micro")
local buffer = import("micro/buffer")
local fmt = import("fmt")

function formatAction(bp, callback)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local cfg = bp.Buf.Settings

	currentAction[filetype] = { method = "textDocument/formatting", response = formatActionResponse(callback) }
	send(
		currentAction[filetype].method,
		fmt.Sprintf(
			'{"textDocument": {"uri": "file://%s"}, "options": {"tabSize": %.0f, "insertSpaces": %t, "trimTrailingWhitespace": %t, "insertFinalNewline": %t}}',
			file,
			cfg["tabsize"],
			cfg["tabstospaces"],
			cfg["rmtrailingws"],
			cfg["eofnewline"]
		)
	)
end

function formatActionResponse(callback)
	return function(bp, data)
		if data.result == nil then
			return
		end
		local edits = data.result
		-- sortEdits orders changes back-to-front so applying them in order
		-- never invalidates the positions of the remaining edits
		sortEdits(edits)

		-- save original cursor position
		local xy = buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
		for _idx, edit in ipairs(edits) do
			applySingleEdit(bp, edit)
		end
		-- put the cursor back where it was
		bp.Cursor:GotoLoc(xy)
		-- if any changes were applied
		if #edits > 0 then
			-- tell the server about the changed document
			onRune(bp)
		end

		if callback ~= nil then
			callback(bp)
		end
	end
end
