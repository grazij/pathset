/* getopt_long(3) is not in POSIX, and every libc hides it behind different
 * rules: the glibc and BSD/Darwin <getopt.h> declare it unconditionally, but
 * musl declares it only under _GNU_SOURCE (or the deprecated _BSD_SOURCE,
 * which makes glibc emit a #warning). _GNU_SOURCE is the one spelling all
 * three honour, and it only widens what _POSIX_C_SOURCE selects -- the POSIX
 * baseline below still records what the rest of this file relies on. Nothing
 * here uses a call whose semantics _GNU_SOURCE changes (strerror_r, basename).
 * Darwin ignores the macro entirely. */
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <getopt.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *PROG = "pathset";

#ifndef PATHSET_VERSION
#define PATHSET_VERSION "unknown"
#endif

/* An -f argument that is not a path is a filename under `pathset/`, and any
 * name works -- `path`, `man`, `info` and `fpath` are only the ones the docs
 * demonstrate. There is no list to validate against, so a name that does not
 * exist is the ordinary "cannot open" fatal, naming the path it tried. The
 * output format is identical whichever config is read; the caller composes it
 * into PATH, MANPATH, INFOPATH, or fpath. */
#define DEFAULT_CONFIG "path"

static _Noreturn void vdie(int code, int hint, const char *fmt, va_list ap) {
	fprintf(stderr, "%s: ", PROG);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	/* A usage error names the one thing that was wrong and points at -h.
	 * Dumping the whole help here buried that line under three screenfuls. */
	if (hint) fprintf(stderr, "Try '%s --help' for more information.\n", PROG);
	exit(code);
}

static void die(int code, const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vdie(code, 0, fmt, ap);
}

/* Every bad-argument exit: always 2, always with the -h pointer. */
static void die_usage(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vdie(2, 1, fmt, ap);
}

static void usage(FILE *out) {
	fprintf(out,
		"Usage: %s [-f NAME|FILE] [-q] [-v] [-s] [--check] [--allow-empty]\n"
		"   or: %s [-V|--version] [-h|--help]\n"
		"\n"
		"Reads a list of directories from a config file and prints them to stdout\n"
		"joined by ':', or by a space under -s. Duplicate entries are dropped,\n"
		"first occurrence wins; a trailing slash does not make an entry distinct.\n"
		"Compose with $(...):\n"
		"  export PATH=\"$(%s -q)\"\n"
		"  export MANPATH=\"$(%s -f man -q)\"\n"
		"  export INFOPATH=\"$(%s -f info -q)\"\n"
		"  fpath=( $(%s -f fpath -q -s) )   # zsh array\n"
		"\n"
		"Options:\n"
		"  -f, --file NAME    read the config named NAME, looked up as shown below\n"
		"                     (default: path). An argument containing '/' is read\n"
		"                     as a path to a file instead, with no fallback if it\n"
		"                     is missing.\n"
		"  -q                 suppress the per-entry warnings. A one-line summary\n"
		"                     is still printed: $(...) discards the exit status, so\n"
		"                     it would otherwise be the only signal, and silent.\n"
		"  -v                 print kept entries and expansions on stderr (-q wins)\n"
		"  -s, --space        join with a space instead of ':', so the result reads\n"
		"                     as a shell array. An entry containing whitespace is\n"
		"                     then the unrepresentable one and is skipped, exactly\n"
		"                     as a ':' entry is under the default separator.\n"
		"  --check            validate only: print nothing on stdout, exit as below\n"
		"  --allow-empty      print an empty result instead of failing on one\n"
		"  -V, --version      print version and exit\n"
		"  -h, --help         show this help and exit\n"
		"\n"
		"Config file syntax:\n"
		"  - one directory per line, in priority order\n"
		"  - lines whose first non-whitespace character is '#' are comments\n"
		"    (full-line only; '#' mid-path is data, not a comment)\n"
		"  - blank lines are ignored; CRLF line endings are tolerated\n"
		"  - an entry that is missing, empty, unreadable or not a directory\n"
		"    is still emitted, with a warning; it never affects the exit code\n"
		"  - prefix an entry with '?' to make it conditional: it must be an\n"
		"    existing, readable, non-empty directory or it is dropped\n"
		"    silently: e.g. `?/opt/homebrew/bin`\n"
		"\n"
		"Expansion (applied per entry, before the directory check):\n"
		"  ~/foo        $HOME/foo            (only at start of entry)\n"
		"  ~user/foo    that user's home + /foo (via getpwnam)\n"
		"  $VAR/foo     $VAR/foo             (unset OR empty -> skip)\n"
		"  ${VAR}/foo   braced form, useful next to a name char\n"
		"  Not supported: mid-string '~', ${VAR:-default}, '\\$' escapes.\n"
		"\n"
		"Config lookup (first match wins; <name> is the -f value, default 'path'):\n"
		"  1. -f FILE, an argument containing '/' (no fallback: fatal error)\n"
		"  2. $XDG_CONFIG_HOME/pathset/<name> (only if XDG_CONFIG_HOME is set)\n"
		"  3. $HOME/.config/pathset/<name>    (XDG default, canonical)\n"
		"  4. $HOME/.pathset/<name>           (legacy home location)\n"
		"\n"
		"Shell setup (add to your shell rc):\n"
		"  zsh / bash:  export PATH=\"$(%s -q)\"\n"
		"  fish:        set -gx PATH (%s -q | string split :)\n"
		"\n"
		"Exit codes:\n"
		"  0  nothing was skipped (an entry emitted with a warning is not\n"
		"     a skip)\n"
		"  1  fatal error (missing config, I/O error, out of memory, or an\n"
		"     empty result that no skip explains)\n"
		"  2  bad command-line argument\n"
		"  3  one or more entries were skipped: an expansion failure, or a\n"
		"     character the separator cannot represent. '?conditional' drops\n"
		"     and duplicate drops do NOT contribute\n",
		PROG, PROG, PROG, PROG, PROG, PROG, PROG, PROG);
}

