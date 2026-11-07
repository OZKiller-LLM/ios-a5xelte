/*
 * Galaxy A04s, Metal track M4: one logging helper for the bundle, the plug-in and the probe.
 * Every line goes to stderr (the drop agent's autorun.log for the probe) and is appended, with
 * the process name and pid, to /private/var/a04s/metal-probe.log (A04S_METAL_LOG overrides),
 * flushed to disk at once, so that a line written just before a crash is still there.
 */
#ifndef A04S_METAL_LOG_H
#define A04S_METAL_LOG_H

#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/vm_map.h>        /* vm_read_overwrite: the iPhoneOS SDK has no mach_vm.h */

#include <mach/mach_time.h>
#include <pthread.h>

extern const char *getprogname(void);

/* Seconds since this process's first log line, from mach_absolute_time. */
static inline double
a04s_now(void)
{
	static uint64_t t0;
	static mach_timebase_info_data_t tb;
	if (!tb.denom)
		mach_timebase_info(&tb);
	uint64_t t = mach_absolute_time();
	if (!t0)
		t0 = t;
	return (double)(t - t0) * tb.numer / tb.denom / 1e9;
}

/*
 * Each line carries its time since start and how long the PREVIOUS line's fsync took ("sync
 * N ms"): the first phone run (2026-11-07) stopped after nine lines in about 90 s, and the
 * question is whether the eMMC's flushes were that slow or the process really stopped. Every
 * line is still flushed to disk (a hard reset loses nothing written), unless
 * A04S_METAL_LOG_SYNC=0.
 */
static inline void
a04s_log(const char *fmt, ...)
{
	static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
	static double last_sync_ms = -1;
	pthread_mutex_lock(&lock);
	char line[2048];
	int n = snprintf(line, sizeof(line), "[%s %d +%.3fs", getprogname(), getpid(), a04s_now());
	if (last_sync_ms >= 0)
		n += snprintf(line + n, sizeof(line) - (size_t)n, " sync %.0fms", last_sync_ms);
	n += snprintf(line + n, sizeof(line) - (size_t)n, "] ");
	va_list ap;
	va_start(ap, fmt);
	n += vsnprintf(line + n, sizeof(line) - (size_t)n - 2, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof(line) - 2)
		n = (int)sizeof(line) - 2;
	line[n++] = '\n';
	line[n] = 0;
	(void)!write(2, line, (size_t)n);
	const char *path = getenv("A04S_METAL_LOG");
	const char *sync = getenv("A04S_METAL_LOG_SYNC");
	int fd = open(path ? path : "/private/var/a04s/metal-probe.log",
		      O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		(void)!write(fd, line, (size_t)n);
		if (!sync || strcmp(sync, "0")) {
			double t = a04s_now();
			fsync(fd);
			last_sync_ms = (a04s_now() - t) * 1000.0;
		}
		close(fd);
	}
	pthread_mutex_unlock(&lock);
}

/* Up to `len` bytes at `addr` as hex, read with vm_read_overwrite so that an argument that is
 * not a pointer at all costs a "not readable" line, not a crash. */
static inline void
a04s_log_bytes(const char *what, uintptr_t addr, size_t len)
{
	unsigned char buf[256];
	vm_size_t got = 0;
	if (len > sizeof(buf))
		len = sizeof(buf);
	if (addr < 0x100000000ull || addr > 0x7fffffffffull ||
	    vm_read_overwrite(mach_task_self(), (vm_address_t)addr, len, (vm_address_t)buf, &got) != KERN_SUCCESS) {
		a04s_log("  %s @%#lx: not readable", what, (unsigned long)addr);
		return;
	}
	char hex[3 * 64 + 1], asc[65];
	for (size_t off = 0; off < got; off += 64) {
		size_t k = got - off < 64 ? got - off : 64;
		for (size_t i = 0; i < k; i++) {
			snprintf(hex + 3 * i, 4, "%02x ", buf[off + i]);
			asc[i] = buf[off + i] >= 0x20 && buf[off + i] < 0x7f ? (char)buf[off + i] : '.';
		}
		hex[3 * k] = 0;
		asc[k] = 0;
		a04s_log("  %s @%#lx+%03zx: %s |%s|", what, (unsigned long)addr, off, hex, asc);
	}
}

#endif
