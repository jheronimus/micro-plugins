local micro = import("micro")
local fmt = import("fmt")

-- Hover popup geometry: render.lua pre-wraps content to HOVER_TEXT_WIDTH,
-- which equals float's inner width (+4 converts it to the outer
-- width, matching float's border+padding).
local HOVER_TEXT_WIDTH = 72
local HOVER_MAX_HEIGHT = 28

-- the hover action request and response
function hoverAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] ~= nil then
		local send = withSend(filetype)
		local file = bp.Buf.AbsPath
		local line = bp.Buf:GetActiveCursor().Y
		local char = bp.Buf:GetActiveCursor().X
		currentAction[filetype] = { method = "textDocument/hover", response = hoverActionResponse }
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
end

function hoverActionResponse(bp, data)
	local result = data.result
	if result == nil or result.contents == nil or result.contents == "" then
		return
	end
	local contents = normalizeContents(result.contents)
	if contents == nil or contents.text == "" then
		return
	end
	-- plaintext is shown as-is; markdown needs the popup renderer, and
	-- without float there is nothing to render lines into
	if contents.kind == "plaintext" or float == nil then
		micro.InfoBar():Message(contents.text)
		return
	end
	float.show({
		anchor = "top-right",
		title = "Documentation",
		lines = renderMarkdown(contents.text, HOVER_TEXT_WIDTH),
		border = true,
		autoclose = true,
		width = HOVER_TEXT_WIDTH + 4,
		maxHeight = HOVER_MAX_HEIGHT,
	})
end
