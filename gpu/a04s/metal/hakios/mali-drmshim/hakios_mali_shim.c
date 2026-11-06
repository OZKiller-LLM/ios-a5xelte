/*
 * Copyright (c) 2026 Scion-Project contributors
 * SPDX-License-Identifier: MIT
 *
 * A drm-shim driver for Mesa's panfrost that answers the way the Galaxy S9's HakiosMali does
 * (drivers/gpu/hakios.mali.c, drivers/gpu/hakios.mali.cpp, tools/mesa/hakios-drm), so that
 * panfrost can be run on a Linux machine with no GPU and build the job chains it would hand the
 * phone's Mali-G72. Written for tools/mali-drmshim-check.sh; Mesa's own panfrost_noop.c
 * (src/panfrost/drm-shim) was the model, nothing of it is copied.
 *
 * What it does like HakiosMali:
 *   - calls itself panfrost, interface version 1.2 (hakios.drm.c's services[] entry), so Mesa
 *     asks for no timestamps (1.3)
 *   - answers DRM_PANFROST_PARAM_* as hakios_mali_parameter() does: from the G72's registers.
 *     Their values are below; the phone has never been read, so they are the G72's published
 *     ones where there are any and assumptions otherwise, each said. HAKIOS_MALI_REGS overrides
 *     any (e.g. HAKIOS_MALI_REGS=shader_present=0x3ffff,tls_alloc=0x180) -- the values step 4
 *     of mali=N logs on the phone go straight in
 *   - gives GPU addresses with the kernel's own allocator, drivers/gpu/hakios.mali_va.h
 *     (#included as it is), sizes rounded to the kernel's 16 KB pages, executable unless
 *     PANFROST_BO_NOEXEC, and gives them back when a buffer is closed
 *   - accepts and does not run job chains (there is no GPU); every chain's address is checked
 *     to be inside a buffer it was given, and every fence is reported signalled
 *     (drmSyncobjExportSyncFile below), so pixels read back are not results
 * What it checks, and prints at exit as one line beginning "hakios-mali-shim:":
 *   every buffer inside 32 MB .. 4 GB, every executable buffer inside one 16 MB line, every
 *   submitted chain inside a buffer, and no parameter asked for that HakiosMali does not answer.
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "drm-shim/drm_shim.h"
#include "drm-uapi/panfrost_drm.h"
#include "util/u_math.h"

#include "hakios.mali_va.h"

bool drm_shim_driver_prefers_first_render_node = true;
static FILE *capture;
static const char *capture_path;
static unsigned capture_next, capture_sequence;

#define KERNEL_PAGE 16384u      /* XNU arm64's page: createBO() rounds to it (round_page_64) */

/* ---- the parameters ------------------------------------------------------------------------- */

struct reg {
	const char *name;
	unsigned param;
	uint64_t value;
	const char *why;
};

/*
 * The values. hakios_mali_parameter() reads each from the register Linux panfrost reads it from;
 * nothing here has been read off this phone yet.
 */
