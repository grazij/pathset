#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
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

/* The kind selects which filename is read under `pathset/`. Output format is
 * identical for every kind; the caller composes it into PATH, MANPATH,
 * INFOPATH, or fpath. */
static const char *KINDS[] = {"path", "man", "info", "fpath"};
static const size_t NUM_KINDS = sizeof(KINDS) / sizeof(KINDS[0]);
#define DEFAULT_KIND "path"

static int is_valid_kind(const char *k) {
	for (size_t i = 0; i < NUM_KINDS; i++) {
		if (strcmp(KINDS[i], k) == 0) return 1;
	}
	return 0;
}

static void die(int code, const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "%s: ", PROG);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(code);
}

static void usage(FILE *out) {
	fprintf(out,
		"Usage: %s [-c CONFIG] [-k KIND] [-d] [-q] [-v] [--check] [--allow-empty]\n"
		"   or: %s [-V|--version] [-h|--help]\n"
		"\n"
		"Reads a list of directories from a config file and prints a ':'-joined\n"
		"string to stdout. Compose into any variable with $(...):\n"
		"  export PATH=\"$(%s -q -d)\"\n"
		"  export MANPATH=\"$(%s -k man -q -d)\"\n"
		"  export INFOPATH=\"$(%s -k info -q -d)\"\n"
		"  fpath=( ${(s.:.)$(%s -k fpath -q -d)} )   # zsh array\n"
		"\n"
		"Options:\n"
		"  -c CONFIG      read config from CONFIG (overrides default lookup)\n"
		"  -k KIND        select kind: path (default), man, info, fpath\n"
		"  -d             drop duplicate entries (first occurrence wins; a\n"
		"                 trailing slash does not make an entry distinct)\n"
		"  -q             suppress the per-entry warnings. A one-line summary\n"
		"                 is still printed: $(...) discards the exit status, so\n"
		"                 it would otherwise be the only signal, and silent.\n"
		"  -v             print kept entries and expansions on stderr (-q wins)\n"
		"  --check        validate only: print nothing on stdout, exit as below\n"
		"  --allow-empty  print an empty result instead of failing on one\n"
		"  -V, --version  print version and exit\n"
		"  -h, --help     show this help and exit\n"
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
		"Config lookup (first match wins; <kind> = path|man|info|fpath):\n"
		"  1. -c CONFIG (no fallback if missing: fatal error)\n"
		"  2. $XDG_CONFIG_HOME/pathset/<kind> (only if XDG_CONFIG_HOME is set)\n"
		"  3. $HOME/.config/pathset/<kind>    (XDG default, canonical)\n"
		"  4. $HOME/.pathset/<kind>           (legacy home location)\n"
		"\n"
		"Shell setup (add to your shell rc):\n"
		"  zsh / bash:  export PATH=\"$(%s -q -d)\"\n"
		"  fish:        set -gx PATH (%s -q -d | string split :)\n"
		"\n"
		"Exit codes:\n"
		"  0  nothing was skipped (an entry emitted with a warning is not\n"
		"     a skip)\n"
		"  1  fatal error (missing config, I/O error, empty result, out of\n"
		"     memory)\n"
		"  2  bad command-line argument\n"
		"  3  one or more entries were skipped: an expansion failure, or a\n"
		"     ':' that cannot be represented. '?conditional' drops and\n"
		"     dedup drops do NOT contribute\n",
		PROG, PROG, PROG, PROG, PROG, PROG, PROG, PROG);
}

static char *xstrdup(const char *s) {
	size_t n = strlen(s) + 1;
	char *p = malloc(n);
	if (!p) die(1, "out of memory");
	memcpy(p, s, n);
	return p;
}

/* Builds "<prefix>/<segment>/<kind>". */
static char *join3(const char *prefix, const char *segment, const char *kind) {
	size_t lp = strlen(prefix), ls = strlen(segment), lk = strlen(kind);
	/* +2 for two '/' separators, +1 for terminator */
	char *p = malloc(lp + 1 + ls + 1 + lk + 1);
	if (!p) die(1, "out of memory");
	memcpy(p, prefix, lp);
	p[lp] = '/';
	memcpy(p + lp + 1, segment, ls);
	p[lp + 1 + ls] = '/';
	memcpy(p + lp + 1 + ls + 1, kind, lk + 1);
	return p;
}

/*
 * Lookup order is documented in usage(). The non-obvious part: when neither
 * home location exists, the canonical XDG path is returned anyway, so the
 * "cannot open" error names the location the README tells users to create.
 */
