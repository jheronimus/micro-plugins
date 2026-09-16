# Micro Plugins

Forked several plugins for the [Micro](https://github.com/zyedidia/micro) text editor to add bug fixes and small feature additions

## Included Plugins

- **[`lsp`](./lsp/)**: LSP client for Micro.
  - Fixes startup crashes when terminal or non-buffer panes are active.
  - Disables `formatOnSave` by default for Go to prevent race conditions with `gofmt`.
- **[`filemanager`](./filemanager/)**: VS Code-like file tree sidebar.
  - Fixes mouse-click crashes on Micro 2.x (removes deprecated `GetMouseClickLocation`).
  - Adds boundary checks to prevent crashes when clicking empty space below file lists.
- **[`go`](./go/)**: Go language support (`gofmt`, `goimports`, and `gorename`).

## Installation

Add this channel to your Micro configuration in `~/.config/micro/settings.json`:

```json
{
  "pluginchannels": [
    "https://raw.githubusercontent.com/micro-editor/plugin-channel/master/channel.json",
    "https://raw.githubusercontent.com/jheronimus/micro-plugins/main/channel.json"
  ]
}
```

Then install any plugin via Micro's CLI:

```sh
micro -plugin install lsp
micro -plugin install filemanager
micro -plugin install go
```

## Local Development & Validation

This repository uses [mise](https://mise.jdx.dev/), [StyLua](https://github.com/JohnnyMorganz/StyLua), [Selene](https://github.com/Kampfkarren/selene), and [Luacheck](https://github.com/lunarmodules/luacheck).

To validate code formatting, linting, and cyclomatic complexity ($\le 10$):

```sh
task validate
```
