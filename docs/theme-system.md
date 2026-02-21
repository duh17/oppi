# Themes: create and import a theme file

This guide is for people who want to make a custom theme.

## 1) Start from a working theme file

Copy a bundled theme as your template:

```bash
cp server/themes/tokyo-night.json /tmp/my-theme.json
```

The file shape is:

```json
{
  "name": "My Theme",
  "colorScheme": "dark",
  "colors": {
    "...": "#RRGGBB"
  }
}
```

Rules:
- `name`: any string
- `colorScheme`: `"dark"` or `"light"`
- `colors`: all required keys must exist
- each color value must be `#RRGGBB` (or empty string `""` to fall back to default)

## 2) Edit colors

Update values in `colors`.

Keep all keys present. Do not remove keys.

## 3) Validate quickly

Check JSON syntax:

```bash
jq empty /tmp/my-theme.json
```

Check the number of color keys (should be 49):

```bash
jq '.colors | keys | length' /tmp/my-theme.json
```

## 4) Import theme (two options)

### Option A: API (recommended)

```bash
curl -X PUT http://localhost:7749/themes/my-theme \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/my-theme.json
```

### Option B: copy file into data dir

```bash
mkdir -p ~/.config/oppi/data/themes
cp /tmp/my-theme.json ~/.config/oppi/data/themes/my-theme.json
```

## 5) Use it in iOS app

In the iOS app:

- Settings → Import Theme
- pick your server
- select your theme

## Troubleshooting

- `PUT /themes/:name` fails: check key count and hex format.
- Theme not listed: confirm server is running and reachable.
- Wrong contrast/readability: start from a known-good bundled theme and adjust in small steps.

## Reference

- Bundled theme examples: `server/themes/*.json`
- Config and theme API context: `server/docs/config-schema.md`