static char *xstrdup(const char *s) {
	size_t n = strlen(s) + 1;
	char *p = malloc(n);
	if (!p) die(1, "out of memory");
	memcpy(p, s, n);
	return p;
}

/* Builds "<prefix>/<segment>/<name>". */
static char *join3(const char *prefix, const char *segment, const char *name) {
	size_t lp = strlen(prefix), ls = strlen(segment), lk = strlen(name);
	/* +2 for two '/' separators, +1 for terminator */
	char *p = malloc(lp + 1 + ls + 1 + lk + 1);
	if (!p) die(1, "out of memory");
	memcpy(p, prefix, lp);
	p[lp] = '/';
	memcpy(p + lp + 1, segment, ls);
	p[lp + 1 + ls] = '/';
	memcpy(p + lp + 1 + ls + 1, name, lk + 1);
	return p;
}

/*
 * Lookup order is documented in usage(). The non-obvious part: when neither
 * home location exists, the canonical XDG path is returned anyway, so the
 * "cannot open" error names the location the README tells users to create.
 */
static char *resolve_config_path(const char *override, const char *name) {
	if (override) return xstrdup(override);

	const char *xdg = getenv("XDG_CONFIG_HOME");
	if (xdg && *xdg) return join3(xdg, "pathset", name);

	const char *home = getenv("HOME");
	if (home && *home) {
		char *xdg_default = join3(home, ".config/pathset", name);
		if (access(xdg_default, F_OK) == 0) return xdg_default;
		char *legacy_dir = join3(home, ".pathset", name);
		if (access(legacy_dir, F_OK) == 0) {
			free(xdg_default);
			return legacy_dir;
		}
		free(legacy_dir);
		return xdg_default;
	}

	die(1, "no -f path given and neither XDG_CONFIG_HOME nor HOME is set");
	return NULL;
}

static void trim(char **start, size_t *len) {
	char *s = *start;
	size_t n = *len;
	while (n > 0 && isspace((unsigned char)s[0])) { s++; n--; }
	while (n > 0 && isspace((unsigned char)s[n - 1])) n--;
	*start = s;
	*len = n;
}

/* `conditional` marks a `?`-prefixed entry: it is checked before being
 * included and dropped silently when the check fails. A plain entry is
 * emitted whatever the check says. Neither form contributes to exit 3 from
 * the directory check; only an expansion failure does. */
typedef struct {
	char *path;
	int conditional;
} Entry;

typedef struct {
	Entry *items;
	size_t n;
	size_t cap;
} Vec;