static struct reg regs[] = {
	{ "prod_id", DRM_PANFROST_PARAM_GPU_PROD_ID, 0x6221, "GPU_ID >> 16, the G72 (hakios.mali.c MALI_G72)" },
	{ "revision", DRM_PANFROST_PARAM_GPU_REVISION, 0x0030,
	  "r0p3 assumed (Mesa's pan_props.c gives the G72 anisotropy from r0p3)" },
	{ "shader_present", DRM_PANFROST_PARAM_SHADER_PRESENT, 0x3ffff, "MP18: 18 cores, assumed contiguous" },
	{ "tiler_present", DRM_PANFROST_PARAM_TILER_PRESENT, 0x1, "one tiler" },
	{ "l2_present", DRM_PANFROST_PARAM_L2_PRESENT, 0x1, "one L2 (one core group), assumed" },
	{ "stack_present", DRM_PANFROST_PARAM_STACK_PRESENT, 0, "none on Bifrost (hakios.mali.c)" },
	{ "as_present", DRM_PANFROST_PARAM_AS_PRESENT, 0xff, "assumed" },
	{ "js_present", DRM_PANFROST_PARAM_JS_PRESENT, 0x7, "three job slots, assumed" },
	{ "l2_features", DRM_PANFROST_PARAM_L2_FEATURES, 0x07120206, "assumed (not read by Mesa)" },
	{ "core_features", DRM_PANFROST_PARAM_CORE_FEATURES, 0, "assumed (not read by Mesa)" },
	{ "tiler_features", DRM_PANFROST_PARAM_TILER_FEATURES, 0x809,
	  "8 levels, 512-byte bins: Bifrost's usual value (Mesa's own shim's), assumed" },
	{ "mem_features", DRM_PANFROST_PARAM_MEM_FEATURES, 0x1, "one L2 slice, coherent core group, assumed" },
	{ "mmu_features", DRM_PANFROST_PARAM_MMU_FEATURES, 0x2830,
	  "48 bits of GPU address, 40 physical: hakios.mali.c's note on the G71/G72" },
	{ "thread_features", DRM_PANFROST_PARAM_THREAD_FEATURES, 0,
	  "0: Mesa then assumes 384 x 64 registers for v6, assumed" },
	{ "max_threads", DRM_PANFROST_PARAM_MAX_THREADS, 384, "the first Bifrost's 384 (Mesa's own v6 fallback)" },
	{ "max_wg", DRM_PANFROST_PARAM_THREAD_MAX_WORKGROUP_SZ, 384, "as max_threads, assumed" },
	{ "max_barrier", DRM_PANFROST_PARAM_THREAD_MAX_BARRIER_SZ, 384, "as max_threads, assumed" },
	{ "coherency_features", DRM_PANFROST_PARAM_COHERENCY_FEATURES, 0x1, "assumed (not read by Mesa)" },
	{ "texture_features0", DRM_PANFROST_PARAM_TEXTURE_FEATURES0, 0xffffffff,
	  "every compressed format, as Mesa's own shim; unknown" },
	{ "texture_features1", DRM_PANFROST_PARAM_TEXTURE_FEATURES1, 0xffffffff, "as texture_features0" },
	{ "texture_features2", DRM_PANFROST_PARAM_TEXTURE_FEATURES2, 0xffffffff, "as texture_features0" },
	{ "texture_features3", DRM_PANFROST_PARAM_TEXTURE_FEATURES3, 0xffffffff, "as texture_features0" },
	{ "nr_core_groups", DRM_PANFROST_PARAM_NR_CORE_GROUPS, 1, "one per L2 (hakios.mali.c)" },
	/* hakios.mali.c answers max(THREAD_TLS_ALLOC, THREAD_MAX_THREADS): never less than max_threads */
	{ "tls_alloc", DRM_PANFROST_PARAM_THREAD_TLS_ALLOC, 384, "max(TLS_ALLOC, MAX_THREADS), the kernel's floor" },
	{ "afbc_features", DRM_PANFROST_PARAM_AFBC_FEATURES, 0, "0: none, as hakios.mali.c answers" },
};

static unsigned unanswered;

static void
regs_from_environment(void)
{
	const char *s = getenv("HAKIOS_MALI_REGS");
	char *copy, *item, *save = NULL;

	if (s == NULL)
		return;
	copy = strdup(s);
	for (item = strtok_r(copy, ",", &save); item != NULL; item = strtok_r(NULL, ",", &save)) {
		char *eq = strchr(item, '=');
		bool found = false;

		if (eq == NULL)
			continue;
		*eq = 0;
		for (unsigned i = 0; i < ARRAY_SIZE(regs); i++) {
			if (strcmp(regs[i].name, item) == 0) {
				regs[i].value = strtoull(eq + 1, NULL, 0);
				regs[i].why = "HAKIOS_MALI_REGS";
				found = true;
			}
		}
		if (!found)
			fprintf(stderr, "hakios-mali-shim: HAKIOS_MALI_REGS: no register %s\n", item);
	}
	free(copy);
}

