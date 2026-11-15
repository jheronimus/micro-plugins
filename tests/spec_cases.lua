-- Spec-derived cases for the CommonMark subset the renderer claims to
-- support, plus regressions for every server-emission bug fixed so far.
-- Each case: { name, md, width, expect = lines }. String expectations
-- assert only the line text; table expectations assert named fields.

local RULE40 = string.rep("─", 40)

return {
	-- paragraphs
	{
		name = "paragraph single line",
		md = "Package fmt implements formatted I/O.",
		width = 60,
		expect = { "Package fmt implements formatted I/O." },
	},
	{
		name = "paragraph wraps",
		md = "Package fmt implements formatted I/O.",
		width = 20,
		expect = { "Package fmt", "implements formatted", "I/O." },
	},
	{ name = "paragraph joins soft breaks", md = "line one\nline two", width = 60, expect = { "line one line two" } },
	{
		name = "blank line between paragraphs",
		md = "one two\n\nthree four",
		width = 60,
		expect = { "one two", "", "three four" },
	},
	{ name = "empty input", md = "", width = 40, expect = {} },
	{ name = "trailing blanks trimmed", md = "text\n\n\n", width = 40, expect = { "text" } },

	-- headings
	{
		name = "atx heading",
		md = "## Title",
		width = 40,
		expect = { { text = "Title", bold = true, color = "constant" } },
	},
	{
		name = "atx closing sequence stripped",
		md = "# Title #",
		width = 40,
		expect = { { text = "Title", bold = true, color = "constant" } },
	},
	{
		name = "setext h1",
		md = "Title\n=====",
		width = 40,
		expect = { { text = "Title", bold = true, color = "constant" } },
	},
	{
		name = "setext h2",
		md = "Title\n---",
		width = 40,
		expect = { { text = "Title", bold = true, color = "constant" } },
	},

	-- thematic breaks
	{ name = "dashes rule", md = "---", width = 40, expect = { { text = RULE40, color = "comment" } } },
	{ name = "spaced asterisk rule", md = "* * *", width = 40, expect = { { text = RULE40, color = "comment" } } },

	-- code blocks
	{
		name = "fenced code",
		md = "```go\nfunc main() {}\n```",
		width = 40,
		expect = { { text = "  func main() {}", color = "comment" } },
	},
	{
		name = "unterminated fence",
		md = "```go\nfunc main() {}",
		width = 40,
		expect = { { text = "  func main() {}", color = "comment" } },
	},
	{
		name = "tilde fence",
		md = "~~~\na b\n~~~",
		width = 40,
		expect = { { text = "  a b", color = "comment" } },
	},
	{
		name = "indented code",
		md = "Intro:\n\n    code line\n    more",
		width = 40,
		expect = { "Intro:", "", { text = "  code line", color = "comment" }, { text = "  more", color = "comment" } },
	},
	{
		name = "indented line continues paragraph",
		md = "text\n    more",
		width = 40,
		expect = { "text more" },
	},

	-- lists
	{ name = "bullet list", md = "- one\n- two", width = 40, expect = { "• one", "• two" } },
	{ name = "ordered list", md = "1. one\n2. two", width = 40, expect = { "1. one", "2. two" } },
	{ name = "nested list", md = "- a\n  - b", width = 40, expect = { "• a", "  • b" } },
	{
		name = "ordered counters continue across blank line",
		md = "1. a\n2. b\n\n1. c",
		width = 40,
		expect = { "1. a", "2. b", "3. c" },
	},
	{ name = "task list markers", md = "- [x] done\n- [ ] todo", width = 40, expect = { "☑ done", "☐ todo" } },
	{
		name = "list item hanging indent wrap",
		md = "- one two three four",
		width = 12,
		expect = { "• one two", "  three four" },
	},

	-- block quotes
	{
		name = "block quote",
		md = "> quoted text",
		width = 40,
		expect = { { text = "│ quoted text", color = "comment", italic = true } },
	},
	{
		name = "block quote joins lines",
		md = "> line one\n> line two",
		width = 40,
		expect = { { text = "│ line one line two", color = "comment", italic = true } },
	},

	-- inline: regressions for the bugs found against real servers
	{
		name = "godoc escaped list marker",
		md = "1\\. If the operand is a reflect.Value",
		width = 60,
		expect = { "1. If the operand is a reflect.Value" },
	},
	{
		name = "pylsp nbsp indentation decodes to indented code",
		md = "&nbsp;&nbsp;&nbsp;&nbsp;bytes",
		width = 40,
		expect = { { text = "  bytes", color = "comment" } },
	},
	{ name = "entity named", md = "a &amp; b", width = 40, expect = { "a & b" } },
	{ name = "entity decimal and hex", md = "&#65;&#x42;C", width = 40, expect = { "ABC" } },
	{ name = "escaped asterisk stays literal", md = "\\*not bold\\*", width = 40, expect = { "*not bold*" } },

	-- inline styling (exact segments)
	{
		name = "code span styled",
		md = "use `fmt.Println` now",
		width = 60,
		expect = {
			{
				text = "use fmt.Println now",
				segments = {
					{ text = "use" },
					{ text = " " },
					{ text = "fmt.Println", code = true },
					{ text = " " },
					{ text = "now" },
				},
			},
		},
	},
	{
		name = "code span shields markup",
		md = "`*not em*`",
		width = 40,
		expect = { { text = "*not em*", segments = { { text = "*not em*", code = true } } } },
	},
	{
		name = "strong",
		md = "**bold**",
		width = 40,
		expect = { { text = "bold", segments = { { text = "bold", bold = true } } } },
	},
	{
		name = "strikethrough",
		md = "~~gone~~",
		width = 40,
		expect = { { text = "gone", segments = { { text = "gone", strike = true } } } },
	},

	-- inline: things that must NOT trigger
	{ name = "snake_case stays raw", md = "some_var_name", width = 40, expect = { "some_var_name" } },
	{ name = "multiplication stars stay raw", md = "2 * 3 * 4", width = 40, expect = { "2 * 3 * 4" } },

	-- links and images render their text
	{ name = "link flattens to text", md = "[text](http://example.com)", width = 40, expect = { "text" } },
	{ name = "image renders alt text", md = "![alt](http://example.com/x.png)", width = 40, expect = { "alt" } },
	{ name = "autolink", md = "<https://example.com>", width = 40, expect = { "https://example.com" } },

	-- GFM tables
	{
		name = "table aligned",
		md = "| a | bb |\n| --- | --- |\n| 1 | 2 |",
		width = 40,
		expect = {
			{ text = "│ a │ bb │", bold = true },
			{ text = "──────────", color = "comment" },
			{ text = "│ 1 │ 2  │" },
		},
	},
}
