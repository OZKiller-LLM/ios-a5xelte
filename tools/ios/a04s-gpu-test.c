/*
 * a04s-gpu-test: the Galaxy A04s's Mali-G52 MP1 (Bifrost v7) from iOS user space, through the
 * kernel's HeroGPU service (iokit/Kernel/arm/HeroGPU.cpp over bsd/dev/a04s_gpu.c, 7c-5b). Its
 * lines go to the kernel log, and so to the screen console, through HeroGPU's Log call.
 *
 *   1. GetParam: GPU_ID must be 0x7212, plus the params Mesa's Panfrost reads first.
 *   2. A WRITE_VALUE job in a buffer of ours, on JS1.
 *   3. A FRAGMENT job on JS0 that clears a 64x64 RGBA8 target in another buffer of ours, with the
 *      same Bifrost (v7) descriptors as the kernel's 7c-4a clear; every pixel is checked.
 *   4. A WRITE_VALUE aimed at an AS1 address nothing is mapped at: it must fail (the MMU catches
 *      it), and then a good WRITE_VALUE must work again (AS1 recovered).
 *   5. A job chain outside the user range must be refused without running.
 *   6. One buffer is left for the kernel to free when we exit: the heartbeat's GPUUSER line must
 *      then show CLIENTS 0 and VA 0.
 *
 * Ends with one line: "A04S GPU TEST PASS ..." or "A04S GPU TEST FAIL ...".
 * The iOS SDK has no IOKitLib.h; the few calls used are declared here.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
CFMutableDictionaryRef IOServiceMatching(const char *name);
io_service_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
kern_return_t IOServiceOpen(io_service_t service, task_port_t owningTask, uint32_t type,
    io_connect_t *connect);
kern_return_t IOServiceClose(io_connect_t connect);
kern_return_t IOObjectRelease(io_object_t object);
kern_return_t IOConnectCallScalarMethod(io_connect_t connection, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt, uint64_t *output, uint32_t *outputCnt);
kern_return_t IOConnectCallStructMethod(io_connect_t connection, uint32_t selector,
    const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt);

enum { GET_PARAM = 0, CREATE_BO = 1, FREE_BO = 2, MAP_BO = 3, SUBMIT = 4, LOG = 5 };

#define USER_VA_BASE    0x40000000ull
#define USER_VA_END     0x80000000ull
#define UNMAPPED_VA     0x7ff00000ull   /* the top of AS1's range: nothing is allocated there */
#define COLOR           0xff40c020u     /* the kernel's FRAG_COLOR */
#define FILL            0x5a5a5a5au
#define W               64u
#define H               64u

static io_connect_t gpu;

static void
say(const char *fmt, ...)
{
	char line[256];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	printf("%s\n", line);
	fflush(stdout);
	if (gpu != MACH_PORT_NULL && n > 0) {
		IOConnectCallStructMethod(gpu, LOG, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1,
		    NULL, NULL);
	}
}

static kern_return_t
call(uint32_t sel, const uint64_t *in, uint32_t nin, uint64_t *out, uint32_t nout)
{
	uint32_t cnt = nout;
	return IOConnectCallScalarMethod(gpu, sel, in, nin, out, &cnt);
}

struct bo {
	uint64_t handle, va, size;
	volatile uint8_t *cpu;
};

static int
bo_new(struct bo *b, uint64_t size)
{
	uint64_t out[3] = { 0 }, map = 0;
	kern_return_t kr = call(CREATE_BO, &size, 1, out, 3);
	if (kr != KERN_SUCCESS) {
		say("CreateBO(%llu) failed: 0x%x", size, kr);
		return -1;
	}
	b->handle = out[0];
	b->va = out[1];
	b->size = out[2];
	kr = call(MAP_BO, &b->handle, 1, &map, 1);
	if (kr != KERN_SUCCESS || map == 0) {
		say("MapBO(%llu) failed: 0x%x", b->handle, kr);
		return -1;
	}
	b->cpu = (volatile uint8_t *)(uintptr_t)map;
	if (b->va < USER_VA_BASE || b->va + b->size > USER_VA_END) {
		say("BO %llu at GPU VA 0x%llx is outside AS1's user range", b->handle, b->va);
		return -1;
	}
	say("BO %llu: %llu bytes at GPU VA 0x%llx", b->handle, b->size, b->va);
	return 0;
}

static uint32_t
submit(uint64_t jc, unsigned js, uint64_t *us)
{
	uint64_t in[2] = { jc, js }, out[2] = { ~0ull, 0 };
	kern_return_t kr = call(SUBMIT, in, 2, out, 2);
	*us = out[1];
	return kr == KERN_SUCCESS ? (uint32_t)out[0] : 0xdead0000u | (kr & 0xffff);
}

