/*
 * a04s-drop: the Galaxy A04s's drop zone, run once per boot as root (in place of a daemon).
 *
 * hfs_replace.py can only rewrite an existing file's blocks from TWRP, so this keeps one fixed
 * file for it to rewrite: /private/var/a04s/drop.bin, 128 MiB, made of zeros on the first boot.
 * From then on tools/a04s_drop.py (on the PC) writes a package into it from TWRP, and on the
 * next boot this unpacks it under /private/var/a04s/ and runs its autorun. It is the A04s's
 * counterpart of the S7's kernel drop zone (bsd/dev/herolte_drop.c), which lived beyond the
 * HFS volume; the A04s's volume fills userdata.
 *
 * Package (little-endian), the S7's layout plus a checksum:
 *   block 0: "A04SDRP1", u32 version 1, u32 entries, u64 payload bytes, u64 ident,
 *            32-byte SHA-256 of the payload, u32 flags (bit 0: run the autorun at every boot)
 *   payload from byte 4096: per entry u32 path length, u32 mode (0 = directory, 0644 or 0755),
 *            u64 size, the absolute path, zero padding to 8, the data, zero padding to 8.
 *
 * Every path must lie under /private/var/a04s/ (no "..", ".", empty parts or the drop zone's
 * own files), and the whole package is checked before anything is written. Files go through a
 * ".part" file, fsync and rename. A package is applied once (its ident is kept in drop.applied).
 * Then /private/var/a04s/autorun, if the package had one, runs with its output in autorun.log.
 * Lines go to /private/var/a04s/drop.log (readable from TWRP with hfs_read.py) and /dev/console.
 *
 * v2: the autorun's environment gets the KEY=VALUE lines of /private/var/a04s/autorun.env
 * (a package can carry it). At every boot, the kernel's message buffer (IOLog and printf, as
 * dmesg reads it; boot-arg msgbuf= sets its size, up to 1 MiB) is saved as dmesg-1.log ...
 * dmesg-5.log at about 1, 2, 4, 8 and 15 minutes after the autorun, so the kernel's own lines can
 * be read from TWRP too.
 */
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define DIR_PATH        "/private/var/a04s"
#define PREFIX          DIR_PATH "/"
#define DROP_PATH       PREFIX "drop.bin"
#define APPLIED_PATH    PREFIX "drop.applied"
#define LOG_PATH        PREFIX "drop.log"
#define AUTORUN_PATH    PREFIX "autorun"
#define AUTORUN_LOG     PREFIX "autorun.log"
#define DROP_BYTES      (128ull << 20)
#define HEADER_BYTES    4096u
#define MAX_ENTRIES     4096u
#define MAX_PATH_LEN    1023u
#define CHUNK           (1u << 20)
#define FLAG_EVERY_BOOT 1u
#define AUTORUN_ENV     PREFIX "autorun.env"
#define MAX_ENV_LINES   64u
#define MSGBUF_MAX      (1u << 20)      /* bsd/sys/msgbuf.h MAX_MSG_BSIZE */

extern char **environ;

static int log_fd = -1;

static void
say(const char *fmt, ...)
{
	char line[512];
	time_t t = time(NULL);
	struct tm tm;
	localtime_r(&t, &tm);
	int n = (int)strftime(line, sizeof(line), "%Y-%m-%d %H:%M:%S A04S DROP: ", &tm);
	va_list ap;
	va_start(ap, fmt);
	int m = vsnprintf(line + n, sizeof(line) - (size_t)n - 1, fmt, ap);
	va_end(ap);
	if (m < 0) {
		return;
	}
	n += m;
	if (n > (int)sizeof(line) - 2) {
		n = (int)sizeof(line) - 2;
	}
	line[n++] = '\n';
	line[n] = '\0';
	if (log_fd >= 0) {
		(void)write(log_fd, line, (size_t)n);
		(void)fsync(log_fd);
	}
	int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (fd >= 0) {
		(void)write(fd, line, (size_t)n);
		close(fd);
	}
}

static int
full_pread(int fd, void *buf, size_t len, off_t off)
{
	uint8_t *p = buf;
	while (len > 0) {
		ssize_t r = pread(fd, p, len, off);
		if (r <= 0) {
			return -1;
		}
		p += r;
		len -= (size_t)r;
		off += r;
	}
	return 0;
}

static int
full_write(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;
	while (len > 0) {
		ssize_t r = write(fd, p, len);
		if (r <= 0) {
			return -1;
		}
		p += r;
		len -= (size_t)r;
	}
	return 0;
}

static uint32_t
le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t
le64(const uint8_t *p)
{
	return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}

