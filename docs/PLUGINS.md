# Plugins and themes

Tutto can be shaped the way an editor can: themes are colour files, the panel's cards go anywhere in two sizes, and plugins add features: actions, live cards and automations, each with its own settings. Everything here is set in Tutto's settings (Customize, Appearance, Plugins), never in the menu bar panel itself.

The rule throughout: **customization is data Tutto renders**. A theme never runs anything. A plugin runs commands and prints data, and Tutto draws what it prints with its own components and your theme. So a plugin's card always looks like the rest of the panel.

## Plugins

A plugin is a `.json` file in `~/Library/Application Support/Tutto/Plugins`, or a folder there with a `plugin.json` and the scripts it runs. In a folder plugin, the commands run in that folder, so `./show.sh` works. A name plus either a command or a card is enough. Everything else is optional.

```json
{
  "name": "Repo Changes",
  "symbol": "arrow.triangle.branch",
  "command": "open -a Terminal \"$TUTTO_SETTING_FOLDER\"",
  "input": "none",
  "output": "silent",
  "timeout": 30,
  "widget": {"command": "./changes.sh", "every": 20, "size": "small", "background": false},
  "triggers": [{"on": "daily", "at": "09:00"}, {"on": "battery.below", "percent": 15}],
  "settings": [{"key": "folder", "title": "Repository", "type": "folder", "default": "~/code"}]
}
```

