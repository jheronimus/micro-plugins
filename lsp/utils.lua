local fmt = import("fmt")

function getUriFromBuf(buf)
	if buf == nil then
		return
	end
	local file = buf.AbsPath
	local uri = fmt.Sprintf("file://%s", file)
	return uri
end

function normalizeUri(rawUri)
	return rawUri:gsub("^file://", ""):gsub("%%[a-f0-9][a-f0-9]", function(x)
		return string.char(tonumber(x:gsub("%%", ""), 16))
	end)
end

function mysplit(inputstr, sep)
	if sep == nil then
		sep = "%s"
	end
	local t = {}
	for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
		table.insert(t, str)
	end
	return t
end

function contains(list, x)
	for _, v in pairs(list) do
		if v == x then
			return true
		end
	end
	return false
end

function string.starts(String, Start)
	return string.sub(String, 1, #Start) == Start
end

function string.ends(String, End)
	return string.sub(String, #String - (#End - 1), #String) == End
end

-- Minimal JSON encoder for values produced by json.parse (tables,
-- strings, numbers, booleans). Used to send server objects (e.g. LSP
-- completion items for completionItem/resolve) back to the server.
local function encodeJsonTable(value)
	local arrayLen, total = 0, 0
	for _ in ipairs(value) do
		arrayLen = arrayLen + 1
	end
	for _ in pairs(value) do
		total = total + 1
	end
	local items = {}
	if arrayLen == total and arrayLen > 0 then
		for _, item in ipairs(value) do
			items[#items + 1] = encodeJson(item)
		end
		return "[" .. table.concat(items, ",") .. "]"
	end
	for k, item in pairs(value) do
		items[#items + 1] = encodeJson(tostring(k)) .. ":" .. encodeJson(item)
	end
	return "{" .. table.concat(items, ",") .. "}"
end

function encodeJson(value)
	local vtype = type(value)
	if vtype == "string" then
		return fmt.Sprintf(
			'"%s"',
			value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
		)
	elseif vtype == "number" then
		if value == math.floor(value) then
			return fmt.Sprintf("%.0f", value)
		end
		return tostring(value)
	elseif vtype == "boolean" then
		return tostring(value)
	elseif vtype == "table" then
		return encodeJsonTable(value)
	end
	return "null"
end

function string.parse(text)
	if not text:find('"jsonrpc":') then
		return {}
	end
	local _, fin = text:find("\r*\n\r*\n")
	local cleanedText = text
	if fin ~= nil then
		cleanedText = text:sub(fin + 1)
	end
	local status, res = pcall(json.parse, cleanedText)
	if status then
		return res
	end
	return false
end

table.filter = function(t, filterIter)
	local out = {}

	for k, v in pairs(t) do
		if filterIter(v, k, t) then
			table.insert(out, v)
		end
	end

	return out
end
