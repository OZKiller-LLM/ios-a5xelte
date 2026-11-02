/*
 * Host test of the A04s eMMC write guard, compiled from the kernel's own header in CI.
 * A failure stops the build, so no kernel comes out of a guard that lets a bad write through.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "a04s_emmc_guard.h"

/* name, first sector, sectors: this phone's whole partition table. */
static const struct {
	const char *name;
	uint64_t first, sectors;
} partitions[] = {
	{ "efs", 8192, 40960 }, { "sec_efs", 49152, 40960 }, { "reserved", 90112, 8192 },
	{ "cpefs", 98304, 16384 }, { "steady", 114688, 8192 }, { "param", 122880, 16384 },
	{ "bota", 139264, 73728 }, { "ldfw", 212992, 16384 }, { "tzsw", 229376, 3072 },
	{ "tzar", 232448, 13312 }, { "keystorage", 245760, 1024 }, { "nad_refer", 246784, 2048 },
	{ "up_param", 248832, 16384 }, { "misc", 265216, 4096 }, { "uh", 269312, 4096 },
	{ "uhcfg", 273408, 8192 }, { "blcmd", 281600, 1024 }, { "boot", 282624, 90112 },
	{ "recovery", 372736, 108544 }, { "dtb", 481280, 16384 }, { "dtbo", 497664, 16384 },
	{ "radio", 514048, 102400 }, { "persistent", 616448, 1024 }, { "vbmeta", 617472, 1024 },
	{ "vbmeta_system", 618496, 1024 }, { "keyrefuge", 619520, 32768 }, { "keydata", 652288, 32768 },
	{ "metadata", 685056, 65536 }, { "fmp_selftest", 750592, 8 }, { "reserved2", 750600, 3064 },
	{ "super", 753664, 13369344 }, { "prism", 14123008, 1802240 }, { "optics", 15925248, 49152 },
	{ "cache", 15974400, 409600 }, { "omr", 16384000, 102400 }, { "cp_debug", 16486400, 10240 },
	{ "spu", 16496640, 102400 },
};

static int failures;

static void
expect(bool got, bool want, const char *what, uint64_t lba, uint64_t sectors)
{
	if (got != want) {
		printf("FAIL %s: lba %llu, %llu sectors: %d\n", what,
		    (unsigned long long)lba, (unsigned long long)sectors, got);
		failures++;
	}
}

int
main(void)
{
	const uint64_t first = A04S_USERDATA_FIRST, end = first + A04S_USERDATA_SECTORS;

	expect(first == 16599040 && end == 244271104, true, "userdata range", first, end);
	expect(a04s_guard_self_test(), true, "self test", 0, 0);

	for (size_t i = 0; i < sizeof(partitions) / sizeof(partitions[0]); i++) {
		uint64_t start = partitions[i].first, count = partitions[i].sectors;
		expect(a04s_write_allowed(start, 1), false, partitions[i].name, start, 1);
		expect(a04s_write_allowed(start + count - 1, 1), false, partitions[i].name, start + count - 1, 1);
		expect(a04s_write_allowed(start, count), false, partitions[i].name, start, count);
	}

	/* Outside the table: the partition tables themselves, and the end of the card. */
	expect(a04s_write_allowed(0, 1), false, "protective MBR", 0, 1);
	expect(a04s_write_allowed(1, 1), false, "partition table", 1, 1);
	expect(a04s_write_allowed(end, 1), false, "past userdata", end, 1);
	expect(a04s_write_allowed(244285439, 1), false, "backup partition table", 244285439, 1);

	/* Edges, requests that straddle them, an empty request, and arithmetic overflow. */
	expect(a04s_write_allowed(first - 1, 1), false, "just below", first - 1, 1);
	expect(a04s_write_allowed(first - 1, 2), false, "straddles the start", first - 1, 2);
	expect(a04s_write_allowed(first, 1), true, "first sector", first, 1);
	expect(a04s_write_allowed(end - 1, 1), true, "last sector", end - 1, 1);
	expect(a04s_write_allowed(end - 1, 2), false, "straddles the end", end - 1, 2);
	expect(a04s_write_allowed(first, A04S_USERDATA_SECTORS), true, "all of userdata", first, A04S_USERDATA_SECTORS);
	expect(a04s_write_allowed(first, 0), false, "empty", first, 0);
	expect(a04s_write_allowed(first, UINT64_MAX), false, "huge count", first, UINT64_MAX);
	expect(a04s_write_allowed(UINT64_MAX, 2), false, "wraps around", UINT64_MAX, 2);

	printf("%s\n", failures ? "GUARD TEST FAILED" : "guard test passed");
	return failures ? 1 : 0;
}
