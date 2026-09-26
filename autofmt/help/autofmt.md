# autofmt

Automatic code formatting on save and via manual command for Micro.

## Features

- **Multi-language support**: Go, C, C++, Rust, TypeScript, JavaScript, Python, Lua, Bash/Shell, Markdown, HTML, CSS, JSON, Nix, Dart, C#, Solidity, Racket.
- **Host autodetection**: Automatically tests `$PATH` using `which` to pick the first installed formatter from a prioritized candidate list.
- **Configurable**: Tool candidate lists are decoupled into `tools.lua` for easy user customization.
- **Zero VS Code dependencies**: Uses standalone binaries (`superhtml`, `biome`, `prettier`, etc.).

## Usage

- Automatic on save (enabled by default).
- Run `> fmt` to format the current buffer using the autodetected formatter.
- Run `> fmt <custom command>` to run an ad-hoc formatter on the current buffer.

## Options

- `autofmt.onsave` (boolean, default: `true`): Enable or disable formatting on save.
- `autofmt.for-<lang>` (string): Force a specific formatter for a filetype or `"off"` to disable.
  Example: `set autofmt.for-python "black -q"` or `set autofmt.for-go "off"`.

## Customizing Tools

Edit `plugins/autofmt/tools.lua` (or `~/.config/micro/plugins/autofmt/tools.lua`) to add or reorder formatters.