static int
get_param(int fd, unsigned long request, void *arg)
{
	struct drm_panfrost_get_param *gp = arg;

	for (unsigned i = 0; i < ARRAY_SIZE(regs); i++) {
		if (regs[i].param == gp->param) {
			gp->value = regs[i].value;
			if (capture) fprintf(capture, "{\"op\":\"param\",\"param\":%u,\"value\":%" PRIu64 "}\n", gp->param, (uint64_t)gp->value);
			return 0;
		}
	}
	/* JS_FEATURES n (22..37) HakiosMali answers from the registers too; nothing else */
	if (gp->param >= DRM_PANFROST_PARAM_JS_FEATURES0 && gp->param <= DRM_PANFROST_PARAM_JS_FEATURES15) {
		gp->value = gp->param - DRM_PANFROST_PARAM_JS_FEATURES0 < 3 ? 0x20e : 0;
		return 0;
	}
	fprintf(stderr, "hakios-mali-shim: parameter %u asked for, which HakiosMali does not answer\n", gp->param);
	unanswered++;
	return -1;
}

/* ---- the buffers ------------------------------------------------------------------------------ */

struct mali_bo {
	struct shim_bo base;    /* first: drm-shim frees the whole of it */
	uint64_t va, size;
	uint32_t flags;
	unsigned capture_id;
};

static struct mali_va va_space;
static mtx_t va_lock;
static struct {
	unsigned buffers, executable, heap, outside, crossing, freed, bad_free, no_va, chains, chains_outside;
	uint64_t lowest, highest, bytes, peak_bytes;
} stats = { .lowest = UINT64_MAX };
static FILE *trace;

static void
bo_free(struct shim_bo *shim_bo)
{
	struct mali_bo *bo = (struct mali_bo *)shim_bo;

	mtx_lock(&va_lock);
	if (bo->va != 0) {
		if (capture) fprintf(capture, "{\"op\":\"free\",\"id\":%u}\n", bo->capture_id);
		if (mali_va_free(&va_space, bo->va, bo->size))
			stats.freed++;
		else
			stats.bad_free++;
		stats.bytes -= bo->size;
	}
	if (trace)
		fprintf(trace, "free va %#" PRIx64 " size %#" PRIx64 "\n", bo->va, bo->size);
	mtx_unlock(&va_lock);
}

static int
create_bo(int fd, unsigned long request, void *arg)
{
	struct drm_panfrost_create_bo *create = arg;
	struct shim_fd *shim_fd = drm_shim_fd_lookup(fd);
	struct mali_bo *bo = calloc(1, sizeof(*bo));
	uint64_t size = ALIGN_POT((uint64_t)create->size, KERNEL_PAGE);
	bool exec = !(create->flags & PANFROST_BO_NOEXEC);

	if (bo == NULL || size == 0 || size > (256ull << 20))   /* MALI_BUFFER_MAX */
		goto fail;
	if (drm_shim_bo_init(&bo->base, size) != 0)
		goto fail;
	mtx_lock(&va_lock);
	bo->va = mali_va_alloc(&va_space, size, exec);
	bo->size = size;
	bo->flags = create->flags;
	bo->capture_id = ++capture_next;
	if (bo->va == 0) {
		stats.no_va++;
		mtx_unlock(&va_lock);
		drm_shim_bo_put(&bo->base);
		return -1;
	}
	stats.buffers++;
	stats.executable += exec;
	stats.heap += !!(create->flags & PANFROST_BO_HEAP);
	stats.bytes += size;
	stats.peak_bytes = MAX2(stats.peak_bytes, stats.bytes);
	stats.lowest = MIN2(stats.lowest, bo->va);
	stats.highest = MAX2(stats.highest, bo->va + size);
	if (bo->va < MALI_VA_FIRST || bo->va + size > MALI_VA_END)
		stats.outside++;
	if (exec && bo->va / MALI_VA_EXEC_LINE != (bo->va + size - 1) / MALI_VA_EXEC_LINE)
		stats.crossing++;
	if (trace)
		fprintf(trace, "bo va %#" PRIx64 " size %#" PRIx64 " flags %#x%s\n", bo->va, size, create->flags,
		        exec ? " exec" : "");
	mtx_unlock(&va_lock);

	create->handle = drm_shim_bo_get_handle(shim_fd, &bo->base);
	create->offset = bo->va;
	if (capture) fprintf(capture, "{\"op\":\"alloc\",\"id\":%u,\"va\":%" PRIu64 ",\"size\":%" PRIu64 ",\"flags\":%u}\n",
	    bo->capture_id, bo->va, bo->size, bo->flags);
	drm_shim_bo_put(&bo->base);
	return 0;
fail:
	free(bo);
	return -1;
}