| Field | What it is |
|---|---|
| `name` | Shown everywhere. Links find the plugin by it, in any case. |
| `symbol` | An SF Symbol name. |
| `command` | The action: what runs from its shortcut, its tile in the tools row, Run, a link or a trigger. It runs with `zsh -l -c` (your PATH, as in Terminal) in your home folder, or in a folder plugin's own folder. |
| `input` | `none`, or `clipboard` (the clipboard's text arrives on standard input). |
| `output` | `notice` (its first lines in a toast), `clipboard` (what it prints replaces the clipboard; printing nothing leaves the clipboard alone) or `silent`. |
| `timeout` | Seconds before it's stopped (1–600, default 30). Output is capped at 64 KB. |
| `widget` | A card on the panel; see below. |
| `triggers` | Events that run the action by themselves; see below. |
| `settings` | Fields it asks for; see below. |
| `enabled` | `false` switches it off. |

### Cards

The card's `command` prints what the card shows:

- **Plain text:** the first line is the value, the second a detail, and any further lines are a list (wide cards).
- **JSON**, for more:

```json
{"value": "3", "unit": "open", "title": "PRs", "detail": "2 need review",
 "symbol": "arrow.triangle.pull", "level": "notice", "progress": 0.4,
 "series": [3, 4, 2, 5], "url": "https://example.com",
 "items": [{"title": "Fix login", "detail": "api", "url": "https://example.com/1"}]}
```

| Key | Meaning |
|---|---|
| `level` | `normal`, `notice` (an accent dot) or `alert` (the value turns red). |
| `progress` | 0–1, or a percent. Drawn as a meter. |
| `series` | Numbers drawn as a line. |
| `url` | Opened when the card is clicked. Without one, a click runs the plugin's command, or refreshes the card if it has no command. |

When to run it:
- `every` sets the seconds between runs while the card is on screen (at least 2).
- The card refreshes as soon as it appears if its value is older than that.
- `"background": true` keeps it fresh with the panel closed, at most every 10 s. Use this only when an automation needs it.
- `size` is the card's starting size; you can change it on the Customize page.

A card that fails shows the reason (the first line of its errors, or its exit code) instead of a stale value.

### Triggers

`"on"` is one of these:

| Event | Parameter | `$TUTTO_EVENT_INFO` |
|---|---|---|
| `every` | `"minutes"` | — |
| `daily` | `"at": "HH:MM"` | — |
| `battery.below` | `"percent"` | the charge |
| `power.connected`, `power.disconnected` | | the charge |
| `wake`, `sleep`, `lock`, `unlock`, `launch` (Tutto starts) | | — |
| `app.launched`, `app.quit`, `app.activated` | `"app"`: a name or bundle id (any app if left out) | the app's bundle id |
| `clipboard.changed` | | — (with `"input": "clipboard"`, the text arrives on standard input) |
| `network.changed` | | `wifi`, `ethernet`, `cellular`, `other` or `none` |
| `display.changed` | | how many displays there are |
| `agents.started`, `agents.finished` | | for `finished`, the minutes they worked |
| `stayawake.started`, `stayawake.ended` | | the minutes set, or why it ended |
| `custom` | `"name"` | the `info` sent |

How each kind behaves:
- **Custom events** come from anything that can open a link: a script, a build, a coding agent's hook.

  ```bash
  open -g "tutto://do/event?name=build-done&info=tests%20passed"
  ```

- **Battery below N %** fires once on the way down. It fires again only after the charge climbs 3 points above N, or after the Mac is plugged in.
- **Schedules** run on the wall clock. A Mac that slept through a time runs it once on waking, not once for each missed time.
- **Agents finish** fires about 3 minutes after the last sign of work: writes to their session logs, or a build they started still using the processor.
- **Copies** made by Tutto itself, and copies marked private (password managers), never fire `clipboard.changed`.
- **Limit:** a plugin runs at most 12 times a minute from its triggers.

Tutto watches for an event only while a plugin that's on asks for it. With no plugins, nothing extra runs.

### Settings

```json
"settings": [
  {"key": "folder", "title": "Repository", "type": "folder", "default": "~/code", "help": "A Git repository"},
  {"key": "token", "title": "API token", "type": "secret"},
  {"key": "units", "title": "Units", "type": "choice", "options": ["metric", "imperial"], "default": "metric"}
]
```

- **Types:** `text`, `number`, `toggle`, `choice` (with `options`), `folder` (with a folder picker) and `secret`.
- **Where values live:** you set them in the plugin's editor on the Plugins page, so they stay out of the plugin's file and it can be shared safely. Secrets are kept in your login keychain.
- **What commands see:** every command gets each value as `TUTTO_SETTING_<KEY>`; `repo-folder` becomes `TUTTO_SETTING_REPO_FOLDER`.

### What a run is told

| Variable | |
|---|---|
| `TUTTO_REASON` | `run` (button, shortcut, tile), `link`, `widget`, `trigger` or `test` (Try It) |
| `TUTTO_EVENT`, `TUTTO_EVENT_INFO` | for a trigger, the event and its details |
| `TUTTO_PLUGIN`, `TUTTO_PLUGIN_ID` | its name and id |
| `TUTTO_PLUGIN_DIR` | a folder plugin's folder |
| `TUTTO_SETTING_<KEY>` | its settings |

### Running one from a script

```bash
open -g "tutto://do/plugin?name=Uppercase%20Clipboard"
```

The link reads the folder first, so a plugin you just wrote runs as it is now.

### Safety

- Commands run as you, like any script you run yourself.
- A plugin that turns up in the folder (one you didn't make in Tutto) starts **switched off**, with a "New" label, until you've looked at what it runs and switched it on. Plugins you make or edit in Tutto are on.
- A deleted plugin goes to the Trash, along with its settings, its secrets and its shortcut.

### Templates

New Plugin offers ready-made plugins that work on any Mac:

- **Actions:** Plain Text Clipboard, Uppercase Clipboard, Count Clipboard Lines and Open Downloads.
- **Cards:** Git Changes (repository setting), Ping (address setting) and Uptime.
- **Automations:** Battery Low Notice, When Agents Finish, Clean Copied Links (strips tracking from copied links), Stretch Reminder and Build Finished (a custom event).

## Themes

Settings › Appearance has six built-in themes: Tutto, Graphite, Paper, Slate, Midnight and Forest. You can adjust whichever one is in use:

| Choice | Options |
|---|---|
| Accent | Your Mac's, none (marks in the ink), a preset, or any colour |
| Greys | Neutral, warm, cool |
| Contrast | Standard, high |
| Panel background | Glass, tinted, solid |
| Cards | Filled, outlined |
| Corners | Small, medium, large |
| Spacing | Compact, standard, roomy |
| Numbers | Standard, rounded, mono (for the big figures) |
| Light or dark | Match your Mac, light, dark |

The whole app follows at once. If a colour would be hard to read (the accent below 3:1 against a card, or small text below 4.5:1), the page says so. For the accent, it offers a fix that moves it just far enough to read.

**Save as Theme…** writes the look in use to `~/Library/Application Support/Tutto/Themes` as a JSON file. Share it by sending the file, or drop someone else's into the folder.

A link switches themes from a script or a plugin. For example, a plugin with a `daily` trigger at 21:00 can run:

```bash
open -g "tutto://do/theme?name=Midnight"
```

```json
{
  "name": "Midnight",
  "accent": "#8C9BFF",
  "neutrals": "cool",
  "background": "solid",
  "corners": "large",
  "numbers": "rounded",
  "appearance": "dark",
  "colors": {"dark": {"background": "#0A0D14", "card": "#FFFFFF10"}}
}
```

- **Fields:** every one can be left out and keeps its default, so a theme made for another version of Tutto still loads.
- **`accent`:** `system`, `mono`, or a hex colour.
- **`colors`:** sets tokens outright for `light` or `dark`. The tokens are `ink`, `background`, `card`, `line`, `accent` and `alert`, each as `#RRGGBB` or `#RRGGBBAA`.

## The panel's cards

Settings › Customize lists every card in one order: battery, CPU, memory, GPU, disk, network, temperature, your plugins' cards, Stay awake, the auto clicker, the fan, sound and the tools row.

- **Layout:** small cards sit two to a row, and a small card on its own takes the whole row. The one-line controls (Stay awake, the auto clicker, the fan) share a card when they're next to each other.
- **Arranging:** drag cards in the list, or in the live preview beside it. Click a card in the preview to size or hide it.
- **Size:** a card is small or wide wherever it comes in both. A wide battery card shows its health and the busiest apps. A wide reading or plugin card shows a longer line, and a plugin's list.
- **Restore Defaults** puts everything back. Your plugins stay in or out of the panel as they were.