static void
wr32(volatile uint8_t *p, uint32_t off, uint32_t v)
{
	*(volatile uint32_t *)(p + off) = v;
}

static void
wr64(volatile uint8_t *p, uint32_t off, uint64_t v)
{
	*(volatile uint64_t *)(p + off) = v;
}

static uint64_t
rd64(volatile uint8_t *p, uint32_t off)
{
	return *(volatile uint64_t *)(p + off);
}

/* A WRITE_VALUE (ZERO, 64 bits) job header at job+at, writing at GPU VA target. */
static void
write_value(struct bo *job, uint32_t at, uint64_t target)
{
	memset((void *)(job->cpu + at), 0, 64);
	wr32(job->cpu, at + 16, 1u | (2u << 1) | (1u << 16));  /* 64-bit, WRITE_VALUE, index 1 */
	wr64(job->cpu, at + 32, target);
	wr64(job->cpu, at + 40, 3);                             /* ZERO */
	__asm__ volatile ("dsb sy" ::: "memory");
}

static int
open_gpu(void)
{
	/* The kernel's GPU boot tests must have passed before the first open is accepted. */
	for (unsigned tries = 0; tries < 30; tries++) {
		io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("HeroGPU"));
		if (svc != MACH_PORT_NULL) {
			kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &gpu);
			IOObjectRelease(svc);
			if (kr == KERN_SUCCESS) {
				return 0;
			}
			gpu = MACH_PORT_NULL;
			printf("IOServiceOpen: 0x%x, try %u\n", kr, tries + 1);
		} else {
			printf("no HeroGPU service, try %u\n", tries + 1);
		}
		sleep(10);
	}
	return -1;
}

