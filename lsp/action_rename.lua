local micro = import("micro")
local fmt = import("fmt")

local function renameActionResponse(newName)
	return function(bp, data)
		if data.result == nil then
			micro.InfoBar():Message("No rename changes returned by LSP")
			return
		end
		local fileEdits = collectChanges(data.result)
		applyAllChanges(bp, fileEdits, "Renamed to " .. newName)
	end
end

local function sendRename(bp, newName)
	local filetype = bp.Buf:FileType()
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X

	currentAction[filetype] = {
		method = "textDocument/rename",
		response = renameActionResponse(newName),
	}
	send(
		currentAction[filetype].method,
		fmt.Sprintf(
			'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}, "newName": %s}',
			file,
			line,
			char,
			encodeJson(newName)
		)
	)
end

function renameAction(bp, args)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		micro.InfoBar():Message("LSP not active for " .. filetype)
		return
	end

	if args and #args > 0 then
		sendRename(bp, args[1])
	else
		micro.InfoBar():Prompt("New name: ", "", "rename", nil, function(resp, canceled)
			if canceled or resp == "" then
				return
			end
			sendRename(bp, resp)
		end)
	end
end