/* The drop file, made of zeros, if it isn't there yet: 0 if it is there now. */
static int
ensure_drop(void)
{
	struct stat st;
	if (stat(DROP_PATH, &st) == 0) {
		if (S_ISREG(st.st_mode) && (uint64_t)st.st_size == DROP_BYTES) {
			return 0;
		}
		say("FAIL: %s is not a %llu-byte file; leaving it alone", DROP_PATH, (unsigned long long)DROP_BYTES);
		return -1;
	}
	const char *part = DROP_PATH ".part";
	int fd = open(part, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) {
		say("FAIL: create %s: %s", part, strerror(errno));
		return -1;
	}
	uint8_t *zero = calloc(1, CHUNK);
	int ok = zero != NULL;
	for (uint64_t done = 0; ok && done < DROP_BYTES; done += CHUNK) {
		ok = full_write(fd, zero, CHUNK) == 0;
	}
	free(zero);
	ok = ok && fcntl(fd, F_FULLFSYNC) == 0;
	close(fd);
	if (!ok || rename(part, DROP_PATH) != 0) {
		say("FAIL: writing %s: %s", DROP_PATH, strerror(errno));
		unlink(part);
		return -1;
	}
	int dfd = open(DIR_PATH, O_RDONLY);
	if (dfd >= 0) {
		(void)fcntl(dfd, F_FULLFSYNC);
		close(dfd);
	}
	say("created %s (%llu bytes of zeros); write a package into it from TWRP", DROP_PATH,
	    (unsigned long long)DROP_BYTES);
	return 1;
}

/* A path the package may write: under PREFIX, no empty, "." or ".." parts, not ours. */
static int
path_ok(const char *p, size_t len)
{
	size_t pl = strlen(PREFIX);
	if (len <= pl || len > MAX_PATH_LEN || strlen(p) != len || strncmp(p, PREFIX, pl) != 0) {
		return 0;
	}
	const char *s = p + pl;
	for (;;) {
		const char *e = strchr(s, '/');
		size_t n = e ? (size_t)(e - s) : strlen(s);
		if (n == 0 || (n == 1 && s[0] == '.') || (n == 2 && s[0] == '.' && s[1] == '.')) {
			return 0;
		}
		if (!e) {
			break;
		}
		s = e + 1;
	}
	static const char *const ours[] = { DROP_PATH, DROP_PATH ".part", APPLIED_PATH, LOG_PATH, AUTORUN_LOG,
		PREFIX "dmesg-1.log", PREFIX "dmesg-2.log", PREFIX "dmesg-3.log", PREFIX "dmesg-4.log", PREFIX "dmesg-5.log" };
	for (size_t i = 0; i < sizeof(ours) / sizeof(ours[0]); i++) {
		size_t on = strlen(ours[i]);
		if (strcmp(p, ours[i]) == 0 || (len > on && strncmp(p, ours[i], on) == 0 && p[on] == '/')) {
			return 0;
		}
	}
	return 1;
}

static uint64_t
pad8(uint64_t n)
{
	return (n + 7u) & ~7ull;
}

/* Walk the payload: check every entry (apply = 0), or write them (apply = 1). */
static int
walk(int fd, uint64_t payload, uint32_t entries, int apply)
{
	uint64_t off = 0;
	char path[MAX_PATH_LEN + 1];
	uint8_t *buf = apply ? malloc(CHUNK) : NULL;
	if (apply && buf == NULL) {
		return -1;
	}
	int rc = 0;
	for (uint32_t i = 0; i < entries && rc == 0; i++) {
		uint8_t h[16];
		if (off + 16 > payload || full_pread(fd, h, 16, (off_t)(HEADER_BYTES + off)) != 0) {
			say("FAIL: entry %u: header past the payload", i);
			rc = -1;
			break;
		}
		uint32_t plen = le32(h), mode = le32(h + 4);
		uint64_t size = le64(h + 8);
		off += 16;
		if (plen == 0 || plen > MAX_PATH_LEN || off + plen > payload) {
			say("FAIL: entry %u: bad path length %u", i, plen);
			rc = -1;
			break;
		}
		if (full_pread(fd, path, plen, (off_t)(HEADER_BYTES + off)) != 0) {
			rc = -1;
			break;
		}
		path[plen] = '\0';
		off = pad8(off + plen);
		if (!path_ok(path, plen) || (mode != 0 && mode != 0644 && mode != 0755) ||
		    (mode == 0 && size != 0) || size > payload || off + size > payload) {
			say("FAIL: entry %u (%s): refused (mode %o, %llu bytes)", i, path_ok(path, plen) ? path : "bad path",
			    mode, (unsigned long long)size);
			rc = -1;
			break;
		}
		if (apply) {
			if (mode == 0) {
				struct stat st;
				if (mkdir(path, 0755) != 0 && !(errno == EEXIST && stat(path, &st) == 0 && S_ISDIR(st.st_mode))) {
					say("FAIL: mkdir %s: %s", path, strerror(errno));
					rc = -1;
				}
			} else {
				char part[MAX_PATH_LEN + 8];
				snprintf(part, sizeof(part), "%s.part", path);
				int out = open(part, O_WRONLY | O_CREAT | O_TRUNC, 0600);
				if (out < 0) {
					say("FAIL: create %s: %s", part, strerror(errno));
					rc = -1;
				}
				for (uint64_t done = 0; rc == 0 && done < size;) {
					size_t n = size - done < CHUNK ? (size_t)(size - done) : CHUNK;
					if (full_pread(fd, buf, n, (off_t)(HEADER_BYTES + off + done)) != 0 ||
					    full_write(out, buf, n) != 0) {
						say("FAIL: writing %s: %s", path, strerror(errno));
						rc = -1;
					}
					done += n;
				}
				if (out >= 0) {
					if (rc == 0 && (fsync(out) != 0 || fchmod(out, (mode_t)mode) != 0)) {
						rc = -1;
					}
					close(out);
				}
				if (rc == 0 && rename(part, path) != 0) {
					say("FAIL: rename %s: %s", path, strerror(errno));
					rc = -1;
				}
				if (rc != 0) {
					unlink(part);
				} else {
					say("  %s %o, %llu bytes", path, mode, (unsigned long long)size);
				}
			}
		}
		off = pad8(off + size);
	}
	free(buf);
	return rc;
}

