# Contributing

The implementation is a single C11 source file (`pathset.c`) with no
dependencies beyond libc.

## Make targets

```sh
make build             # compile (native arch)
make lint              # syntax-only check
make test              # smoke tests in tests/run.sh (75 assertions)
make clean             # remove build artifacts
make release           # clean build + tests, run before tagging
make universal         # macOS fat binary (arm64 + x86_64)
make release-universal # clean fat build + tests, run before tagging
make install           # install to $(PREFIX)/bin (default /usr/local)
make uninstall         # remove the installed binary and man page
make man               # regenerate pathset.1 (needs help2man)
make formula           # bump + publish the Homebrew formula
make formula-verify    # install from the published tap as a sanity check
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

## Releasing

The order matters: `make formula` computes the formula's `sha256` by
downloading the tagged tarball from GitHub, so **the tag must already be
pushed before it runs.**

```sh
# 1. Move the CHANGELOG [Unreleased] entries under a new version heading
#    and bump VERSION in the Makefile.
$EDITOR CHANGELOG.md Makefile

# 2. If the -h / -V text changed, regenerate and commit the man page.
make man

# 3. Clean build + full test suite.
make release              # or: make release-universal

# 4. Commit the bump and push it.
git commit -am "Bumped release to X.Y.Z"
git push origin main

# 5. Tag and push the tag. Do not skip the tag push.
git tag vX.Y.Z
git push origin vX.Y.Z

# 6. Publish the formula, then sanity-check the published tap.
make formula
make formula-verify
```

`make formula` runs end to end: downloads the tarball, computes its `sha256`,
rewrites `url` + `sha256` in `Formula/pathset.rb`, commits and pushes that
here, then copies the formula into the tap checkout and commits and pushes it
there. Never hand-edit those two lines.

It assumes the tap is cloned next to this repo. Override the location and
GitHub coordinates if your layout differs:

```sh
make formula TAP_DIR=../my-tap GITHUB_USER=alice GITHUB_REPO=pathset
```

### Troubleshooting a release

**`curl: (56) ... error: 404`** — the tag for the current `VERSION` isn't on
GitHub; step 5 was skipped, or only the commit was pushed. Confirm with
`git ls-remote --tags origin`, push the tag, and re-run.

**Verify the tap push landed.** `make formula` pushes two repos, and a failure
in the second leaves the tap commit unpushed locally — `brew install` then
keeps serving the previous version even though everything here looks released:

```sh
git -C ../homebrew-tap status -sb   # expect no "ahead" marker
```

`make formula-verify` catches this too: it untaps, re-taps, installs from the
published tap, prints `-V`, and uninstalls. Note the final `brew uninstall` —
if you keep `pathset` installed via Homebrew, reinstall it afterward.
