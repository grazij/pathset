# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- GitHub Actions CI builds and runs the test suite on glibc (gcc and clang),
  musl (gcc and clang, via Alpine) and macOS (clang), with warnings promoted
  to errors on every leg. `getopt_long` is not in the C standard and each
  libc exposes it on its own terms — musl only under `_GNU_SOURCE` — so the
  hand-rolled long-option parser below existed largely because nothing would
  have caught a portability break before a user did. Now something does.
- Five test cases for the long-option contract, which until now was only
  implied by the implementation: abbreviations, `--opt=value`, `--` ending
  option scanning, and the argv ordering described below.

### Changed

- **BREAKING** — an entry that is not a usable directory is now emitted with a
  warning instead of being dropped, and no longer affects the exit code. `?`
  changes meaning to match: it was "optional: skip quietly if broken", and is
  now "conditional: check before including". It keeps the full existing check
  (must be an existing, readable, non-empty directory) and drops the entry
  silently when it fails.

  Dropping an entry silently rewrites the order the config declared, and it
  did so in the one case where the check is wrong about usability:
  `dir_has_entries` uses `opendir`, which needs read permission, while `PATH`
  lookup needs only execute — so a `0111` directory was refused despite
  working perfectly. Emitting a dead entry costs one failed lookup; dropping a
  live one changes the answer.

  To keep the old behaviour for an entry, prefix it with `?`. Configs that
  already use `?` are unaffected. A config relying on a plain entry being
  dropped will now see it in the output, and will stop seeing exit `3` from
  the directory check.

- `-q` now summarises warnings as well as skips, e.g. `2 entries emitted with
  warnings, 1 entry skipped`. A warned entry leaves the exit status at `0`, so
  under `-q` — where the per-entry warnings are gone and `$(...)` has already
  discarded the status — the summary is its only trace.

- Long options are parsed by `getopt_long(3)` instead of a hand-rolled
  pre-pass that stripped them out of `argv` before `getopt(3)` saw it. The
  spellings accepted are unchanged — `--check`, `--allow-empty`, `--version`
  and `--help`, each written out in full. An abbreviation such as `--che`,
  and any `--opt=value` form, are still refused with `unknown argument` and
  exit `2`, in the same words as before: `getopt_long` accepts abbreviations
  on every libc that ships it, so pathset now rejects them deliberately
  rather than by not having implemented them. Answering to a prefix would
  make every future long-option rename a breaking change.
- `argv` is read once, left to right, so the first option that ends the run
  wins. `--help` and `--version` used to be lifted out of `argv` ahead of
  everything else and won wherever they appeared. Only self-contradictory
  mixtures change: `pathset -Z --help` now exits `2` on `-Z` instead of
  printing help, `pathset --help --bogus` now prints help instead of exiting
  `2`, and `pathset -c --help` now treats `--help` as the argument to `-c`
  (a config file of that name, which fails to open) instead of printing
  help. No single-purpose invocation is affected.

### Fixed

- A config whose entries were all skipped hit the empty-result guard and
  exited `1`, masking the exit `3` that says why. Exit `1` now means an empty
  result that no skip explains — an empty or all-comment config — and exit `3`
  covers the rest. Both are still refused rather than printed; `--allow-empty`
  still overrides the refusal without changing the code.

## 0.4.0

### Added

- `--check` validates the config and prints nothing to stdout, exiting with the
  usual codes. Intended as a guard in a shell rc, or in any script that wants
  the status rather than the output.
- `--allow-empty` permits an empty result, which is otherwise now fatal.
- `--help` and `--version` are accepted as long forms of `-h` and `-V`. They
  are hand-parsed rather than taken from `getopt_long`, which is a GNU/BSD
  extension absent from the C standard.
- `tests/run.sh` takes a filter: `./tests/run.sh 42`, `./tests/run.sh dedup`,
  or `./tests/run.sh -l` to list. Every block still executes, because
  fixtures are shared between blocks; the filter selects which assertions are
  reported. A filtered run prints `NOT A FULL RUN` and exits `2` if the
  filter matched nothing, so it cannot be mistaken for a clean suite.

### Changed

- `-q` no longer silences everything. It still drops the per-entry skip
  warnings, but now prints one summary line (`N entries skipped`). The
  documented invocation `export PATH="$(pathset -q -d)"` discards the exit
  status — the shell reports `export`'s, not pathset's — so exit `3` was
  unreachable in exactly the place it mattered, and a config that had rotted
  degraded `PATH` with no signal at all.
- An empty result is now fatal (exit `1`) instead of an empty line and exit
  `0`. `export PATH="$(pathset)"` with nothing to print leaves a shell that
  cannot find any command. `--allow-empty` restores the previous behaviour.
- `-d` now treats a trailing slash as insignificant, so `/opt/bin` and
  `/opt/bin/` collapse to a single entry. The survivor is still emitted
  exactly as it was written in the config; pathset does not rewrite entries.