static void vec_push(Vec *v, char *s, int conditional) {
	if (v->n == v->cap) {
		size_t nc = v->cap ? v->cap * 2 : 16;
		Entry *np = realloc(v->items, nc * sizeof(Entry));
		if (!np) die(1, "out of memory");
		v->items = np;
		v->cap = nc;
	}
	v->items[v->n].path = s;
	v->items[v->n].conditional = conditional;
	v->n++;
}

/*
 * Returns 1 if `dir` is a directory containing at least one entry other than
 * "." and "..", 0 if it's an existing-but-empty directory, and -1 on any
 * stat/open failure (with errno set).
 */
static int dir_has_entries(const char *dir) {
	struct stat st;
	if (stat(dir, &st) != 0) return -1;
	if (!S_ISDIR(st.st_mode)) {
		errno = ENOTDIR;
		return -1;
	}
	DIR *d = opendir(dir);
	if (!d) return -1;
	int found = 0;
	struct dirent *e;
	errno = 0;
	while ((e = readdir(d)) != NULL) {
		if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
		found = 1;
		break;
	}
	int read_err = errno;
	closedir(d);
	if (!found && read_err != 0) {
		errno = read_err;
		return -1;
	}
	return found;
}

static void read_paths(const char *path, Vec *out) {
	FILE *f = fopen(path, "r");
	if (!f) die(1, "cannot open '%s': %s", path, strerror(errno));

	char *line = NULL;
	size_t cap = 0;
	ssize_t got;
	while ((got = getline(&line, &cap, f)) != -1) {
		char *s = line;
		size_t n = (size_t)got;
		trim(&s, &n);
		if (n == 0 || s[0] == '#') continue;

		/* Leading `?` marks the entry as conditional. Strip it; whitespace
		 * between `?` and the path is allowed. */
		int conditional = 0;
		if (s[0] == '?') {
			conditional = 1;
			s++; n--;
			while (n > 0 && isspace((unsigned char)s[0])) { s++; n--; }
			if (n == 0) continue;  /* "?" with no path is ignored */
		}

		char *entry = malloc(n + 1);
		if (!entry) die(1, "out of memory");
		memcpy(entry, s, n);
		entry[n] = '\0';
		vec_push(out, entry, conditional);
	}
	free(line);
	if (ferror(f)) die(1, "read error on '%s': %s", path, strerror(errno));
	if (fclose(f) != 0) die(1, "close error on '%s': %s", path, strerror(errno));
}

/*
 * stdout is the whole product: `export PATH="$(pathset -q)"` splices it
 * straight into the shell. A short write on a full disk or a closed fd would
 * otherwise truncate PATH mid-directory and still exit 0 -- silent, because
 * $(...) reports the *shell's* status and the -q summary only counts config
 * faults, never I/O. exit()'s implicit flush cannot report this; it discards
 * the error. So every path that writes to stdout ends here first.
 */
static void flush_stdout_or_die(void) {
	if (fflush(stdout) != 0 || ferror(stdout))
		die(1, "write error on stdout: %s", strerror(errno));
}

static void print_path(const Vec *v, int words) {
	for (size_t i = 0; i < v->n; i++) {
		if (i) fputc(words ? ' ' : ':', stdout);
		fputs(v->items[i].path, stdout);
	}
	fputc('\n', stdout);
}

/*
 * Growing byte buffer. Owns its allocation; caller takes the buffer with
 * `b->buf` (transfers ownership) or frees it.
 */
typedef struct {
	char *buf;
	size_t n;
	size_t cap;
} Buf;

static void buf_append(Buf *b, const char *s, size_t len) {
	if (b->n + len + 1 > b->cap) {
		size_t nc = b->cap ? b->cap : 64;
		while (nc < b->n + len + 1) nc *= 2;
		char *np = realloc(b->buf, nc);
		if (!np) die(1, "out of memory");
		b->buf = np;
		b->cap = nc;
	}
	memcpy(b->buf + b->n, s, len);
	b->n += len;
	b->buf[b->n] = '\0';
}

/* Returns a malloc'd home dir, or NULL if the user is unknown or has none. */
static char *lookup_user_home(const char *user) {
	errno = 0;
	struct passwd *pw = getpwnam(user);
	if (!pw || !pw->pw_dir || !*pw->pw_dir) return NULL;
	return xstrdup(pw->pw_dir);
}