int
main(void)
{
	sleep(30);
	if (open_gpu() != 0) {
		printf("A04S GPU TEST FAIL: no HeroGPU\n");
		return 1;
	}
	say("A04S GPU TEST: hello from user space, pid %d", getpid());

	/* 1. GetParam. */
	static const struct { uint64_t id; const char *name; } params[] = {
		{ 0, "PROD_ID" }, { 1, "REVISION" }, { 2, "SHADER_PRESENT" }, { 3, "TILER_PRESENT" },
		{ 4, "L2_PRESENT" }, { 6, "AS_PRESENT" }, { 7, "JS_PRESENT" }, { 9, "CORE_FEATURES" },
		{ 10, "TILER_FEATURES" }, { 12, "MMU_FEATURES" }, { 14, "MAX_THREADS" },
		{ 18, "TEXTURE_FEATURES0" }, { 22, "JS_FEATURES0" }, { 38, "NR_CORE_GROUPS" },
		{ 39, "THREAD_TLS_ALLOC" }, { 40, "AFBC_FEATURES" },
	};
	uint64_t prod = 0;
	char line[200];
	size_t used = 0;
	line[0] = 0;
	const unsigned count = sizeof(params) / sizeof(params[0]);
	for (unsigned i = 0; i < count; i++) {
		uint64_t v = 0;
		call(GET_PARAM, &params[i].id, 1, &v, 1);
		if (params[i].id == 0) {
			prod = v;
		}
		char one[48];
		int n = snprintf(one, sizeof(one), "%s %llx ", params[i].name, v);
		if (n > 0 && used + (size_t)n >= sizeof(line)) {
			say("%s", line);    /* full: this one starts the next line */
			used = 0;
			line[0] = 0;
		}
		if (n > 0 && (size_t)n < sizeof(line)) {
			memcpy(line + used, one, (size_t)n + 1);
			used += (size_t)n;
		}
		if (used > 120 || i + 1 == count) {
			say("%s", line);
			used = 0;
			line[0] = 0;
		}
	}
	int id_ok = prod == 0x7212;

	struct bo job, rt;
	if (bo_new(&job, 0x10000) || bo_new(&rt, W * H * 4)) {
		say("A04S GPU TEST FAIL: buffers");
		return 1;
	}

	/* 2. WRITE_VALUE on JS1. */
	uint64_t us = 0;
	write_value(&job, 0, job.va + 0x100);
	wr64(job.cpu, 0x100, 0xa5a5a5a55a5a5a5aull);
	__asm__ volatile ("dsb sy" ::: "memory");
	uint32_t wv = submit(job.va, 1, &us);
	uint64_t wv_out = rd64(job.cpu, 0x100);
	int wv_ok = wv == 0 && wv_out == 0;
	say("WRITE_VALUE: status 0x%x, %llu us, output 0x%llx -> %s", wv, us, wv_out, wv_ok ? "OK" : "FAILED");

	/* 3. FRAGMENT clear: job at +0x1200, sample positions +0x1400, framebuffer +0x1800,
	 * its render target descriptor at +0x1880 (v7.xml, as bsd/dev/a04s_gpu.c frag_job()). */
	const uint32_t J = 0x1200, S = 0x1400, F = 0x1800, R = F + 128;
	memset((void *)(job.cpu + 0x1000), 0, 0x1000);
	for (unsigned i = 0; i < W * H; i++) {
		wr32(rt.cpu, i * 4, FILL);
	}
	wr32(job.cpu, J + 16, 1u | (9u << 1) | (1u << 16));            /* 64-bit, FRAGMENT, index 1 */
	wr32(job.cpu, J + 32, 0);                                       /* min tile */
	wr32(job.cpu, J + 36, ((H / 16 - 1) << 16) | (W / 16 - 1));     /* max tile */
	wr64(job.cpu, J + 40, (job.va + F) | 1);                        /* MFBD */
	wr32(job.cpu, S + 0, 0x00800080);                               /* single-sampled, origin 128,128 */
	wr32(job.cpu, S + 128, 0x00800080);
	wr64(job.cpu, F + 16, job.va + S);
	wr32(job.cpu, F + 32, ((H - 1) << 16) | (W - 1));
	wr32(job.cpu, F + 40, ((H - 1) << 16) | (W - 1));
	wr32(job.cpu, F + 44, (2u << 6) | (8u << 9) | (1u << 24));     /* tie-break, 16x16 tiles, 1 KiB */
	wr32(job.cpu, F + 48, 1u << 16);                                /* Z D24 */
	wr32(job.cpu, R + 0, 1u << 26);                                 /* R8G8B8A8 */
	wr32(job.cpu, R + 4, 1u | (19u << 3) | (2u << 8) | (1u << 15) | (0x688u << 16) | (1u << 31));
	wr64(job.cpu, R + 32, rt.va);
	wr32(job.cpu, R + 40, W * 4);
	for (unsigned i = 0; i < 4; i++) {
		wr32(job.cpu, R + 48 + i * 4, COLOR);
	}
	__asm__ volatile ("dsb sy" ::: "memory");
	uint32_t fr = submit(job.va + J, 0, &us);
	unsigned good = 0;
	for (unsigned i = 0; i < W * H; i++) {
		good += *(volatile uint32_t *)(rt.cpu + i * 4) == COLOR;
	}
	int fr_ok = fr == 0 && good == W * H;
	say("FRAGMENT clear 64x64: status 0x%x, %llu us, %u/%u pixels (first 0x%08x) -> %s", fr, us, good,
	    W * H, *(volatile uint32_t *)rt.cpu, fr_ok ? "OK" : "FAILED");

	/* 4. A write to an AS1 address with nothing mapped must fail, then AS1 must work again. */
	write_value(&job, 0x2000, UNMAPPED_VA);
	uint32_t bad = submit(job.va + 0x2000, 1, &us);
	int bad_ok = bad != 0 && bad != 0xffffffffu && bad != 0xfffffffeu && (bad & 0xffff0000u) != 0xdead0000u;
	write_value(&job, 0, job.va + 0x100);
	wr64(job.cpu, 0x100, 0x1111222233334444ull);
	__asm__ volatile ("dsb sy" ::: "memory");
	uint32_t wv2 = submit(job.va, 1, &us);
	uint64_t wv2_out = rd64(job.cpu, 0x100);
	int wv2_ok = wv2 == 0 && wv2_out == 0;
	say("UNMAPPED write: status 0x%x -> %s; WRITE_VALUE after: status 0x%x output 0x%llx -> %s", bad,
	    bad_ok ? "CAUGHT" : "NOT CAUGHT", wv2, wv2_out, wv2_ok ? "OK" : "FAILED");

	/* 5. A chain outside the user range is refused without running. */
	uint32_t out_range = submit(0x02000000ull, 1, &us);
	int range_ok = out_range == 0xffffffffu;
	say("chain at 0x2000000 (AS0's range): status 0x%x -> %s", out_range, range_ok ? "REFUSED" : "NOT REFUSED");

	/* 6. Free one buffer here; the job buffer is left for the kernel to free at exit. */
	uint64_t hnd = rt.handle;
	kern_return_t fk = call(FREE_BO, &hnd, 1, NULL, 0);
	kern_return_t fk2 = call(FREE_BO, &hnd, 1, NULL, 0);    /* twice: must be refused */
	int free_ok = fk == KERN_SUCCESS && fk2 != KERN_SUCCESS;

	int pass = id_ok && wv_ok && fr_ok && bad_ok && wv2_ok && range_ok && free_ok;
	say("A04S GPU TEST %s: ID %llx WV %x FRAG %x %u/%u BAD %x WV2 %x RANGE %x FREE %x/%x", pass ? "PASS" : "FAIL",
	    prod, wv, fr, good, W * H, bad, wv2, out_range, fk, fk2);
	IOServiceClose(gpu);
	return pass ? 0 : 1;
}
