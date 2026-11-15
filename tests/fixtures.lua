-- Golden fixtures from real server payloads: normalizeContents shape
-- handling and the rendering each server's hover should produce.
-- Each case: { name, contents, expect = lines } or
-- { name, contents, expectContents = {kind, text} }.

return {
	{
		name = "plain string is plaintext",
		contents = "just text",
		expectContents = { kind = "plaintext", text = "just text" },
	},
	{
		name = "MarkupContent kind passes through",
		contents = { kind = "markdown", value = "# x" },
		expectContents = { kind = "markdown", text = "# x" },
	},
	{
		name = "MarkedString becomes a fence",
		contents = { language = "go", value = "func F() {}" },
		expectContents = { kind = "markdown", text = "```go\nfunc F() {}\n```" },
	},
	{
		name = "MarkedString[] joins as markdown",
		contents = { "plain doc text", { language = "go", value = "func F() {}" } },
		expectContents = { kind = "markdown", text = "plain doc text\n\n```go\nfunc F() {}\n```" },
	},
	{
		name = "gopls hover",
		width = 72,
		contents = {
			kind = "markdown",
			value = "```go\nfunc Println(a ...any) (n int, err error)\n```\n\nPrintln formats using the default formats for its operands.",
		},
		expect = {
			{ text = "  func Println(a ...any) (n int, err error)", color = "comment" },
			"",
			"Println formats using the default formats for its operands.",
		},
	},
	{
		name = "pylsp hover with nbsp sections",
		width = 72,
		contents = {
			kind = "markdown",
			value = "(module) random\n\nRandom variable generators.\n\n&nbsp;&nbsp;&nbsp;&nbsp;bytes\n-----\n\nuniform bytes (values between 0 and 255)\n\n&nbsp;&nbsp;&nbsp;&nbsp;integers\n-----\n\nuniform within range",
		},
		expect = {
			"(module) random",
			"",
			"Random variable generators.",
			"",
			{ text = "bytes", bold = true, color = "constant" },
			"",
			"uniform bytes (values between 0 and 255)",
			"",
			{ text = "integers", bold = true, color = "constant" },
			"",
			"uniform within range",
		},
	},
}
