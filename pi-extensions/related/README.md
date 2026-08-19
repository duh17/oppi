# Related work extension

This portable Pi extension package registers `related_update` and `related_status` for an agent-authored related-work board.

The board is a replace-on-write markdown summary plus navigable session and web items. Files belong in the summary as `[[path|label]]`. Session and web items use real `href` URLs: `oppi://session/<id>` or `http(s)://`.

When the board is non-empty, a `related` widget appears above the composer. Oppi renders it through the generic widget and URL/wiki pipeline. Standalone Pi gets the same tools plus terminal/RPC fallback lines.

## Local install for Oppi development

Install it like any other local Pi extension. From the Oppi repo root:

```bash
ln -sfn "$PWD/pi-extensions/related" ~/.pi/agent/extensions/related
```

Pi auto-discovers extensions in `~/.pi/agent/extensions/`, so new Oppi sessions load `related` automatically. Use the workspace editor's extension toggles to enable or disable it per workspace; they write Pi resource settings for the workspace cwd.

The package is not enabled by installing Oppi.

## Example tool call

```json
{
  "summary": "See [[docs/extensions.md|extensions]] and the parent session.",
  "items": [
    {
      "id": "parent",
      "title": "Parent session",
      "href": "oppi://session/abc-123"
    },
    {
      "id": "spec",
      "title": "Native UI contract",
      "href": "https://example.com/spec"
    }
  ]
}
```

`related_status` returns the current board, or `{ status: "none" }` when empty. `/related clear` or `related_update` with `clear: true` removes the board and widget.

## Development checks

```bash
cd pi-extensions/related
npm install
npm run check
npm test
```
