# pathset

[![CI](https://github.com/grazij/pathset/actions/workflows/ci.yml/badge.svg)](https://github.com/grazij/pathset/actions/workflows/ci.yml)

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
and Shortcuts agree. A directory that doesn't exist, or is empty, is still
emitted — with a warning — unless you mark it `?`.

The output is data, not a shell command — compose it with `$(...)` into any
variable you like.

## Install

Needs a C11 compiler; no dependencies beyond libc.

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
| `-q` | Suppress the per-entry warnings. A one-line summary is still printed — see [Catching a rotted config](#catching-a-rotted-config). |
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

# conditional: left out entirely when rbenv isn't installed
?$RBENV_ROOT/shims

# system
/usr/bin
/bin
```

A plain entry is **always emitted**. If it is missing, empty, unreadable, or
not a directory, pathset warns on stderr and emits it anyway: the order you
declared is the order you get, and a stale entry costs one failed lookup
rather than silently changing the list.

Prefix an entry with `?` to make it **conditional**: it is checked first, and
included only if it is an existing, readable, non-empty directory. A `?` entry
that fails the check is dropped silently. Use it for entries that exist on
only some of the machines sharing the config, and for anything you would
rather leave out than be warned about on every shell startup.

Neither form affects the exit code from that check. Only a failed
*expansion* — an unset `$VAR`, an unknown `~user` — is a skip, and skips are
what produce exit `3`.

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
| `0` | Nothing was skipped. Entries emitted with a warning do not change this. |
| `1` | Fatal — missing config, I/O error, out of memory, or an empty result that no skip explains. |
| `2` | Bad command-line argument. |
| `3` | One or more entries were skipped — a failed expansion, or a `:` that cannot be represented. Output is still printed; the code lets a script catch a config that has rotted. |

A failed directory check is a warning, not a skip. `?conditional` drops and
`-d` duplicate drops do not produce exit `3` either.

An empty result is refused, not printed as an empty line:
`export PATH="$(pathset)"` with nothing to print leaves a shell that cannot
find any command. It exits `3` when skips account for the emptiness and `1`
when nothing does — an empty or all-comment config. Pass `--allow-empty` if an
empty result is genuinely what you want; the exit code is unchanged by it.

### Catching a rotted config

`export PATH="$(pathset -q -d)"` hides more than it looks like it does. `-q`
drops the per-entry warnings, and the shell reports *`export`'s* exit status,
not `pathset`'s — so exit `3` never reaches you. To keep one signal, `-q`
still prints a summary:

```console
$ pathset -c bad.conf -q >/dev/null
pathset: 2 entries emitted with warnings, 1 entry skipped (omit -q to see which)
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
pathset: skipping conditional '$RBENV_ROOT/shims': $RBENV_ROOT is not set
pathset: keeping '/Users/Shared/pathset-demo/bin'
pathset: keeping '/Users/Shared/pathset-demo/.local/bin'
pathset: keeping '/usr/bin'
pathset: keeping '/bin'
```

An entry that isn't a usable directory warns, is emitted anyway, and leaves
the exit code alone:

```console
$ pathset -c demo.conf ; echo "exit=$?"
pathset: '/opt/nope/bin' does not exist (emitted anyway)
/usr/bin:/opt/nope/bin
exit=0
```

An entry that fails to *expand* is the other case: there is no path to emit,
so it is skipped — and that is what sets exit `3`:

```console
$ pathset -c bad.conf ; echo "exit=$?"
pathset: skipping '$RBENV_ROOT/shims': $RBENV_ROOT is not set
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
- The `?` check needs read permission, because it uses `opendir(3)` to tell
  an empty directory from a populated one. `PATH` lookup needs only execute,
  so a `0111` directory is usable but fails the check and a `?` entry naming
  one is dropped. Write it without `?` to have it emitted.

## Related

- [CHANGELOG.md](CHANGELOG.md) — release notes, including config-layout
  changes from earlier versions
- [CONTRIBUTING.md](CONTRIBUTING.md) — build targets and the release process

## License

MIT — see [LICENSE.md](LICENSE.md).
