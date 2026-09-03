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
| `maxItems` | `30` | posts kept, 5 to 50 |
| `notifyNewPosts` | `true` | desktop notification for posts seen for the first time |
| `highlightUnread` | `true` | color the bar icon while there are unread posts |
| `unreadColor` | `#e5484d` | any CSS color, or `theme` for the bar's active color |

## Files it writes

| | |
|---|---|
| `~/.local/state/omapress/state.json` | which post ids are read / known |
| `~/.cache/omapress/feed.json` | the last successfully fetched feed |

Delete both to start over. Nothing else is touched: no user configuration,
no `sudo` or `pkexec`, no systemd units, no installer, no bundled binaries.

## Boundaries

What the plugin will and will not do, since it runs unsandboxed inside
`omarchy-shell` and reads a feed it does not control.

**Network.** Only the configured feed URL is ever requested, and only over
https. It and every redirect hop must name a real public host: no
credentials, no explicit port, no IP literal, no localhost, `.local`,
`.internal` or private address (checked on the name and on what it resolves
to). At most five hops. A declared `Content-Length` over 4 MiB is refused
before a byte is read; the body streams in 64 KiB chunks and one byte over
the cap is an error, not a truncation. Conditional requests keep a normal
refresh at a few hundred bytes.

**Time.** Every helper run carries one absolute budget (fetch 40 s, read
state 10 s) that each socket operation inherits as remaining time, with
`SIGALRM` as the backstop. The shell watches each run with a deadline five
seconds past that budget: `TERM` to the helper and its process group, `KILL`
two seconds later if it is still there, and the run is reported as a timeout.

**Size.** Everything that reaches the panel is bounded: 50 posts, titles 300
characters, summaries 400, authors 120, links and ids 2048, 200 blocks and
30 links per post, 30 000 characters of body per post. The helper derives its
8 MiB output budget from these caps and checks its own output against it; the
shell refuses anything larger whole and rebuilds every document into the same
closed shape, dropping unknown fields. Control characters are stripped at
ingestion. A DTD anywhere in the feed is refused, since entity expansion is
the one thing a DTD can do to an RSS parser. The cache and state files are
read under byte caps and re-coerced the same way, so a tampered file cannot
widen what the panel shows.

**Links.** A link is shown and opened only if it is http or https to a real
public host under the same rules as the feed; everything else, including
`javascript:`, `file:`, credentialed and local URLs, is dropped at parse time,
dropped again when the cache is re-read, and refused once more at the click.
Opening goes through `xdg-open`. A notification's click-through gets a link
only if it passes, and its title and body are single-line, capped, and cannot
start with a dash.

**Files.** The state and cache directories are created 0700, opened
`O_DIRECTORY|O_NOFOLLOW`, refused if they are symlinks or not owned by the
user, and held by descriptor for the run. Reads are descriptor-relative,
no-follow, non-blocking, and accept only a regular, singly-linked file owned by
the user under the cap. Writes go to a random-named `O_EXCL` 0600 temp file,
fsync, rename over the entry (which replaces a planted symlink rather than
following it), then fsync the directory.

**Rendering.** Every string from the feed is drawn with `Text.PlainText`.
Nothing from the feed is ever interpreted as markup, a path, or a command.

**Surface.** The IPC methods take no arguments. The helper is only ever run
with a fixed argv the shell builds; its `--source` flag, which reads a local
file instead of the network, exists for the tests and is never passed by the
plugin.

## How it works

`bin/omapress` is a small Python script. `fetch` downloads the feed, flattens
each post's HTML into plain-text blocks, merges in the read state, and prints
one JSON document. `mark-read`, `mark-unread` and `mark-all-read` update the
state file and print the same document from the cache. `Service.qml` runs the
helper and holds the result; `Panel.qml` is the bar button and the popup;
`Model.js` is the pure formatting logic.

## Development

```bash
tests/helper-test.sh             # helper end to end against fixture feeds, adversarial filesystem cases
python3 tests/helper_unit.py     # URL policy, redirects, caps, deadline, cache coercion
node --test tests/model.test.mjs # schema, URL and setting policy, formatting
tests/watchdog-test.sh           # ProcessWatchdog against a child that ignores TERM
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