static char *resolve_config_path(const char *override, const char *kind) {
	if (override) return xstrdup(override);

	const char *xdg = getenv("XDG_CONFIG_HOME");
	if (xdg && *xdg) return join3(xdg, "pathset", kind);

	const char *home = getenv("HOME");
	if (home && *home) {
		char *xdg_default = join3(home, ".config/pathset", kind);
		if (access(xdg_default, F_OK) == 0) return xdg_default;
		char *legacy_dir = join3(home, ".pathset", kind);
		if (access(legacy_dir, F_OK) == 0) {
			free(xdg_default);
			return legacy_dir;
		}
		free(legacy_dir);
		return xdg_default;
	}

	die(1, "no -c given and neither XDG_CONFIG_HOME nor HOME is set");
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

static void print_path(const Vec *v) {
	for (size_t i = 0; i < v->n; i++) {
		if (i) fputc(':', stdout);
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

static void expand_paths(Vec *v, int quiet, int verbose, int *skipped) {
	size_t kept = 0;
	for (size_t i = 0; i < v->n; i++) {
		Entry e = v->items[i];
		const char *err = NULL;
		char *exp = expand_entry(e.path, &err);
		/* The output format has no escape for ':', so an entry containing one
		 * would silently split into two elements and invent a directory that
		 * was never declared. Unrepresentable, so drop it like any other
		 * failed entry. Checked after expansion: a ':' can arrive from $VAR. */
		if (exp && strchr(exp, ':')) {
			free(exp);
			exp = NULL;
			err = "contains ':', which cannot be represented in a ':'-joined list";
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
 * getopt(3) understands short options only, and getopt_long is a GNU/BSD
 * extension, absent from the C standard. Only a handful of long forms are
 * worth accepting, so translate them into flags here and hand getopt an argv
 * with them removed. A bare "--" ends option scanning; everything after it is
 * passed through untouched.
 *
 * Returns a malloc'd pointer array the caller frees. The strings in it are
 * borrowed from the original argv and must not be freed.
 */
typedef struct {
	int help;
	int version;
	int check;
	int allow_empty;
} LongOpts;

static char **filter_long_opts(int argc, char **argv, int *out_argc, LongOpts *lo) {
	char **out = malloc((size_t)(argc + 1) * sizeof(*out));
	if (!out) die(1, "out of memory");
	int n = 0;
	int passthrough = 0;
	out[n++] = argv[0];
	for (int i = 1; i < argc; i++) {
		char *a = argv[i];
		if (passthrough || a[0] != '-' || a[1] != '-') {
			out[n++] = a;
			continue;
		}
		if (strcmp(a, "--") == 0) {
			passthrough = 1;
			out[n++] = a;
		} else if (strcmp(a, "--help") == 0) {
			lo->help = 1;
		} else if (strcmp(a, "--version") == 0) {
			lo->version = 1;
		} else if (strcmp(a, "--check") == 0) {
			lo->check = 1;
		} else if (strcmp(a, "--allow-empty") == 0) {
			lo->allow_empty = 1;
		} else {
			usage(stderr);
			die(2, "unknown argument: %s", a);
		}
	}
	out[n] = NULL;
	*out_argc = n;
	return out;
}

int main(int argc, char **argv) {
	const char *cfg_override = NULL;
	const char *kind = DEFAULT_KIND;
	int quiet = 0;
	int dedup = 0;
	int verbose = 0;

	LongOpts lo = {0};
	int fargc;
	char **fargv = filter_long_opts(argc, argv, &fargc, &lo);
	if (lo.help) { usage(stdout); free(fargv); return 0; }
	if (lo.version) { printf("%s %s\n", PROG, PATHSET_VERSION); free(fargv); return 0; }

	/* Suppress getopt's auto-error so we control the exit code (must be 2)
	 * and the message format. */
	opterr = 0;
	int opt;
	while ((opt = getopt(fargc, fargv, ":c:k:dqvVh")) != -1) {
		switch (opt) {
		case 'c': cfg_override = optarg; break;
		case 'k':
			if (!is_valid_kind(optarg)) {
				usage(stderr);
				die(2, "invalid kind '%s' (expected: path, man, info, fpath)", optarg);
			}
			kind = optarg;
			break;
		case 'd': dedup = 1; break;
		case 'q': quiet = 1; break;
		case 'v': verbose = 1; break;
		case 'V': printf("%s %s\n", PROG, PATHSET_VERSION); return 0;
		case 'h': usage(stdout); return 0;
		case ':':
			usage(stderr);
			die(2, "-%c requires an argument", optopt);
		case '?':
		default:
			usage(stderr);
			die(2, "unknown argument: -%c", optopt);
		}
	}
	if (optind < fargc) {
		usage(stderr);
		die(2, "unexpected argument: %s", fargv[optind]);
	}
	free(fargv);

	if (quiet) verbose = 0;

	char *cfg = resolve_config_path(cfg_override, kind);
	Vec v = {0};
	int skipped = 0;
	int warned = 0;
	read_paths(cfg, &v);
	expand_paths(&v, quiet, verbose, &skipped);
	filter_paths(&v, quiet, verbose, &warned);
	if (dedup) dedup_paths(&v, verbose);

	/* -q drops the per-entry warnings, and the documented invocation
	 * `export PATH="$(pathset -q -d)"` discards the exit status too: the shell
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
	 * No config means to say that, so it is fatal unless asked for outright. */
	if (v.n == 0 && !lo.allow_empty) {
		die(1, "refusing to print an empty result (use --allow-empty to override)");
	}

	if (!lo.check) print_path(&v);

	for (size_t i = 0; i < v.n; i++) free(v.items[i].path);
	free(v.items);
	free(cfg);
	return skipped > 0 ? 3 : 0;
}
