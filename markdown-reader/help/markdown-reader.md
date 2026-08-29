# markdown-reader

`markdown-reader` provides a reader mode for Markdown files in Micro.

## Features

- **Automatic Reader Mode:** Markdown files open in read-only mode by default without line numbers/rulers for a clean, distraction-free reading experience.
- **Prompt on Edit:** Attempting to type or edit (`Enter`, `Backspace`, `Delete`, `Cut`, etc.) prompts `Exit reader mode? (y/n)` in the infobar. Confirming unlocks the buffer into edit mode and restores the ruler.
- **Faded Syntax Markers:** Markdown delimiters (`#`, `**`, `*`, `_`, `[]()`, ```` `) are styled with subtle/faded colors, keeping emphasis on your content.
- **Seamless Navigation:** Arrow keys, page scrolling, and search (`Ctrl-F`) navigate freely without triggering edit prompts.
- **Status Indicator:** Shows `[READER]` in reader mode and `[EDIT]` in edit mode.

## Commands

- `> readermode` (or `> reader`): Toggle between Reader Mode and Edit Mode for the current buffer.

## Keybindings

You can bind a key combination (e.g. `Alt-r`) to toggle reader mode in your `~/.config/micro/bindings.json`:

```json
{
  "Alt-r": "command:readermode"
}
```

## Configuration

Set options via `~/.config/micro/settings.json` or `> set <option> <value>`:

- `markdown-reader.autoreader` (default: `true`): Automatically enter reader mode when opening Markdown files.

## Statusline Integration

You can display the reader status in your custom statusline format:

```json
{
  "statusformatl": "$(filename) $(markdown-reader.statusInfo) $(modified)"
}
```
