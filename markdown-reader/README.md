# markdown-reader for Micro

A reader-focused Markdown plugin for the [micro](https://micro-editor.github.io/) text editor.

## Features

- **Reader Mode on Open:** Opens Markdown files (`.md`, `.markdown`, `.mkd`, `.livemd`) in clean, read-only mode by default.
- **Prompt to Edit:** Pressing any edit key (typing letters, Enter, Backspace, Delete, Cut) asks `Exit reader mode? (y/n)`. Confirming unlocks edit mode.
- **Subdued/Faded Syntax Delimiters:** Keeps Markdown syntax characters (`#`, `**`, `_`, `[]()`) visually subdued while highlighting the text and headers.
- **Free Navigation:** Full cursor navigation, scrolling, and search without leaving reader mode.
- **Manual Toggle:** Switch modes on the fly via `> readermode` or a custom shortcut like `Alt-r`.

## Installation

### Local / Development

Symlink the plugin directory into your Micro plugins folder:

```bash
ln -s "$(pwd)" ~/.config/micro/plug/markdown-reader
```

Or copy the `markdown-reader` directory into `~/.config/micro/plug/`.

## Keybindings

Add to `~/.config/micro/bindings.json`:

```json
{
  "Alt-r": "command:readermode"
}
```

## Settings

- `markdown-reader.autoreader` (`true` / `false`): Open Markdown files in reader mode automatically (default: `true`).
