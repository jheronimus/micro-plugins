-- Default LSP server candidates in priority order per language.
-- Users can customize or extend this table directly or in ~/.config/micro/plugins/lsp/servers.lua
defaultServers = {
	go = { "gopls" },
	c = { "clangd" },
	["c++"] = { "clangd" },
	rust = { "rust-analyzer" },
	typescript = { "biome lsp-proxy", 'deno lsp={"enable":true}', "typescript-language-server --stdio" },
	javascript = { "biome lsp-proxy", 'deno lsp={"enable":true}', "typescript-language-server --stdio" },
	python = { "basedpyright-langserver --stdio", "pyright-langserver --stdio", "pylsp", "ruff server" },
	lua = { "lua-language-server" },
	shell = { "bash-language-server start" },
	markdown = { "marksman server", 'deno lsp={"enable":true}' },
	html = { "superhtml lsp", "biome lsp-proxy" },
	css = { "biome lsp-proxy", "tailwindcss-language-server" },
	json = { "biome lsp-proxy", 'deno lsp={"enable":true}' },
	jsonc = { "biome lsp-proxy", 'deno lsp={"enable":true}' },
	nix = { "nil", "nixd" },
	dart = { "dart language-server" },
	csharp = { "csharp-ls", "OmniSharp" },
	solidity = { "nomicfoundation-solidity-language-server" },
	racket = { "racket" },
}