static uint64_t
applied_ident(void)
{
	FILE *f = fopen(APPLIED_PATH, "r");
	unsigned long long v = 0;
	if (f) {
		if (fscanf(f, "%llu", &v) != 1) {
			v = 0;
		}
		fclose(f);
	}
	return v;
}

static void
set_applied(uint64_t ident)
{
	const char *part = APPLIED_PATH ".part";
	FILE *f = fopen(part, "w");
	if (!f) {
		return;
	}
	fprintf(f, "%llu\n", (unsigned long long)ident);
	fflush(f);
	(void)fsync(fileno(f));
	fclose(f);
	(void)rename(part, APPLIED_PATH);
}

static void
run_autorun(uint64_t ident)
{
	struct stat st;
	if (stat(AUTORUN_PATH, &st) != 0 || !S_ISREG(st.st_mode)) {
		say("no autorun");
		return;
	}
	posix_spawn_file_actions_t fa;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_addopen(&fa, 1, AUTORUN_LOG, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	posix_spawn_file_actions_adddup2(&fa, 1, 2);
	char id[64];
	snprintf(id, sizeof(id), "A04S_DROP_IDENT=%llu", (unsigned long long)ident);
	size_t n = 0;
	while (environ && environ[n]) {
		n++;
	}
	char **env = calloc(n + 2 + MAX_ENV_LINES, sizeof(char *));
	if (env == NULL) {
		posix_spawn_file_actions_destroy(&fa);
		return;
	}
	for (size_t i = 0; i < n; i++) {
		env[i] = environ[i];
	}
	env[n++] = id;
	/* v2: KEY=VALUE lines from autorun.env; '#' starts a comment line. */
	char *extra[MAX_ENV_LINES];
	unsigned nextra = 0;
	FILE *ef = fopen(AUTORUN_ENV, "r");
	char line[256];
	while (ef && nextra < MAX_ENV_LINES && fgets(line, sizeof(line), ef)) {
		line[strcspn(line, "\r\n")] = '\0';
		char *eq = strchr(line, '=');
		if (line[0] == '#' || eq == NULL || eq == line) {
			continue;
		}
		extra[nextra] = strdup(line);
		if (extra[nextra] != NULL) {
			say("  autorun env %s", line);
			env[n++] = extra[nextra++];
		}
	}
	if (ef) {
		fclose(ef);
	}
	char *argv[] = { (char *)AUTORUN_PATH, NULL };
	pid_t pid;
	int e = posix_spawn(&pid, AUTORUN_PATH, &fa, NULL, argv, env);
	posix_spawn_file_actions_destroy(&fa);
	free(env);
	for (unsigned i = 0; i < nextra; i++) {
		free(extra[i]);
	}
	if (e != 0) {
		say("FAIL: autorun: %s", strerror(e));
		return;
	}
	say("autorun running, pid %d, output in %s", pid, AUTORUN_LOG);
	int status = 0;
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
	}
	if (WIFEXITED(status)) {
		say("autorun exited %d", WEXITSTATUS(status));
	} else if (WIFSIGNALED(status)) {
		say("autorun killed by signal %d", WTERMSIG(status));
	}
}