/*
 * Expands one config entry: a leading `~/` or `~user/`, plus `$VAR` and
 * `${VAR}` anywhere. Unsupported forms are listed in usage().
 *
 * Returns a malloc'd string, or NULL with a short reason in *err. That
 * reason points at static storage the next call overwrites, so the caller
 * must use it before expanding another entry.
 */
static char *expand_entry(const char *in, const char **err) {
	static char errbuf[320];
	Buf b = {0};
	const char *p = in;

	if (*p == '~') {
		const char *u = p + 1;
		const char *slash = strchr(u, '/');
		size_t ulen = slash ? (size_t)(slash - u) : strlen(u);
		char *home = NULL;
		if (ulen == 0) {
			const char *h = getenv("HOME");
			if (!h || !*h) { *err = "HOME is not set"; goto fail; }
			home = xstrdup(h);
		} else {
			if (ulen >= 128) { *err = "username too long"; goto fail; }
			char user[128];
			memcpy(user, u, ulen);
			user[ulen] = '\0';
			home = lookup_user_home(user);
			if (!home) {
				snprintf(errbuf, sizeof errbuf, "unknown user '%s'", user);
				*err = errbuf;
				goto fail;
			}
		}
		buf_append(&b, home, strlen(home));
		free(home);
		p = slash ? slash : u + ulen;
	}

	while (*p) {
		if (*p != '$') {
			buf_append(&b, p, 1);
			p++;
			continue;
		}
		const char *name_start;
		size_t name_len;
		const char *after;
		if (p[1] == '{') {
			name_start = p + 2;
			const char *close = strchr(name_start, '}');
			if (!close) { buf_append(&b, p, 1); p++; continue; }
			name_len = (size_t)(close - name_start);
			after = close + 1;
		} else if (isalpha((unsigned char)p[1]) || p[1] == '_') {
			name_start = p + 1;
			const char *e = name_start;
			while (*e && (isalnum((unsigned char)*e) || *e == '_')) e++;
			name_len = (size_t)(e - name_start);
			after = e;
		} else {
			buf_append(&b, p, 1);
			p++;
			continue;
		}
		if (name_len == 0 || name_len >= 256) {
			*err = "invalid variable name";
			goto fail;
		}
		char name[256];
		memcpy(name, name_start, name_len);
		name[name_len] = '\0';
		const char *val = getenv(name);
		/* An exported-but-empty variable would expand to nothing, silently
		 * promoting "$PREFIX/bin" to "/bin" -- a real directory at the wrong
		 * priority. Treat empty as unset, which is what the ~ branch and
		 * resolve_config_path already do for HOME and XDG_CONFIG_HOME. */
		if (!val || !*val) {
			snprintf(errbuf, sizeof errbuf, "$%s is %s", name,
				val ? "empty" : "not set");
			*err = errbuf;
			goto fail;
		}
		buf_append(&b, val, strlen(val));
		p = after;
	}

	if (!b.buf) return xstrdup("");
	return b.buf;

fail:
	free(b.buf);
	return NULL;
}

/*
 * The output format has no escape for its separator, so an entry containing
 * one would silently split into two elements and invent a directory that was
 * never declared. Which character is unrepresentable follows the separator:
 * ':' by default, and any whitespace under -s, since that is what a shell
 * splits a space-joined list on. Returns the reason phrase, or NULL when the
 * entry can be represented.
 */
static const char *unrepresentable(const char *s, int words) {
	if (words) {
		return strpbrk(s, " \t\n")
			? "contains whitespace, which cannot be represented in a space-joined list"
			: NULL;
	}
	return strchr(s, ':')
		? "contains ':', which cannot be represented in a ':'-joined list"
		: NULL;
}

