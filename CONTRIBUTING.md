# Contributing

The implementation is a single C11 source file (`pathset.c`) with no
dependencies beyond libc.

## Make targets

```sh
make build             # compile (native arch)
make lint              # syntax-only check
make test              # smoke tests in tests/run.sh
make clean             # remove build artifacts
make release           # clean build + tests, run before tagging
make universal         # macOS fat binary (arm64 + x86_64)
make release-universal # clean fat build + tests, run before tagging
make install           # install to $(PREFIX)/bin (default /usr/local)
make uninstall         # remove the installed binary and man page
make man               # regenerate pathset.1 (needs help2man)
```

`tests/run.sh` takes an optional filter when iterating on one case:

```sh
./tests/run.sh -l          # list the tests
./tests/run.sh 42          # run by number
./tests/run.sh dedup       # run by case-insensitive name substring
```

Every block still executes — fixtures are shared between blocks — so the
filter selects what is reported, not what runs. A filtered run says
`NOT A FULL RUN` and exits `2` if nothing matched. `make test` is unfiltered.

The Makefile sets no `-O` level — optimization is the builder's choice. Set
`CFLAGS`, `CPPFLAGS`, and `LDFLAGS` freely, including on the command line; the
flags pathset needs to compile correctly are kept outside `CFLAGS` and can't
be overridden away:

```sh
make build CFLAGS="-O3 -Wall"
```

`pathset.1` is committed and no build target regenerates it, so installing
never requires `help2man`. Run `make man` yourself after changing the `-h` or
`-V` text, and commit the result.

## Continuous integration

`.github/workflows/ci.yml` runs `make lint`, `make build` and `make test` on
every push and pull request, across the three C libraries pathset is built
against:

| Leg | Why it is there |
| --- | --- |
| `ubuntu-latest`, gcc and clang | glibc, under both compilers — they disagree about what `-Wall -Wextra -Wpedantic` is worth warning about |
| `macos-latest`, clang | the BSD/Darwin libc, `-mmacosx-version-min`, and the `arm64` + `x86_64` cross-build |
| `alpine:3.20`, gcc and clang | musl, the only libc that hides `getopt_long` behind `_GNU_SOURCE` |

Every leg also rebuilds with `-Werror`, since the default `CFLAGS` are
warnings-only and a new warning would otherwise scroll past a green run. What
CI deliberately does not cover, and why, is in the comments at the top of the
workflow.

CI is what makes a portability break visible before a user hits one. It does
not replace `make release`, which stays the gate before tagging: it is the
only thing that runs the suite against the exact binary being shipped.

## Releasing

```sh
# 1. Move the CHANGELOG [Unreleased] entries under a new version heading
#    and bump VERSION in the Makefile.
$EDITOR CHANGELOG.md Makefile

# 2. Regenerate and commit the man page. help2man stamps VERSION into the
#    .TH line, so a bump alone leaves pathset.1 stale even if -h is unchanged.
make man

# 3. Clean build + full test suite.
make release              # or: make release-universal

# 4. Commit the bump and push it. Wait for CI to go green.
git commit -am "chore(release): X.Y.Z"
git push origin main

# 5. Tag and push the tag.
git tag vX.Y.Z
git push origin vX.Y.Z
```

There is no publishing step. The in-repo Homebrew formula and the `make
formula` / `make formula-verify` targets were removed in 1170649, along with
`Formula/pathset.rb`, so a tag is the whole release. If a tap is reintroduced
later, it publishes from the tag rather than from this repo.

`make release` is a local pre-check and is not a substitute for CI: it runs on
one platform, and the portability breaks worth catching are the ones that only
appear on another libc.