/* v2: the kernel's message buffer into dmesg-N.log, through a .part file and rename. */
static void
save_dmesg(unsigned index)
{
	/* libproc's proc_kmsgbuf, as dmesg uses: looked up at run time, as the SDK doesn't declare it. */
	int (*kmsgbuf)(void *, uint32_t) = (int (*)(void *, uint32_t))dlsym(RTLD_DEFAULT, "proc_kmsgbuf");
	char *buf = kmsgbuf != NULL ? malloc(MSGBUF_MAX) : NULL;
	if (buf == NULL) {
		say("kernel log: %s", kmsgbuf != NULL ? "no memory" : "no proc_kmsgbuf");
		return;
	}
	int got = kmsgbuf(buf, MSGBUF_MAX);
	char path[64], part[72];
	snprintf(path, sizeof(path), PREFIX "dmesg-%u.log", index);
	snprintf(part, sizeof(part), "%s.part", path);
	int fd = got > 0 ? open(part, O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
	int ok = fd >= 0 && full_write(fd, buf, (size_t)got) == 0 && fsync(fd) == 0;
	if (fd >= 0) {
		close(fd);
	}
	free(buf);
	if (ok && rename(part, path) == 0) {
		say("kernel log: %d bytes in %s", got, path);
	} else {
		unlink(part);
		say("kernel log: not saved (%d bytes read)", got);
	}
}

static int drop_main(void);

int
main(void)
{
	sleep(30);
	if (mkdir(DIR_PATH, 0755) != 0 && errno != EEXIST) {
		return 1;
	}
	log_fd = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
	say("start, pid %d", getpid());
	int rc = drop_main();
	static const unsigned at_minutes[] = { 1, 2, 4, 8, 15 };
	unsigned slept = 0;
	for (unsigned i = 0; i < sizeof(at_minutes) / sizeof(at_minutes[0]); i++) {
		sleep((at_minutes[i] - slept) * 60u);
		slept = at_minutes[i];
		save_dmesg(i + 1);
	}
	say("done");
	return rc;
}

static int
drop_main(void)
{
	int made = ensure_drop();
	if (made != 0) {
		return made < 0 ? 1 : 0;
	}
	int fd = open(DROP_PATH, O_RDONLY);
	uint8_t h[HEADER_BYTES];
	if (fd < 0 || full_pread(fd, h, sizeof(h), 0) != 0) {
		say("FAIL: reading %s", DROP_PATH);
		return 1;
	}
	if (memcmp(h, "A04SDRP1", 8) != 0) {
		say("no package in %s", DROP_PATH);
		close(fd);
		return 0;
	}
	uint32_t version = le32(h + 8), entries = le32(h + 12), flags = le32(h + 64);
	uint64_t payload = le64(h + 16), ident = le64(h + 24);
	if (version != 1 || entries > MAX_ENTRIES || payload > DROP_BYTES - HEADER_BYTES) {
		say("FAIL: package header: version %u, %u entries, %llu bytes", version, entries,
		    (unsigned long long)payload);
		close(fd);
		return 1;
	}
	uint64_t done = applied_ident();
	int applied_now = 0;
	if (ident == done) {
		say("package %llu already applied", (unsigned long long)ident);
	} else {
		CC_SHA256_CTX c;
		CC_SHA256_Init(&c);
		uint8_t *buf = malloc(CHUNK);
		int ok = buf != NULL;
		for (uint64_t at = 0; ok && at < payload;) {
			size_t n = payload - at < CHUNK ? (size_t)(payload - at) : CHUNK;
			ok = full_pread(fd, buf, n, (off_t)(HEADER_BYTES + at)) == 0;
			if (ok) {
				CC_SHA256_Update(&c, buf, (CC_LONG)n);
			}
			at += n;
		}
		free(buf);
		uint8_t sum[CC_SHA256_DIGEST_LENGTH];
		CC_SHA256_Final(sum, &c);
		if (!ok || memcmp(sum, h + 32, sizeof(sum)) != 0) {
			say("FAIL: package %llu: checksum mismatch; nothing written", (unsigned long long)ident);
			close(fd);
			return 1;
		}
		if (walk(fd, payload, entries, 0) != 0) {
			say("FAIL: package %llu refused; nothing written", (unsigned long long)ident);
			close(fd);
			return 1;
		}
		say("package %llu: %u entries, %llu bytes, checksum OK; applying", (unsigned long long)ident, entries,
		    (unsigned long long)payload);
		if (walk(fd, payload, entries, 1) != 0) {
			say("FAIL: package %llu stopped part way", (unsigned long long)ident);
			close(fd);
			return 1;
		}
		set_applied(ident);
		applied_now = 1;
		say("package %llu applied", (unsigned long long)ident);
	}
	close(fd);
	if (applied_now || (flags & FLAG_EVERY_BOOT)) {
		run_autorun(ident);
	}
	return 0;
}
