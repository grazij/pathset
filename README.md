# pathset

Turns a readable list of directories into the `:`-joined string that `PATH`,
`MANPATH`, `INFOPATH`, and zsh's `fpath` want — so the order lives in one
config file instead of scattered across rc files.

## Background

On macOS, `/etc/zprofile` runs `/usr/libexec/path_helper` before `~/.zshenv`
and `~/.zprofile`. It rebuilds `PATH` from `/etc/paths` and `/etc/paths.d/*`,
putting Apple's entries first and everything you installed after them.

Non-shell contexts are worse. The Shortcuts app's "Run Shell Script" action
loads only `~/.zshenv`, so it inherits whatever `path_helper` produced.

`pathset` prints the order you declared. Set it once in `~/.zshenv` and shells
and Shortcuts agree. Directories that don't exist, or are empty, are dropped.

The output is data, not a shell command — compose it with `$(...)` into any
variable you like.

## Install

Homebrew:

```sh
brew install grazij/tap/pathset
```

From source (needs a C11 compiler; no dependencies beyond libc):

```sh
make
sudo make install
```

`make install PREFIX="$HOME/.local"` installs elsewhere; `make uninstall`
takes the same `PREFIX`. `make universal` builds a macOS fat binary
(`arm64` + `x86_64`).

## Usage

```
pathset [-c CONFIG] [-k KIND] [-d] [-q] [-v] [--check] [--allow-empty]
pathset [-V|--version] [-h|--help]
```

