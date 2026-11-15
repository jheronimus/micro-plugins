-- Unit tests for the LSP plugin's pure renderer (lsp/render.lua).
-- Usage: lua tests/run.lua  (from the plugins directory)

dofile("lsp/render.lua")

-- compare a rendered entry (or segment) against an expectation: a string
-- expectation asserts only the text; a table asserts every field it
-- names, including nested segments
local eqEntry

local function eqSegments(gotSegments, wantSegments)
	if type(gotSegments) ~= "table" or #gotSegments ~= #wantSegments then
		return false
	end
	for i, seg in ipairs(wantSegments) do
		if not eqEntry(gotSegments[i], seg) then
			return false
		end
	end
	return true
end

eqEntry = function(got, want)
	if type(want) == "string" then
		return type(got) == "table" and got.text == want
	end
	if type(got) ~= "table" then
		return false
	end
	for k, v in pairs(want) do
		if k == "segments" then
			if not eqSegments(got.segments, v) then
				return false
			end
		elseif got[k] ~= v then
			return false
		end
	end
	return true
end

local function eqLines(got, want)
	if type(got) ~= "table" or #got ~= #want then
		return false
	end
	for i, w in ipairs(want) do
		if not eqEntry(got[i], w) then
			return false
		end
	end
	return true
end

local function eqContents(got, want)
	return type(got) == "table" and got.kind == want.kind and got.text == want.text
end

-- executes one case; contents cases go through normalizeContents first
local function runCase(case)
	local ok, got
	if case.expectContents ~= nil then
		ok, got = pcall(normalizeContents, case.contents)
		return ok and eqContents(got, case.expectContents), ok, got
	end
	if case.contents ~= nil then
		local normalized
		ok, normalized = pcall(normalizeContents, case.contents)
		if ok and normalized ~= nil then
			ok, got = pcall(renderMarkdown, normalized.text, case.width)
			return ok and eqLines(got, case.expect), ok, got
		end
		return false, ok, normalized
	end
	ok, got = pcall(renderMarkdown, case.md, case.width)
	return ok and eqLines(got, case.expect), ok, got
end

local function printFailure(case, ok, got)
	print("FAIL: " .. case.name)
	if not ok then
		print("  error: " .. tostring(got))
	elseif case.expectContents ~= nil then
		print("  got kind=" .. tostring(got and got.kind) .. " text=" .. tostring(got and got.text))
	else
		print("  got:")
		for _, entry in ipairs(got or {}) do
			print("    " .. tostring(type(entry) == "table" and entry.text or entry))
		end
	end
end

local cases = {}
for _, file in ipairs({ "tests/spec_cases.lua", "tests/fixtures.lua" }) do
	for _, case in ipairs(dofile(file)) do
		cases[#cases + 1] = case
	end
end

local failures = 0
for _, case in ipairs(cases) do
	local pass, ok, got = runCase(case)
	if not pass then
		failures = failures + 1
		printFailure(case, ok, got)
	end
end

print(("%d/%d passed"):format(#cases - failures, #cases))
if failures > 0 then
	os.exit(1)
end
