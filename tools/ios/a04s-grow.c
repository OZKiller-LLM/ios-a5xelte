/*
 * a04s-grow: grow the Galaxy A04s's iOS root volume to fill its partition, once, as root.
 *
 * The root volume was written into the A04s's userdata partition from a 20 GiB image, so the
 * HFSX volume ends at 20 GiB while the partition (and the block device the kernel exposes for
 * it) is 227,672,064 sectors (116.57 GB). This asks the kernel's own HFS (Apple's hfs-627.100.6,
 * built in) to extend the mounted volume with HFSIOC_RESIZE_VOLUME, the call `diskutil
 * resizeVolume` uses: hfs_extendfs() grows the allocation bitmap, marks the new space free,
 * moves the alternate volume header to the new end and, at this size, the journal from 8 to
 * 16 MiB, all inside journal transactions. The eMMC driver only accepts writes inside userdata,
 * so nothing outside the partition can be touched whatever happens.
 *
 * It refuses unless "/" is HFS with 4096-byte blocks and smaller than the partition. Once the
 * volume is full size it does nothing, so it is safe at every boot.
 *
 * Lines go to the screen console (/dev/console). The exit status is 0 if the volume is full
 * size afterwards, else 1; the kernel shows it as "xstat 0x0" or "xstat 0x100". The kernel's own
 * lines are "hfs_extendfs: will extend ..." and "hfs_extendfs: extended ... to N blocks".
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/fsctl.h>
#include <sys/ioccom.h>
#include <sys/mount.h>
#include <unistd.h>

#define HFSIOC_RESIZE_VOLUME    _IOW('h', 2, u_int64_t)        /* hfs/core/hfs_fsctl.h */
#define USERDATA_SECTORS        227672064ull                    /* bsd/dev/a04s_emmc_guard.h */
#define TARGET_BYTES            (USERDATA_SECTORS * 512ull)     /* 116,568,096,768: 28,459,008 blocks */
#define BLOCK                   4096u

static void
say(const char *fmt, ...)
{
	char line[256];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	if ((size_t)n >= sizeof(line) - 1) {
		n = (int)sizeof(line) - 2;
	}
	line[n] = '\n';
	line[n + 1] = '\0';
	fputs(line, stdout);
	fflush(stdout);
	int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (fd >= 0) {
		(void)write(fd, line, (size_t)n + 1);
		close(fd);
	}
}

static int
root_fs(struct statfs *st)
{
	if (statfs("/", st) != 0) {
		say("A04S GROW FAIL: statfs: %s", strerror(errno));
		return -1;
	}
	return 0;
}

int
main(void)
{
	sleep(45);              /* after the boot's own disk work */
	struct statfs st;
	if (root_fs(&st) != 0) {
		return 1;
	}
	uint64_t before = (uint64_t)st.f_blocks * st.f_bsize;
	say("A04S GROW: / is %s on %s, %u-byte blocks, %llu blocks (%llu bytes), %llu free",
	    st.f_fstypename, st.f_mntfromname, (unsigned)st.f_bsize, (unsigned long long)st.f_blocks,
	    (unsigned long long)before, (unsigned long long)st.f_bfree);
	if (strcmp(st.f_fstypename, "hfs") != 0 || strcmp(st.f_mntonname, "/") != 0 || st.f_bsize != BLOCK) {
		say("A04S GROW FAIL: not the HFS root with %u-byte blocks; nothing done", BLOCK);
		return 1;
	}
	if (before >= TARGET_BYTES) {
		say("A04S GROW DONE: already %llu bytes (the partition is %llu); nothing to do",
		    (unsigned long long)before, (unsigned long long)TARGET_BYTES);
		return 0;
	}
	uint64_t size = TARGET_BYTES;
	say("A04S GROW: extending to %llu bytes (%llu blocks)", (unsigned long long)size,
	    (unsigned long long)(size / BLOCK));
	int r = fsctl("/", HFSIOC_RESIZE_VOLUME, &size, 0);
	int e = errno;
	sync();
	if (root_fs(&st) != 0) {
		return 1;
	}
	uint64_t after = (uint64_t)st.f_blocks * st.f_bsize;
	if (r != 0) {
		say("A04S GROW FAIL: fsctl %d (%s); now %llu blocks, %llu free", e, strerror(e),
		    (unsigned long long)st.f_blocks, (unsigned long long)st.f_bfree);
	}
	say("A04S GROW %s: %llu -> %llu bytes, %llu blocks, %llu free (%llu MiB)",
	    after >= TARGET_BYTES ? "DONE" : "FAIL", (unsigned long long)before, (unsigned long long)after,
	    (unsigned long long)st.f_blocks, (unsigned long long)st.f_bfree,
	    (unsigned long long)((uint64_t)st.f_bfree * st.f_bsize >> 20));
	return after >= TARGET_BYTES ? 0 : 1;
}