static int
mmap_bo(int fd, unsigned long request, void *arg)
{
	struct drm_panfrost_mmap_bo *m = arg;
	struct shim_fd *shim_fd = drm_shim_fd_lookup(fd);
	struct shim_bo *bo = drm_shim_bo_lookup(shim_fd, m->handle);

	if (bo == NULL)
		return -1;
	m->offset = drm_shim_bo_get_mmap_offset(shim_fd, bo);
	drm_shim_bo_put(bo);
	return 0;
}

static int
get_bo_offset(int fd, unsigned long request, void *arg)
{
	struct drm_panfrost_get_bo_offset *o = arg;
	struct shim_fd *shim_fd = drm_shim_fd_lookup(fd);
	struct shim_bo *bo = drm_shim_bo_lookup(shim_fd, o->handle);

	if (bo == NULL)
		return -1;
	o->offset = ((struct mali_bo *)bo)->va;
	drm_shim_bo_put(bo);
	return 0;
}

/* ---- the jobs --------------------------------------------------------------------------------- */

static int
submit(int fd, unsigned long request, void *arg)
{
	struct drm_panfrost_submit *s = arg;
	struct shim_fd *shim_fd = drm_shim_fd_lookup(fd);
	const uint32_t *handles = (const uint32_t *)(uintptr_t)s->bo_handles;
	bool inside = false;
	unsigned sequence = ++capture_sequence;
	if (capture) {
		fprintf(capture, "{\"op\":\"submit\",\"seq\":%u,\"jc\":%" PRIu64 ",\"requirements\":%u}\n",
		    sequence, (uint64_t)s->jc, s->requirements);
		for (uint32_t i = 0; i < s->bo_handle_count; i++) {
			struct shim_bo *base = drm_shim_bo_lookup(shim_fd, handles[i]);
			if (!base) abort();
			struct mali_bo *bo = (struct mali_bo *)base;
			char filename[1024];
			snprintf(filename, sizeof(filename), "%s/submit-%u-bo-%u.bin", capture_path, sequence, bo->capture_id);
			FILE *output = fopen(filename, "wb");
			unsigned char *data = malloc(base->size);
			if (!output || !data || pread(shim_device.mem_fd, data, base->size, base->mem_addr) != base->size ||
			    fwrite(data, 1, base->size, output) != base->size || fclose(output) != 0) abort();
			free(data);
			fprintf(capture, "{\"op\":\"snapshot\",\"seq\":%u,\"id\":%u,\"file\":\"submit-%u-bo-%u.bin\"}\n",
			    sequence, bo->capture_id, sequence, bo->capture_id);
			drm_shim_bo_put(base);
		}
		fflush(capture);
	}

	/* the chain's first job must be in one of the buffers the submit names */
	for (uint32_t i = 0; i < s->bo_handle_count && !inside; i++) {
		struct shim_bo *bo = drm_shim_bo_lookup(shim_fd, handles[i]);

		if (bo != NULL) {
			struct mali_bo *m = (struct mali_bo *)bo;
			inside = s->jc >= m->va && s->jc + 128 <= m->va + m->size;
			drm_shim_bo_put(bo);
		}
	}
	mtx_lock(&va_lock);
	stats.chains++;
	stats.chains_outside += !inside;
	if (trace)
		fprintf(trace, "submit jc %#llx reqs %#x bos %u%s\n", (unsigned long long)s->jc, s->requirements,
		        s->bo_handle_count, inside ? "" : " OUTSIDE");
	mtx_unlock(&va_lock);
	return 0;
}

/*
 * A fence as a sync file. drm-shim answers DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD with a stub that
 * gives no file, so panfrost_fence_create says "export failed" and hands back no fence -- and
 * libhakiosair, rightly, refuses a dispatch or draw it cannot wait for. HakiosMali's shim does
 * export one (hakios.drm.c). So libdrm's call is answered here, ahead of libdrm (this library
 * is preloaded), with a file that stands for a fence already signalled: nothing runs the jobs,
 * so every fence is as finished as it will ever be. What is read back after it is NOT a result.
 */
