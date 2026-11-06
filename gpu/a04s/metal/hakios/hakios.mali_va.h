/*
 * The GPU addresses the Galaxy S9's Mali gives programs' buffers (drivers/gpu/hakios.mali.c, hakios_mali_address() and
 * hakios_mali_unmap()): plain C with no kernel in it, so that tools/mali_va_test.c checks it on a build machine.
 *
 * The range is Linux panfrost's, 32 MB up to 4 GB, which is what Mesa's panfrost assumes and leans on (Mesa 25.0.7,
 * src/panfrost/lib/kmod/panfrost_kmod.c: "Lower 32MB are reserved, and the address space is limited to 32-bit"). On
 * Bifrost a blend shader's address is given in 32 bits, its upper half taken to be the fragment shader's
 * (src/gallium/drivers/panfrost/pan_cmdstream.c, `cfg.shader.pc = (uint32_t)blend_shaders[i]`), and workgroup storage
 * must not cross a 4 GB line (src/panfrost/lib/pan_desc.c): two buffers either side of 4 GB would send a blend shader
 * to the wrong place, with nothing said. The original driver (the Infinix Hot 20's) handed out 32 GB, never an address
 * twice, which Mesa got away with only for as long as the first 4 GB lasted.
 *
 * And a buffer the GPU runs code from must not cross a 16 MB line, the program counter being 24 bits there: Linux
 * panfrost keeps executable buffers inside one (panfrost_gem.c, aligned to their size), and Mesa counts on it
 * (src/panfrost/midgard/midgard_compile.c: "the kernel makes sure shader BOs can't cross 16MB boundaries").
 *
 * So addresses are given out and taken back. The range is cut into 64 KB granules; a buffer takes the granules its size
 * covers plus one left empty after it (an overrun faults rather than writing into the next buffer), found by a walk that
 * carries on from where the last one ended and starts again from the bottom when it reaches 4 GB, so an address freed
 * is not given out again at once: a job still using a buffer just freed faults where it can be said, not in another
 * buffer's memory. The caller gives an address back only once nothing of the buffer is left in the GPU's tables or its
 * MMU (hakios_mali_unmap()). Sources: Linux panfrost (panfrost_gem.c, panfrost_mmu.c) and Mesa 25.0.7, read for these
 * facts; nothing of their code.
 */
#ifndef HAKIOS_MALI_VA_H
#define HAKIOS_MALI_VA_H

#include <stdbool.h>
#include <stdint.h>

#define MALI_VA_FIRST           0x02000000ull                           /* 32 MB, as Linux panfrost */
#define MALI_VA_END             0x100000000ull                          /* 4 GB */
#define MALI_VA_GRANULE         0x10000ull                              /* 64 KB */
#define MALI_VA_GRANULES        (MALI_VA_END / MALI_VA_GRANULE)         /* 65536, the first 512 never given */
#define MALI_VA_EXEC_LINE       0x1000000ull                            /* 16 MB: code does not cross one */

struct mali_va {
	uint64_t used[MALI_VA_GRANULES / 64];   /* a bit a granule */
	uint64_t next;                          /* the granule the next walk starts from (0: the bottom) */
	uint64_t taken;                         /* granules in use, the empty ones after buffers included */
};

static inline bool
mali_va_used(const struct mali_va *va, uint64_t g)
{
	return (va->used[g / 64] >> (g % 64)) & 1;
}

static inline void
mali_va_mark(struct mali_va *va, uint64_t first, uint64_t count, bool used)
{
	for (uint64_t g = first; g < first + count; g++) {
		if (used) {
			va->used[g / 64] |= 1ull << (g % 64);
		} else {
			va->used[g / 64] &= ~(1ull << (g % 64));
		}
	}
	va->taken = used ? va->taken + count : va->taken - count;
}

/* The granules a buffer of `size` bytes takes, the empty one after it included. */
static inline uint64_t
mali_va_granules(uint64_t size)
{
	return (size + MALI_VA_GRANULE - 1) / MALI_VA_GRANULE + 1;
}

/*
 * The first of `count` free granules in a row from granule `from` on, below 4 GB, whose first `size` bytes do not cross
 * a 16 MB line when `executable` (and `size` is not more than 16 MB). 0: none.
 */
static inline uint64_t
mali_va_find(const struct mali_va *va, uint64_t from, uint64_t count, uint64_t size, bool executable)
{
	uint64_t g = from;

	while (g + count <= MALI_VA_GRANULES) {
		uint64_t start = g * MALI_VA_GRANULE, run = 0;

		if (executable && size <= MALI_VA_EXEC_LINE && start / MALI_VA_EXEC_LINE != (start + size - 1) / MALI_VA_EXEC_LINE) {
			g = (start / MALI_VA_EXEC_LINE + 1) * (MALI_VA_EXEC_LINE / MALI_VA_GRANULE);    /* from the next line */
			continue;
		}
		while (run < count && !mali_va_used(va, g + run)) {
			run++;
		}
		if (run == count) {
			return g;
		}
		g += run + 1;                   /* past the one in use */
	}
	return 0;
}

/* `size` bytes of GPU addresses; `executable`: the GPU may run code from them. 0: none left (or a size of nothing). */
static inline uint64_t
mali_va_alloc(struct mali_va *va, uint64_t size, bool executable)
{
	uint64_t count = mali_va_granules(size), first = MALI_VA_FIRST / MALI_VA_GRANULE, g = 0;

	if (size == 0 || size > MALI_VA_END - MALI_VA_FIRST) {
		return 0;
	}
	if (va->next > first) {
		g = mali_va_find(va, va->next, count, size, executable);
	}
	if (g == 0) {
		g = mali_va_find(va, first, count, size, executable);
	}
	if (g == 0) {
		return 0;
	}
	mali_va_mark(va, g, count, true);
	va->next = g + count < MALI_VA_GRANULES ? g + count : first;
	return g * MALI_VA_GRANULE;
}

/* The addresses of a buffer given back: `address` and `size` as mali_va_alloc() gave and was asked. false: not one of its. */
static inline bool
mali_va_free(struct mali_va *va, uint64_t address, uint64_t size)
{
	uint64_t g = address / MALI_VA_GRANULE, count = mali_va_granules(size);

	if (address < MALI_VA_FIRST || address % MALI_VA_GRANULE != 0 || size == 0 || g + count > MALI_VA_GRANULES) {
		return false;
	}
	for (uint64_t k = g; k < g + count; k++) {
		if (!mali_va_used(va, k)) {
			return false;           /* not given out (or given back already): nothing is changed */
		}
	}
	mali_va_mark(va, g, count, false);
	return true;
}

#endif /* HAKIOS_MALI_VA_H */