static void expand_paths(Vec *v, int quiet, int verbose, int *skipped, int words) {
	size_t kept = 0;
	for (size_t i = 0; i < v->n; i++) {
		Entry e = v->items[i];
		const char *err = NULL;
		char *exp = expand_entry(e.path, &err);
		/* Dropped like any other failed entry. Checked after expansion,
		 * because the separator can arrive through $VAR. */
		const char *unrep = exp ? unrepresentable(exp, words) : NULL;
		if (unrep) {
			free(exp);
			exp = NULL;
			err = unrep;
		}
		if (!exp) {
			if (e.conditional) {
				if (verbose) {
					fprintf(stderr, "%s: skipping conditional '%s': %s\n", PROG, e.path, err);
				}
			} else {
				if (!quiet) {
					fprintf(stderr, "%s: skipping '%s': %s\n", PROG, e.path, err);
				}
				(*skipped)++;
			}
			free(e.path);
			continue;
		}
		if (verbose && strcmp(e.path, exp) != 0) {
			fprintf(stderr, "%s: expanded '%s' -> '%s'\n", PROG, e.path, exp);
		}
		free(e.path);
		v->items[kept].path = exp;
		v->items[kept].conditional = e.conditional;
		kept++;
	}
	v->n = kept;
}

/*
 * Length of `p` with trailing slashes ignored. Never reduces "/" (or "//") to
 * the empty string, so root stays comparable to itself and to nothing else.
 */
static size_t path_cmp_len(const char *p) {
	size_t n = strlen(p);
	while (n > 1 && p[n - 1] == '/') n--;
	return n;
}

/* True when two entries name the same directory. Compares normalized so
 * "/x" and "/x/" collapse, but the caller still emits the entry as declared:
 * pathset prints the path you wrote, not a rewritten one. */
static int same_dir(const char *a, const char *b) {
	size_t la = path_cmp_len(a), lb = path_cmp_len(b);
	return la == lb && memcmp(a, b, la) == 0;
}

/*
 * In-place dedup: keep the first occurrence of each entry, drop later ones.
 * The O(n^2) scan is fine; config files are tiny.
 */
static void dedup_paths(Vec *v, int verbose) {
	size_t kept = 0;
	for (size_t i = 0; i < v->n; i++) {
		Entry e = v->items[i];
		int dup = 0;
		for (size_t j = 0; j < kept; j++) {
			if (same_dir(v->items[j].path, e.path)) { dup = 1; break; }
		}
		if (dup) {
			if (verbose) fprintf(stderr, "%s: dropping duplicate '%s'\n", PROG, e.path);
			free(e.path);
		} else {
			v->items[kept++] = e;
		}
	}
	v->n = kept;
}

/*
 * A phrase completing "'<path>' ...", so both messages below read as English.
 * `rc` and `err` come straight from dir_has_entries and the errno it left.
 * The strerror fallback uses a static buffer the next call overwrites, so the
 * caller must consume it before checking another entry.
 */
static const char *unusable_reason(int rc, int err) {
	static char buf[320];
	if (rc == 0) return "is an empty directory";
	switch (err) {
	case ENOENT: return "does not exist";
	case ENOTDIR: return "is not a directory";
	case EACCES: return "is not readable";
	default: break;
	}
	snprintf(buf, sizeof buf, "is unusable: %s", strerror(err));
	return buf;
}

/*
 * The directory check, which decides nothing on its own for a plain entry: an
 * unusable directory in PATH costs a wasted lookup, while dropping it silently
 * reorders the list the config declared and hides the real fault. So a plain
 * entry is always emitted and only warns, never touching the exit code.
 *
 * `?` is the checked form: it must be an existing, readable, non-empty
 * directory or it is dropped, silently. Neither outcome is a skip -- only
 * expansion failure sets *skipped, back in expand_paths.
 */
static void filter_paths(Vec *v, int quiet, int verbose, int *warned) {
	size_t kept = 0;
	for (size_t i = 0; i < v->n; i++) {
		Entry e = v->items[i];
		int rc = dir_has_entries(e.path);
		int err = errno;
		if (rc != 1 && e.conditional) {
			if (verbose) {
				fprintf(stderr, "%s: skipping conditional '%s': %s\n",
					PROG, e.path, unusable_reason(rc, err));
			}
			free(e.path);
			continue;
		}
		if (rc != 1) {
			if (!quiet) {
				fprintf(stderr, "%s: '%s' %s (emitted anyway)\n",
					PROG, e.path, unusable_reason(rc, err));
			}
			(*warned)++;
		}
		if (verbose) fprintf(stderr, "%s: keeping '%s'\n", PROG, e.path);
		v->items[kept++] = e;
	}
	v->n = kept;
}