- The build targets C11 (`-std=c11`) instead of C99. No C11-only feature is
  used yet; this only moves the baseline.

- `make release` and `make release-universal` no longer regenerate the man
  page. `make man` is now a maintainer-only step, run before tagging, and no
  build target depends on `help2man`.
- The Homebrew formula builds with `make build` instead of `make release`.
  Installing `pathset` no longer pulls in `help2man` as a build dependency,
  and no longer runs the test suite on the user's machine — that is the
  maintainer's `make release` before tagging. The committed `pathset.1` is
  installed as-is.
- The Makefile no longer sets any `-O` level. Optimization is the builder's
  choice; `CFLAGS ?= -Wall -Wextra -Wpedantic` is now warnings-only. This is
  also what Homebrew already assumed: its compiler shim discards any `-O` a
  build system passes and substitutes its own (`-Os` under clang), so the
  previous `-O3` on `release` never reached a brew-installed binary.

### Fixed

- An entry containing `:` was emitted verbatim and exited `0`, silently
  splitting into two elements and inventing a directory that was never
  declared. The format has no escape for `:`, so such an entry is now
  skipped with a warning. Checked after expansion, since a `:` can arrive
  through `$VAR`.

- A set-but-empty `$VAR` expanded to nothing instead of being skipped, so
  `$PREFIX/bin` with `PREFIX=""` exported silently became `/bin` — a real
  directory at the wrong priority, reported as success. Empty is now treated
  as unset, which is what the `~` branch and the config lookup already did for
  `HOME` and `XDG_CONFIG_HOME`. `-v` distinguishes "is empty" from "is not
  set".

- The Makefile carried flags required for correctness (`-std=c99`,
  `-DPATHSET_VERSION`, `-mmacosx-version-min`) inside `CFLAGS`, which is the
  builder's variable to replace. Any `make CFLAGS=...` override deleted them
  and produced a binary reporting `pathset unknown` from `-V`. They now live
  in `REQUIRED_CFLAGS`, applied before `$(CFLAGS)` so an override can no
  longer remove them but still wins on warnings and optimization. `CPPFLAGS`
  and `LDFLAGS` are now honored as well.

- The generated man page rendered the em-dashes in the `-h` config-lookup
  text as `???`. The help text now uses ASCII there.
- `~user` expansion was documented in `pathset.c` as using `dscl`/`getent`;
  it uses `getpwnam(3)`.

## 0.3.1

### Fixed

- Homebrew: the formula installed the binary but not the man page. `install`
  now runs `make release` (which regenerates `pathset.1`, hence the new
  `help2man` build dependency) and installs the page into `man1`.

## 0.3.0

### Added

- `-k KIND` flag selects which config to read. Valid kinds: `path`
  (default), `man`, `info`, `fpath`. The output format is unchanged
  (still a `:`-joined string) — the kind only chooses which file is
  read, so users can compose the result into `PATH`, `MANPATH`,
  `INFOPATH`, or zsh's `fpath` array.
- New starter examples: `examples/man.example` and
  `examples/fpath.example`.

### Changed (breaking)

- The canonical config filename is now `<kind>` (e.g. `path`, `man`)
  instead of `config`. Lookup paths become:
  1. `-c CONFIG`
  2. `$XDG_CONFIG_HOME/pathset/<kind>`
  3. `$HOME/.config/pathset/<kind>` (canonical)
  4. `$HOME/.pathset/<kind>`

  Existing users must rename their config:
  `mv ~/.config/pathset/config ~/.config/pathset/path`.
- The `$HOME/.pathset` single-file fallback is removed — it doesn't
  fit the multi-kind layout. Move to `~/.config/pathset/path` if you
  were using it.
- Invalid `-k` values (anything outside `{path, man, info, fpath}`)
  exit `2`. When both `-c` and `-k` are given, `-c` wins and `-k` is
  silently ignored (kind only affects the default lookup).
- Renamed `examples/config.example` → `examples/path.example`.

## 0.2.0

### Changed (breaking)

- Renamed the project from `pathmgr` to `pathset`. The binary, source
  file (`pathset.c`), man page (`pathset.1`), and Homebrew formula are
  all renamed in lockstep.
- Config lookup paths are renamed accordingly. New locations (first
  match wins):
  1. `-c CONFIG`
  2. `$XDG_CONFIG_HOME/pathset/config`
  3. `$HOME/.config/pathset/config` (canonical)
  4. `$HOME/.pathset/config`
  5. `$HOME/.pathset`
- No fallback to old `pathmgr` paths is provided. Users on 0.1.0 must
  move their config: `mv ~/.config/pathmgr ~/.config/pathset` (or the
  equivalent for whichever location they used).
