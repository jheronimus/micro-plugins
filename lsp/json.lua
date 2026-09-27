--
-- JSON
--
-- Internal functions.
json = {}

-- Returns pos, did_find; there are two cases:
-- 1. Delimiter found: pos = pos after leading space + delim; did_find = true.
-- 2. Delimiter not found: pos = pos after leading space;     did_find = false.
-- This throws an error if err_if_missing is true and the delim is not found.
local function skip_delim(str, pos, delim, err_if_missing)
	pos = pos + #str:match("^%s*", pos)
	if str:sub(pos, pos) ~= delim then
		if err_if_missing then
			error("Expected " .. delim .. " near position " .. pos)
		end
		return pos, false
	end
	return pos + 1, true
end

-- Expects the given pos to be the first character after the opening quote.
-- Returns val, pos; the returned pos is after the closing quote character.
local function parse_str_val(str, pos)
	local chars = {}
	local len = #str
	local esc_map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
	while pos <= len do
		local c = str:sub(pos, pos)
		if c == '"' then
			return table.concat(chars), pos + 1
		elseif c == "\\" then
			local nextc = str:sub(pos + 1, pos + 1)
			if not nextc or nextc == "" then
				error("End of input found while parsing string.")
			end
			table.insert(chars, esc_map[nextc] or nextc)
			pos = pos + 2
		else
			table.insert(chars, c)
			pos = pos + 1
		end
	end
	error("End of input found while parsing string.")
end

-- Returns val, pos; the returned pos is after the number's final character.
local function parse_num_val(str, pos)
	local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
	local val = tonumber(num_str)
	if not val then
		error("Error parsing number at position " .. pos .. ".")
	end
	return val, pos + #num_str
end

json.null = {} -- This is a one-off table to represent the null value.

local function parse_object(str, pos)
	local obj, key, delim_found = {}, true, true
	pos = pos + 1
	while true do
		key, pos = json.parse(str, pos, "}")
		if key == nil then
			return obj, pos
		end
		if not delim_found then
			error("Comma missing between object items.")
		end
		pos = skip_delim(str, pos, ":", true) -- true -> error if missing.
		obj[key], pos = json.parse(str, pos)
		pos, delim_found = skip_delim(str, pos, ",")
	end
end

local function parse_array(str, pos)
	local arr, val, delim_found = {}, true, true
	pos = pos + 1
	while true do
		val, pos = json.parse(str, pos, "]")
		if val == nil then
			return arr, pos
		end
		if not delim_found then
			error("Comma missing between array items.")
		end
		arr[#arr + 1] = val
		pos, delim_found = skip_delim(str, pos, ",")
	end
end

local function parse_literal(str, pos)
	local literals = { ["true"] = true, ["false"] = false, ["null"] = json.null }
	for lit_str, lit_val in pairs(literals) do
		local lit_end = pos + #lit_str - 1
		if str:sub(pos, lit_end) == lit_str then
			return lit_val, lit_end + 1
		end
	end
	local pos_info_str = "position " .. pos .. ": " .. str:sub(pos, pos + 10)
	error("Invalid json syntax starting at " .. pos_info_str .. ": " .. str)
end

function json.parse(str, pos, end_delim)
	pos = pos or 1
	if pos > #str then
		error("Reached unexpected end of input." .. str)
	end
	pos = pos + #str:match("^%s*", pos) -- Skip whitespace.
	local first = str:sub(pos, pos)
	if first == "{" then -- Parse an object.
		return parse_object(str, pos)
	elseif first == "[" then -- Parse an array.
		return parse_array(str, pos)
	elseif first == '"' then -- Parse a string.
		return parse_str_val(str, pos + 1)
	elseif first == "-" or first:match("%d") then -- Parse a number.
		return parse_num_val(str, pos)
	elseif first == end_delim then -- End of an object or array.
		return nil, pos + 1
	else -- Parse true, false, or null.
		return parse_literal(str, pos)
	end
end