__attribute__((visibility("default"))) int
drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd)
{
	*sync_file_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
	return *sync_file_fd < 0 ? -1 : 0;
}

static int
noop(int fd, unsigned long request, void *arg)
{
	return 0;
}

static int
madvise(int fd, unsigned long request, void *arg)
{
	((struct drm_panfrost_madvise *)arg)->retained = 1;
	return 0;
}

static ioctl_fn_t ioctls[] = {
	[DRM_PANFROST_SUBMIT] = submit,
	[DRM_PANFROST_WAIT_BO] = noop,
	[DRM_PANFROST_CREATE_BO] = create_bo,
	[DRM_PANFROST_MMAP_BO] = mmap_bo,
	[DRM_PANFROST_GET_PARAM] = get_param,
	[DRM_PANFROST_GET_BO_OFFSET] = get_bo_offset,
	[DRM_PANFROST_PERFCNT_ENABLE] = noop,
	[DRM_PANFROST_PERFCNT_DUMP] = noop,
	[DRM_PANFROST_MADVISE] = madvise,
};

static void
report(void)
{
	bool good = stats.outside == 0 && stats.crossing == 0 && stats.chains_outside == 0 && stats.bad_free == 0 &&
	            stats.no_va == 0 && unanswered == 0;

	fprintf(stderr,
	        "hakios-mali-shim: %s: %u buffers (%u executable, %u heap), %u freed, GPU addresses %#" PRIx64
	        "..%#" PRIx64 ", at most %" PRIu64 " KB at once; outside 32 MB..4 GB %u, code across a 16 MB line %u, "
	        "refused %u, bad frees %u; %u chains submitted, %u not inside a buffer; %u parameters unanswered\n",
	        good ? "contract kept" : "CONTRACT BROKEN", stats.buffers, stats.executable, stats.heap, stats.freed,
	        stats.buffers ? stats.lowest : 0, stats.highest, stats.peak_bytes / 1024, stats.outside,
	        stats.crossing, stats.no_va, stats.bad_free, stats.chains, stats.chains_outside, unanswered);
	/* the trace stays open: drm-shim may free buffers after this, and they are logged */
	if (trace)
		fflush(trace);
}

void
drm_shim_driver_init(void)
{
	const char *t = getenv("HAKIOS_MALI_SHIM_TRACE");
	capture_path = getenv("HAKIOS_MALI_CAPTURE");
	if (capture_path) {
		char filename[1024];
		snprintf(filename, sizeof(filename), "%s/events.jsonl", capture_path);
		capture = fopen(filename, "w");
		if (!capture) abort();
	}

	regs_from_environment();
	mtx_init(&va_lock, mtx_plain);
	if (t != NULL)
		trace = fopen(t, "w");
	if (getenv("HAKIOS_MALI_SHIM_REGS")) {
		for (unsigned i = 0; i < ARRAY_SIZE(regs); i++)
			fprintf(stderr, "hakios-mali-shim: %-18s %#10" PRIx64 "  %s\n", regs[i].name, regs[i].value,
			        regs[i].why);
	}

	shim_device.bus_type = DRM_BUS_PLATFORM;
	shim_device.driver_name = "panfrost";
	shim_device.version_major = 1;
	shim_device.version_minor = 2;
	shim_device.version_patchlevel = 0;
	shim_device.driver_ioctls = ioctls;
	shim_device.driver_ioctl_count = ARRAY_SIZE(ioctls);
	shim_device.driver_bo_free = bo_free;
	drm_shim_override_file("DRIVER=panfrost\n"
	                       "OF_FULLNAME=/soc/mali@17500000\n"
	                       "OF_COMPATIBLE_0=arm,mali-bifrost\n"
	                       "OF_COMPATIBLE_N=1\n",
	                       "/sys/dev/char/%d:%d/device/uevent", DRM_MAJOR, render_node_minor);
	atexit(report);
}
