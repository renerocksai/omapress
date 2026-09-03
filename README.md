# omapress

Omarchy news in the Omarchy bar. A newspaper icon that turns red when
[omarchy.org/news](https://omarchy.org/news) has posts you haven't read, and a
keyboard-driven panel that lets you read them without opening a browser.

- **Bar widget**: the icon is colored while there are unread posts, plain when
  you're caught up. Left click opens the panel, right click refreshes, middle
  click marks everything read.
- **Panel**: the post list with date, author and a two-line summary, plus an
  inline reader for the full post (paragraphs, headings, lists, quotes, code)
  and the links it contains.
- **Notifications** when a refresh finds new posts, with a click-through to the
  post.
- **Offline**: the last fetched feed is cached, so the panel still works on a
  train. Conditional requests (ETag) keep refreshes cheap.
- **Any feed**: the URL is a setting. RSS 2.0 and Atom both parse.

## Requirements

Nothing beyond a stock Omarchy install: `python3` (standard library only) for
the helper, and the JetBrainsMono Nerd Font the shell already uses.

## Install

```bash
omarchy plugin add https://github.com/renerocksai/omapress --enable
```

This clones the repo into
`~/.config/omarchy/plugins/io.github.renerocksai.omapress/` and asks where to
put the widget. Without `--enable` it lands disabled so you can read the code
first, since plugins run unsandboxed inside `omarchy-shell`.

Later: `omarchy plugin update io.github.renerocksai.omapress` to update,
`omarchy plugin remove io.github.renerocksai.omapress` to remove.

## Using it

| Bar icon | |
|---|---|
| left click | open / close the panel |
| right click | refresh now |
| middle click | mark all read |

| Panel, post list | |
|---|---|
| `j` / `k`, arrows | move the cursor |
| `Enter`, `l`, click | read the post inline |
| middle click, globe button | open the post in the browser |
| `o` | open the post under the cursor in the browser |
| `x` | toggle read / unread |
| `a` | mark all read |
| `r` | refresh |
| `Esc` | close |

| Panel, reader | |
|---|---|
| `j` / `k`, arrows, `g` / `G` | scroll |
| `h`, `Backspace`, `Esc` | back to the list |
| `Enter`, `o` | open in the browser |
| `x` | toggle read / unread |

Opening a post in the reader marks it read. On the very first run, posts older
than two weeks start out read so a fresh install shows what's new rather than
lighting up for the whole archive.

### Keybinding

Summon the panel from anywhere by binding the shell's toggle in
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER SHIFT, N", "omarchy-shell shell toggle io.github.renerocksai.omapress '{}'")
```

### IPC

```bash
omarchy-shell io.github.renerocksai.omapress toggle        # or open / close
omarchy-shell io.github.renerocksai.omapress refresh
omarchy-shell io.github.renerocksai.omapress markAllRead
omarchy-shell io.github.renerocksai.omapress unread         # prints the count
```

## Settings

Edit the widget's entry in `~/.config/omarchy/shell.json` or use the bar
settings UI.

| key | default | |
|---|---|---|
| `feedUrl` | `https://omarchy.org/news/rss.xml` | any RSS 2.0 or Atom feed |
| `refreshIntervalSec` | `1800` | 300 to 86400 |
| `maxItems` | `30` | posts kept, 5 to 100 |
| `notifyNewPosts` | `true` | desktop notification for posts seen for the first time |
| `highlightUnread` | `true` | color the bar icon while there are unread posts |
| `unreadColor` | `#e5484d` | any CSS color, or `theme` for the bar's active color |

## Files it writes

| | |
|---|---|
| `~/.local/state/omapress/state.json` | which post ids are read / known |
| `~/.cache/omapress/feed.json` | the last successfully fetched feed |

Delete both to start over.

## How it works

`bin/omapress` is a small Python script. `fetch` downloads the feed, flattens
each post's HTML into plain-text blocks, merges in the read state, and prints
one JSON document. `mark-read`, `mark-unread` and `mark-all-read` update the
state file and print the same document from the cache. `Service.qml` runs the
helper and holds the result; `Panel.qml` is the bar button and the popup;
`Model.js` is the pure formatting logic.

## Development

```bash
tests/helper-test.sh          # helper against the fixture feeds
node --test tests/model.test.mjs
omarchy plugin validate .
```

To hack on it in place, symlink the checkout into the plugins directory:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.renerocksai.omapress
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.renerocksai.omapress center
```

The shell's file watcher does not follow symlinks, so after editing run
`omarchy restart shell` to pick up changes.

## License

MIT