/*
 * Long options are parsed by getopt_long(3) alongside the short ones, so argv
 * is scanned once, left to right, and a long option no longer wins over an
 * error that precedes it.
 *
 * Every long option carries a val of its own, outside the range of a char --
 * including the two that also have a short spelling, which map onto it in the
 * switch. That is what keeps the error paths below unambiguous: optopt holds a
 * short-option character only when a short option failed, because an
 * unrecognised long option leaves it 0, and a long option that is missing its
 * argument or handed one it does not take leaves it set to that option's own
 * val. Give `--space` the val 's' instead and `--space=x` would report `-s`.
 */
enum { OPT_CHECK = 1000, OPT_ALLOW_EMPTY, OPT_VERSION, OPT_HELP, OPT_FILE, OPT_SPACE };

static const struct option LONG_OPTS[] = {
	{"file",        required_argument, NULL, OPT_FILE},
	{"space",       no_argument,       NULL, OPT_SPACE},
	{"check",       no_argument,       NULL, OPT_CHECK},
	{"allow-empty", no_argument,       NULL, OPT_ALLOW_EMPTY},
	{"version",     no_argument,       NULL, OPT_VERSION},
	{"help",        no_argument,       NULL, OPT_HELP},
	{NULL,          0,                 NULL, 0}
};

/*
 * The "--name" token getopt_long has just dealt with, or NULL if the thing it
 * just dealt with was not one. glibc, musl and the BSDs all advance optind
 * past a long option before returning -- success or failure -- so it sits at
 * argv[optind - 1]; argv[optind] is checked too so a libc that reports before
 * advancing still names the right token instead of a stale one.
 */
static const char *long_token(int argc, char **argv) {
	for (int i = optind - 1; i <= optind; i++) {
		if (i < 1 || i >= argc) continue;
		const char *t = argv[i];
		if (t[0] == '-' && t[1] == '-' && t[2] != '\0') return t;
	}
	return NULL;
}

/*
 * The `--name` token getopt_long just *matched*, which long_token cannot find
 * on its own: optind has advanced past the token by one for `--check` and
 * `--file=NAME`, but by two for the separate `--file NAME` form, where the
 * argument sits at optind - 1 and the token at optind - 2. optarg is what
 * tells those apart -- for the separate form every libc hands back the argv
 * pointer itself, while `--file=NAME` points into the middle of the token.
 * Inferring from optind alone lands on NAME, or on the option after it.
 */
static const char *matched_long_token(int argc, char **argv, const struct option *matched) {
	int i = optind - 1;
	if (matched->has_arg != no_argument && optarg && i >= 1 && argv[i] == optarg) i--;
	if (i < 1 || i >= argc) return NULL;
	const char *t = argv[i];
	return (t[0] == '-' && t[1] == '-' && t[2] != '\0') ? t : NULL;
}

/*
 * getopt_long accepts any unambiguous abbreviation of a long option, so
 * `--che` would reach us as `--check`. pathset has never accepted one, and
 * silently widening the spellings it answers to would turn every future
 * rename into a breaking change. An inexact match is rejected with the same
 * message an unknown option gets. `--file` takes an argument, so the token can
 * carry a `--file=NAME` suffix: only the part before `=` is the spelling, and
 * comparing the whole token would reject the documented form.
 */
static void reject_abbreviation(int argc, char **argv, const struct option *matched) {
	const char *tok = matched_long_token(argc, argv, matched);
	if (!tok) return;
	const char *given = tok + 2;
	size_t n = strcspn(given, "=");
	if (strlen(matched->name) != n || strncmp(given, matched->name, n) != 0) {
		die_usage("unknown argument: %s", tok);
	}
}