| Flag | Meaning |
| --- | --- |
| `-c CONFIG` | Read this file instead of the default lookup. Missing file is fatal; `-k` is ignored. |
| `-k KIND` | One of `path` (default), `man`, `info`, `fpath`. Selects which config file is read. |
| `-d` | Drop duplicates; first occurrence wins. A trailing slash does not make an entry distinct, so `/opt/bin` and `/opt/bin/` collapse. |
| `-q` | Suppress the per-entry skip warnings. A one-line summary is still printed — see [Catching a rotted config](#catching-a-rotted-config). |
| `-v` | Print expansions, kept entries, and dropped duplicates on stderr. `-q` wins. |
| `--check` | Validate only: print nothing on stdout, exit with the codes below. For rc-file guards and scripts that want the status, not the output. |
| `--allow-empty` | Print an empty result instead of failing on one. |
| `-V`, `--version` | Print version. |
| `-h`, `--help` | Print help. |

Add to your shell rc:

```sh
# zsh / bash
export PATH="$(pathset -q -d)"
export MANPATH="$(pathset -k man -q -d)"
export INFOPATH="$(pathset -k info -q -d)"

# zsh — fpath is an array, so split the output back into elements
fpath=( ${(s.:.)$(pathset -k fpath -q -d)} $fpath )
```

```fish
set -gx PATH (pathset -q -d | string split :)
```

### Config file

One directory per line, in priority order. Full-line `#` comments (a `#`
mid-path is part of the path); blank lines ignored; CRLF tolerated.

```
# user binaries
~/bin
~/.local/bin

# optional: silently skipped when rbenv isn't installed
?$RBENV_ROOT/shims

# system
/usr/bin
/bin
```

Prefix an entry with `?` to make it **optional**: if it fails to expand or
isn't a usable directory, it is skipped without a warning and without
affecting the exit code. Use it for entries that exist on only some of the
machines sharing the config. Without `?`, a missing entry warns on every shell
startup and exits `3`.

Each entry is expanded before the directory check:

| Syntax | Expands to |
| --- | --- |
| `~/foo`, `~` | `$HOME/foo`, `$HOME` |
| `~user/foo` | that user's home, via `getpwnam(3)` |
| `$VAR/foo`, `${VAR}/foo` | environment variable `VAR` (unset **or empty** → skip) |

A tilde only expands at the start of an entry. `${VAR:-default}`, `\$`
escapes, and special variables like `$$` are not supported and stay literal.
An entry whose expansion fails is skipped with a warning rather than emitted
half-resolved.

### Config lookup

First match wins; `<kind>` is the `-k` value, default `path`.

1. `-c CONFIG`
2. `$XDG_CONFIG_HOME/pathset/<kind>` — only if `XDG_CONFIG_HOME` is set
3. `$HOME/.config/pathset/<kind>` — canonical
4. `$HOME/.pathset/<kind>` — legacy

Starter configs are in [`examples/`](examples/): copy `path.example` to
`~/.config/pathset/path`, `man.example` to `man`, `fpath.example` to `fpath`.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every entry was emitted. |
| `1` | Fatal — missing config, I/O error, empty result, out of memory. |
| `2` | Bad command-line argument. |
| `3` | One or more entries were skipped. Output is still printed; the code lets a script catch a config that has rotted. |

`?optional` skips and `-d` duplicate drops do not produce exit `3`.

An empty result is exit `1`, not an empty line: `export PATH="$(pathset)"` with
nothing to print leaves a shell that cannot find any command. Pass
`--allow-empty` if that is genuinely what you want.

### Catching a rotted config

`export PATH="$(pathset -q -d)"` hides more than it looks like it does. `-q`
drops the per-entry warnings, and the shell reports *`export`'s* exit status,
not `pathset`'s — so exit `3` never reaches you. To keep one signal, `-q`
still prints a summary:

```console
$ pathset -c bad.conf -q >/dev/null
pathset: 2 entries skipped (omit -q to see which)
```

Anywhere you want the status rather than the output, use `--check`:

```sh
pathset --check || echo "PATH config needs attention"
```

## Examples

With the config file shown above and `HOME=/Users/Shared/pathset-demo`:

```console
$ pathset -c demo.conf
/Users/Shared/pathset-demo/bin:/Users/Shared/pathset-demo/.local/bin:/usr/bin:/bin
```

`-v` shows the reasoning on stderr:

```console
$ pathset -c demo.conf -v > /dev/null
pathset: expanded '~/bin' -> '/Users/Shared/pathset-demo/bin'
pathset: expanded '~/.local/bin' -> '/Users/Shared/pathset-demo/.local/bin'
pathset: skipping optional '$RBENV_ROOT/shims': $RBENV_ROOT is not set
pathset: keeping '/Users/Shared/pathset-demo/bin'
pathset: keeping '/Users/Shared/pathset-demo/.local/bin'
pathset: keeping '/usr/bin'
pathset: keeping '/bin'
```

A required entry that is missing warns and sets exit `3`, but the rest is
still emitted:

```console
$ pathset -c bad.conf ; echo "exit=$?"
pathset: skipping '/opt/nope/bin': No such file or directory
/usr/bin
exit=3
```

### Adopting your current PATH

Seed the config from the value you already have, then edit it:

```sh
mkdir -p ~/.config/pathset
echo "$PATH" | tr ':' '\n' > ~/.config/pathset/path
```

Group entries with `#` comments, replace hardcoded home directories with `~`,
mark machine-specific ones `?`, and run `pathset -d -v` to see what survives
and what gets dropped. Then replace the `PATH=...` line in your rc with
`export PATH="$(pathset -q -d)"`.

Tools that append to `PATH` themselves (rbenv, asdf, Homebrew shellenv) keep
working — they prepend or append to the managed value.

## Limitations

- Comments are full-line only, because a path may legitimately contain `#`.
- A directory whose path contains `:` is skipped: the output format has no
  escape for the separator, so it cannot be represented.
- Directories that exist but are empty are dropped, by design.
- A directory unreadable due to permissions is indistinguishable from a
  missing one; both are dropped with a warning. This means a directory with
  execute-but-not-read permission is dropped even though `PATH` lookup would
  work in it — accepted, because detecting emptiness requires reading.

## Related

- [CHANGELOG.md](CHANGELOG.md) — release notes, including config-layout
  changes from earlier versions
- [CONTRIBUTING.md](CONTRIBUTING.md) — build targets and the release process

## License

MIT — see [LICENSE.md](LICENSE.md).
