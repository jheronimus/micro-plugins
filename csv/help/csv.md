# csv

Renders CSV/TSV files as aligned tables. The row under the cursor always
renders raw, so cells are edited in place; erasing a cell's contents makes
it empty without shifting other cells.

- `Enter` at end of row adds a new row (native newline).
- `Ctrl+K` deletes the current row (bound to `DeleteLine` unless you
  already bound it yourself).
- `Tab` is not intercepted — it does what micro does natively. Note that
  in a TSV, an inserted tab is a new column.
- `Ctrl-e` → `csv.addcol` inserts an empty column after the cursor's
  column; `csv.delcol` removes the cursor's column.

Commands work everywhere but only `.csv`/`.tsv` files render. Multi-line
(quoted newline) records are not supported: every line is one record.