- The `-V` output now prints `pathset X.Y.Z` instead of `pathmgr X.Y.Z`.
- The default `make` / `make build` / `make release` build is now a
  **native single-arch** binary (was: macOS universal). Source-based
  installers like Homebrew compile on the user's host and don't benefit
  from a fat binary. Pass `make universal` or `make release-universal`
  to opt in to a fat binary for prebuilt-distribution artifacts.
- The GitHub repository was renamed from `grazij/pathmgr` to
  `grazij/pathset`. GitHub redirects from the old name continue to work
  for clones, but published Homebrew formula URLs now point at the new
  repo.

### Added

- `make universal` and `make release-universal` targets — explicit
  opt-in fat (`-arch arm64 -arch x86_64`) builds on macOS.
- `make release` and `make release-universal` now also run `make test`
  and `make man`, then print `./pathset -V` and a tag-and-push reminder.
  The full release artifact is verified before you tag.
- `make formula VERSION=X.Y.Z` — fetches the tagged tarball from
  GitHub, computes its SHA256, rewrites `Formula/pathset.rb` (`url` and
  `sha256` lines), commits + pushes to this repo, then mirrors the
  formula to `$TAP_DIR` (default `../homebrew-tap`) and commits +
  pushes there. Override `TAP_DIR`, `GITHUB_USER`, `GITHUB_REPO` if
  your layout differs.
- `make formula-verify` — first-time / sanity-check `brew tap` +
  `install` + `pathset -V` + `uninstall` round-trip against the
  published tap.

### Documentation

- README now explains *why* `pathset` exists: macOS `/etc/zprofile`
  runs `/usr/libexec/path_helper` before `~/.zshenv`, which rewrites
  `PATH` from `/etc/paths` and `/etc/paths.d/*` and pins Apple's
  (often empty) directories first. The Shortcuts app's "Run Shell
  Script" only loads `~/.zshenv`, so without an override it inherits
  whatever `path_helper` produced.
- The recommended shell-rc invocation is now `pathset -q -d` (was
  `pathset -q`). Deduplication is appropriate for the PATH-setting use
  case and avoids accidental duplicates when composing with `$PATH`.
  Updated in README, examples/config.example, `-h` help text, and the
  regenerated man page.

## 0.1.0 — initial release

`pathmgr` is a single-file C99 utility (no dependencies beyond libc) that
reads a list of directories from a config file and prints a `:`-joined
path string to stdout. Intended use:

```sh
export PATH="$(pathmgr -q)"
```

### Behavior

- **Config lookup order** (first match wins): `-c CONFIG` →
  `$XDG_CONFIG_HOME/pathmgr/config` (if set) →
  `$HOME/.config/pathmgr/config` (XDG default — canonical) →
  `$HOME/.pathmgr/config` (legacy) → `$HOME/.pathmgr` (single-file).
- **Comments and blanks:** lines whose first non-whitespace character is
  `#` are full-line comments. Blank lines are ignored. CRLF tolerated.
- **Expansion** (per entry, before the directory check): `~/foo`,
  `~user/foo` (via `getpwnam(3)`), `$VAR/foo`, `${VAR}/foo`. Mid-string
  `~`, `${VAR:-default}`, and `\$`-style escapes are intentionally not
  supported.
- **Filtering:** entries that don't exist or are empty directories are
  skipped with a stderr warning. Suppress warnings with `-q`.
- **Optional entries:** prefix a line with `?` (e.g. `?/opt/homebrew/bin`)
  to mark it optional. Optional entries that fail to expand or aren't
  valid directories are silently skipped without affecting the exit code.
- **Output:** bare `:`-joined string, one line. Compose with `$(...)` —
  there is no `PATH=` wrapping.
- **Universal binary on macOS** (`-arch arm64 -arch x86_64`,
  `-mmacosx-version-min=11.0`).

### Flags

| Flag | Purpose |
| --- | --- |
| `-c CONFIG` | Read config from `CONFIG` (overrides default lookup) |
| `-d` | Drop duplicate entries (first occurrence wins) |
| `-q` | Suppress skip warnings on stderr |
| `-v` | Print kept entries, expansions, and dropped duplicates on stderr (`-q` wins if both are given) |
| `-V` | Print version (`pathmgr X.Y.Z`) and exit |
| `-h` | Show help and exit |

Argument parsing uses POSIX `getopt(3)`; short-option bundling (`-dq`)
works. Long options (`--help`, `--version`) are not supported.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every config entry was emitted |
| `1` | Fatal error (missing config, I/O error, out of memory) |
| `2` | Bad command-line argument |
| `3` | One or more entries were skipped during expansion or filtering. `?optional` skips and dedup drops do **not** contribute. |

### Distribution

- `Formula/pathmgr.rb` — Homebrew formula (placeholders for tarball URL
  and SHA256; fill in once a release is tagged).
- `examples/config.example` — portable starter config.
- `pathmgr.1` — man page generated from `-h`/`-V` output via
  `help2man`. Regenerate with `make man`. `make install` copies it to
  `$(PREFIX)/share/man/man1/`.
