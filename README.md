# Micro Plugins

Curated plugins for the [Micro](https://github.com/micro-editor/micro) text editor with bug fixes, compatibility updates, and small feature additions.

## Included Plugins

- **[`lsp`](./lsp/)**: LSP client for Micro.
  - Fixes startup crashes when terminal or non-buffer panes are active.
  - Multi-language server autodetection via `servers.lua`.
  - Symbol rename via `textDocument/rename` bound to `F6`.
- **[`autofmt`](./autofmt/)**: Multi-language automatic code formatting on save and `> fmt`.
  - Host binary autodetection across prioritized candidates via `tools.lua`.
- **[`filemanager`](./filemanager/)**: VS Code-like file tree sidebar.
  - Fixes mouse-click crashes on Micro 2.x (removes deprecated `GetMouseClickLocation`).
  - Adds boundary checks to prevent crashes when clicking empty space below file lists.
  - Adds safe copy commands, optional Nerd Font icons, current-file reveal, new-tab opening, configurable width, and persistent tabs.
- **[`delve`](./delve/)**: Delve debugger integration for stepping through Go code, setting breakpoints, and inspecting variables.
  - Imported from [`serge-v/micro-delve`](https://github.com/serge-v/micro-delve).

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
micro -plugin install autofmt
micro -plugin install delve
```

## Local Development & Validation

This repository uses [mise](https://mise.jdx.dev/), [StyLua](https://github.com/JohnnyMorganz/StyLua), [Selene](https://github.com/Kampfkarren/selene), and [Luacheck](https://github.com/lunarmodules/luacheck).

To validate code formatting, linting, and cyclomatic complexity ($\le 10$):

```sh
task validate
```
