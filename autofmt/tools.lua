-- Default formatter candidates in priority order per language.
-- Users can customize or extend this table directly or in ~/.config/micro/plugins/autofmt/tools.lua
defaultTools = {
	go = { "goimports -w", "gofmt -w" },
	c = { "clang-format -i" },
	["c++"] = { "clang-format -i" },
	rust = { "rustfmt", "rustfmt +nightly" },
	typescript = { "biome format --write", "prettier --write --log-level silent" },
	javascript = { "biome format --write", "prettier --write --log-level silent" },
	html = { "superhtml fmt", "prettier --write --log-level silent" },
	css = { "biome format --write", "prettier --write --log-level silent" },
	python = { { "ruff check --fix", "ruff format -s" }, "ruff format -s", "black -q", "yapf -i" },
	lua = { "stylua" },
	shell = { "shfmt -w" },
	markdown = { "prettier --write --log-level silent" },
	json = { "biome format --write", "prettier --write --log-level silent" },
	jsonc = { "biome format --write", "prettier --write --log-level silent" },
	nix = { "nixfmt", "alejandra -q", "nixpkgs-fmt" },
	dart = { "dart format" },
	csharp = { "csharpier", "clang-format -i" },
	solidity = { "forge fmt" },
	racket = { "raco fmt --width 80 --max-blank-lines 2 -i" },
}