int main(int argc, char **argv) {
	const char *cfg_override = NULL;
	const char *cfg_name = DEFAULT_CONFIG;
	int quiet = 0;
	int verbose = 0;
	int words = 0;

	int check = 0;
	int allow_empty = 0;

	/* Suppress getopt's auto-error so we control the exit code (must be 2)
	 * and the message format. */
	opterr = 0;
	for (;;) {
		/* getopt_long writes longidx only when a long option matched, so it
		 * is reset every round rather than once before the loop. */
		int longidx = -1;
		int opt = getopt_long(argc, argv, ":f:qvVsh", LONG_OPTS, &longidx);
		if (opt == -1) break;
		if (longidx >= 0) reject_abbreviation(argc, argv, &LONG_OPTS[longidx]);
		switch (opt) {
		/* One flag, two meanings, split on '/': an argument that contains
		 * one is a path to a file, anything else is a config name looked up
		 * under `pathset/`. Both are reset so a repeated -f is honestly
		 * last-wins rather than leaving the earlier branch's value to win by
		 * short-circuit inside resolve_config_path. The empty string is the
		 * one rejected argument: it is neither, and would resolve to the
		 * directory itself. */
		case OPT_FILE:
		case 'f':
			if (!*optarg) {
				die_usage("-f needs a config name or a path, not an empty string");
			}
			if (strchr(optarg, '/')) {
				cfg_override = optarg;
				cfg_name = DEFAULT_CONFIG;
			} else {
				cfg_name = optarg;
				cfg_override = NULL;
			}
			break;
		case OPT_SPACE:
		case 's': words = 1; break;
		case 'q': quiet = 1; break;
		case 'v': verbose = 1; break;
		case OPT_CHECK: check = 1; break;
		case OPT_ALLOW_EMPTY: allow_empty = 1; break;
		case OPT_VERSION:
		case 'V':
			printf("%s %s\n", PROG, PATHSET_VERSION);
			flush_stdout_or_die();
			return 0;
		case OPT_HELP:
		case 'h':
			usage(stdout);
			flush_stdout_or_die();
			return 0;
		case ':':
		case '?':
		default: {
			const char *tok = long_token(argc, argv);
			if (opt == ':' && tok)
				die_usage("%s requires an argument", tok);
			if (tok && (optopt == 0 || optopt >= OPT_CHECK))
				die_usage("unknown argument: %s", tok);
			if (opt == ':')
				die_usage("-%c requires an argument", optopt);
			die_usage("unknown argument: -%c", optopt);
		}
		}
	}
	if (optind < argc) {
		die_usage("unexpected argument: %s", argv[optind]);
	}

	if (quiet) verbose = 0;

	char *cfg = resolve_config_path(cfg_override, cfg_name);
	Vec v = {0};
	int skipped = 0;
	int warned = 0;
	read_paths(cfg, &v);
	expand_paths(&v, quiet, verbose, &skipped, words);
	filter_paths(&v, quiet, verbose, &warned);
	dedup_paths(&v, verbose);

	/* -q drops the per-entry warnings, and the documented invocation
	 * `export PATH="$(pathset -q)"` discards the exit status too: the shell
	 * reports export's status, not ours. Between them a rotted config could
	 * degrade PATH with no signal at all, so one summary line survives -q.
	 * It counts warnings as well as skips: a warned entry leaves the exit
	 * status at 0, which makes the summary its *only* trace. */
	if (quiet && (warned > 0 || skipped > 0)) {
		fprintf(stderr, "%s: ", PROG);
		if (warned > 0) {
			fprintf(stderr, "%d %s emitted with %s", warned,
				warned == 1 ? "entry" : "entries",
				warned == 1 ? "a warning" : "warnings");
			if (skipped > 0) fputs(", ", stderr);
		}
		if (skipped > 0) {
			fprintf(stderr, "%d %s skipped", skipped,
				skipped == 1 ? "entry" : "entries");
		}
		fputs(" (omit -q to see which)\n", stderr);
	}

	/* An empty result turns `export PATH="$(pathset)"` into an unusable shell.
	 * No config means to say that, so it is fatal unless asked for outright.
	 * When skips explain the emptiness, exit 3 rather than 1: exiting 1 buries
	 * the specific signal under the generic one, and the caller can no longer
	 * tell a config that has rotted from one that was always empty. */
	if (v.n == 0 && !allow_empty) {
		if (skipped > 0) {
			die(3, "refusing to print an empty result: %d %s skipped "
				"(use --allow-empty to override)", skipped,
				skipped == 1 ? "entry was" : "entries were");
		}
		die(1, "refusing to print an empty result (use --allow-empty to override)");
	}

	if (!check) print_path(&v, words);
	flush_stdout_or_die();

	for (size_t i = 0; i < v.n; i++) free(v.items[i].path);
	free(v.items);
	free(cfg);
	return skipped > 0 ? 3 : 0;
}
