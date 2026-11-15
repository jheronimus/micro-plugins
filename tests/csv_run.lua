-- Unit tests for the CSV plugin's pure renderer (csv/render.lua).
-- Usage: lua tests/csv_run.lua  (from the plugins directory)

dofile("csv/render.lua")

local failures = 0

local function eq(got, want, label)
	if type(want) == "table" then
		for i, v in ipairs(want) do
			if got[i] ~= v then
				failures = failures + 1
				print(("FAIL %s: got %s, want %s"):format(label, tostring(got[i]), tostring(v)))
				return
			end
		end
		if #got ~= #want then
			failures = failures + 1
			print(("FAIL %s: length %d != %d"):format(label, #got, #want))
		end
		return
	end
	if got ~= want then
		failures = failures + 1
		print(("FAIL %s: got %s, want %s"):format(label, tostring(got), tostring(want)))
	end
end

-- parseLine
eq(parseLine("a,b,c", ","), { "a", "b", "c" }, "parse basic")
eq(parseLine("a,,c", ","), { "a", "", "c" }, "parse empty field")
eq(parseLine('"a,b",c', ","), { "a,b", "c" }, "parse quoted delimiter")
eq(parseLine('"say ""hi""",b', ","), { 'say "hi"', "b" }, "parse escaped quotes")
eq(parseLine('a,"b', ","), { "a", "b" }, "parse unterminated quote")
eq(parseLine("a\tb", "\t"), { "a", "b" }, "parse tsv")
eq(parseLine("", ","), { "" }, "parse empty line")
eq(parseLine("a,b,", ","), { "a", "b", "" }, "parse trailing delimiter")

-- computeWidths (capped)
eq(computeWidths({ { "name", "x" }, { "val", "longvalue" } }, 32), { 4, 9 }, "widths basic")
eq(computeWidths({ { "abcdefghij" } }, 4), { 4 }, "widths capped")

-- renderRow: padding + delimiter spans
local text, spans = renderRow({ "a", "bb" }, { 3, 2 }, ",", false, 32)
eq(text, "a  ,bb", "render padded")
eq(#spans, 1, "render one delimiter span")
eq({ spans[1].start, spans[1].length, spans[1].color }, { 3, 1, "comment" }, "render span position")

-- header: bold everywhere
text, spans = renderRow({ "a", "bb" }, { 3, 2 }, ",", true, 32)
eq(text, "a  ,bb", "header text")
eq(spans[#spans].bold, true, "header bold span")

-- truncation
text = renderRow({ "abcdefghij" }, { 4 }, ",", false, 4)
eq(text, "abc" .. "…", "render truncated")

-- displayToRawCol: "a  ,bb" — display col -> raw col of "a,bb"
local fields = { "a", "bb" }
local widths = { 3, 2 }
eq(displayToRawCol(fields, widths, ",", 0, 32), 0, "map col 0")
eq(displayToRawCol(fields, widths, ",", 1, 32), 1, "map col 1")
eq(displayToRawCol(fields, widths, ",", 2, 32), 1, "map padding to field end")
eq(displayToRawCol(fields, widths, ",", 3, 32), 1, "map delimiter to field end")
eq(displayToRawCol(fields, widths, ",", 4, 32), 2, "map second field")
eq(displayToRawCol(fields, widths, ",", 6, 32), 4, "map beyond end")

-- addColumn / delColumn
eq(addColumn("a,b", ",", 0), "a,,b", "addcol after first")
eq(addColumn("a,b", ",", 1), "a,b,", "addcol after last")
eq(addColumn("a,b", ",", 5), "a,b,", "addcol out of range appends")
eq(delColumn("a,b,c", ",", 1), "a,c", "delcol middle")
eq(delColumn("a,b,c", ",", 0), "b,c", "delcol first")
eq(delColumn("a,b,c", ",", 2), "a,b", "delcol last")
eq(delColumn('"x,y",b', ",", 0), "b", "delcol quoted field")
eq(addColumn('"x,y",b', ",", 0), '"x,y",,b', "addcol with quoted field")

local total = 24
print(("csv renderer: %d/%d passed"):format(total - failures, total))
if failures > 0 then
	os.exit(1)
end
