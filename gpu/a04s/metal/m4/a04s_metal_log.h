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

extern const char *getprogname(void);

static inline void
a04s_log(const char *fmt, ...)
{
	char line[2048];
	int n = snprintf(line, sizeof(line), "[%s %d] ", getprogname(), getpid());
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
	int fd = open(path ? path : "/private/var/a04s/metal-probe.log",
		      O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		(void)!write(fd, line, (size_t)n);
		fsync(fd);
		close(fd);
	}
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
