/*
 * Galaxy A04s, Metal track M5: the probe, and the drop package's autorun -- "compute, then a
 * triangle, on the G52".
 *
 *  1. Installs /private/var/a04s/metal/A04sMetal.bundle as /System/Library/Extensions/
 *     A04sMetal.bundle (as root; Metal builds the bundle's path from MetalPluginName), unless every
 *     file there is already this build's. A kill switch file (a04smetal.off) already there is kept.
 *     Then loads the bundle once with NSBundle, which logs why if it cannot be loaded.
 *  2. Runs the tests twice, each in a child process of its own (Metal picks its device once per
 *     process): first on softpipe (RWA_SOFTWARE=1: the same Metal device and shader path on the
 *     CPU, the reference), then on the Mali-G52 through Panfrost and HeroGPU.
 *  3. Each child: MTLCreateSystemDefaultDevice (A04S_METAL=1 lets the bundle answer), then
 *       - compute: fill_buffer (core.metallib) over 4096 uints, each checked against id * 3 + 7;
 *       - a triangle: tri_vs/tri_fs (m5.metallib) into a 64x64 RGBA8 target cleared to blue, the
 *         vertices from a buffer and the colour (red) from a constant buffer; the pixels inside and
 *         outside it counted;
 *       - a quad with a varying: quad_vs/uv_fs (core.metallib) over the whole target, every pixel
 *         checked against its interpolated (u, v).
 *     The pictures are written to /private/var/a04s/m5-<mode>-{tri,quad}.rgba (64x64, RGBA8).
 *
 * Every line goes to /private/var/a04s/metal-probe.log (flushed) and stderr (autorun.log). The
 * Metal device's own lines (bgmtl) go to stderr only. Exit 0 once both runs were tried.
 *
 * Environment (autorun.env): A04S_M6_SAMPLING=1 runs the M6a run 7 sampling tests and run 8's
 * QuartzCore/m5 shader matrix, =2 the matrix alone, =3 run 9's fold/delta comparison alone,
 * (a04s_m6_sampling.m) before the CoreAnimation scenes; A04S_M5_ONLY=softpipe|gpu runs one of the two; A04S_METAL_TIMEOUT
 * (seconds, default 150) limits each child and four times that the whole probe. A04S_CA_SCENES (a list
 * such as 0,5) picks the CoreAnimation scenes; unset, all seven run. Scene 5 is also compared with its
 * CPU reference blurred here, since -renderInContext: ignores layer filters (a04s_ca_scenes.m).
 *
 * REMOVAL: with A04S_METAL_REMOVE=1 it only deletes what M4 and M5 installed --
 * /System/Library/Extensions/A04sMetal.bundle, /private/var/a04s/metal/,
 * /private/var/a04s/lib/A04sMetalCompiler.dylib and /private/var/a04s/metal.clients -- and exits
 * without touching Metal.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <copyfile.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include "a04s_metal_log.h"

extern char **environ;

static const char *SRC_BUNDLE = "/private/var/a04s/metal/A04sMetal.bundle";
static const char *DST_BUNDLE = "/System/Library/Extensions/A04sMetal.bundle";
static const char *KILL = "/System/Library/Extensions/A04sMetal.bundle/a04smetal.off";

static const char *volatile g_step = "start";
#define STEP(s) (g_step = (s))

/* M6a run 4: what the process is waiting on. M6a run 3 spent 335 s building one pipeline with
 * 3.5 s of CPU and no slow kernel call (herodrm's stats), so each heartbeat now also says how much
 * memory the process holds (phys_footprint), how many pages it has read back from storage since
 * the last line (pageins), and how much CPU it used: many page-ins and little CPU is memory
 * pressure on the eMMC, neither is a lock. */
static void *
heartbeat(void *arg)
{
	(void)arg;
	uint64_t last_pageins = 0;
	double last_cpu = 0;
	for (;;) {
		sleep(10);
		task_vm_info_data_t vm;
		mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
		uint64_t footprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) == KERN_SUCCESS
					     ? vm.phys_footprint : 0;
		task_events_info_data_t ev;
		n = TASK_EVENTS_INFO_COUNT;
		uint64_t pageins = task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&ev, &n) == KERN_SUCCESS
					   ? (uint64_t)ev.pageins : 0;
		struct rusage ru;
		getrusage(RUSAGE_SELF, &ru);
		double cpu = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
		a04s_log("heartbeat: alive, step \"%s\"; footprint %.1f MB, %llu page-ins, CPU %.1f s in the last 10 s",
			 g_step, footprint / 1048576.0, (unsigned long long)(pageins - last_pageins), cpu - last_cpu);
		last_pageins = pageins;
		last_cpu = cpu;
	}
	return NULL;
}

static unsigned
timeout_s(void)
{
	const char *t = getenv("A04S_METAL_TIMEOUT");
	unsigned v = t ? (unsigned)atoi(t) : 0;
	return v ? v : 150;
}

/* ---- install and removal ------------------------------------------------------------------- */

/* every regular file of the source bundle has an identical copy at the destination */
static bool
bundle_current(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *src = @(SRC_BUNDLE), *dst = @(DST_BUNDLE);
	NSDirectoryEnumerator *en = [fm enumeratorAtPath:src];
	unsigned n = 0;
	for (NSString *rel in en) {
		BOOL dir = NO;
		NSString *s = [src stringByAppendingPathComponent:rel];
		if (![fm fileExistsAtPath:s isDirectory:&dir] || dir)
			continue;
		NSData *a = [NSData dataWithContentsOfFile:s];
		NSData *b = [NSData dataWithContentsOfFile:[dst stringByAppendingPathComponent:rel]];
		if (!a || !b || ![a isEqualToData:b])
			return false;
		n++;
	}
	return n > 0;
}

static void
install_bundle(void)
{
	struct stat s;
	if (stat(SRC_BUNDLE, &s) != 0) {
		a04s_log("install: no %s (left as it is)", SRC_BUNDLE);
		return;
	}
	if (bundle_current()) {
		a04s_log("install: %s already holds this build", DST_BUNDLE);
		return;
	}
	bool killed = stat(KILL, &s) == 0;
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm removeItemAtPath:@(DST_BUNDLE) error:nil];
	int rc = copyfile(SRC_BUNDLE, DST_BUNDLE, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE);
	a04s_log("install: copyfile %s -> %s: %s", SRC_BUNDLE, DST_BUNDLE, rc == 0 ? "ok" : strerror(errno));
	if (killed) {
		int fd = open(KILL, O_WRONLY | O_CREAT, 0644);
		if (fd >= 0)
			close(fd);
		a04s_log("install: the kill switch a04smetal.off was there and is kept");
	}
}

static void
remove_all(void)
{
	static const char *paths[] = {
		"/System/Library/Extensions/A04sMetal.bundle",
		"/private/var/a04s/metal",
		"/private/var/a04s/lib/A04sMetalCompiler.dylib",
		"/private/var/a04s/metal.clients",
	};
	NSFileManager *fm = [NSFileManager defaultManager];
	for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
		NSString *p = @(paths[i]);
		if (![fm fileExistsAtPath:p]) {
			a04s_log("remove: %s: not there", paths[i]);
			continue;
		}
		NSError *err = nil;
		BOOL ok = [fm removeItemAtPath:p error:&err];
		a04s_log("remove: %s: %s", paths[i], ok ? "removed" : err.localizedDescription.UTF8String);
	}
}

/* ---- the tests (in a child) ---------------------------------------------------------------- */

static id<MTLLibrary>
load_library(id<MTLDevice> dev, const char *path)
{
	NSData *d = [NSData dataWithContentsOfFile:@(path)];
	if (!d) {
		a04s_log("  no %s", path);
		return nil;
	}
	dispatch_data_t data = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
	NSError *err = nil;
	id<MTLLibrary> lib = [dev newLibraryWithData:data error:&err];
	dispatch_release(data);
	a04s_log("  library %s: %s%s%s", path, lib ? "loaded" : "nil", err ? ", error: " : "",
		 err ? err.localizedDescription.UTF8String : "");
	return [lib autorelease];
}

static const char *
cb_result(id<MTLCommandBuffer> cb)
{
	static char s[512];
	snprintf(s, sizeof(s), "status %ld%s%s", (long)cb.status, cb.error ? ", error: " : "",
		 cb.error ? cb.error.localizedDescription.UTF8String : "");
	return s;
}

static void
save_rgba(const char *mode, const char *what, const void *px, size_t n)
{
	char path[128];
	snprintf(path, sizeof(path), "/private/var/a04s/m5-%s-%s.rgba", mode, what);
	FILE *f = fopen(path, "wb");
	if (f) {
		fwrite(px, 1, n, f);
		fclose(f);
	}
}

static bool
test_compute(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> core)
{
	enum { N = 4096 };
	STEP("compute: pipeline");
	id<MTLFunction> fn = [[core newFunctionWithName:@"fill_buffer"] autorelease];
	NSError *err = nil;
	id<MTLComputePipelineState> ps = [[dev newComputePipelineStateWithFunction:fn error:&err] autorelease];
	a04s_log("  compute: pipeline fill_buffer: %s%s%s", ps ? "made" : "nil", err ? ", error: " : "",
		 err ? err.localizedDescription.UTF8String : "");
	if (!ps)
		return false;
	a04s_log("  compute: maxTotalThreadsPerThreadgroup %lu, threadExecutionWidth %lu",
		 (unsigned long)ps.maxTotalThreadsPerThreadgroup, (unsigned long)ps.threadExecutionWidth);
	id<MTLBuffer> buf = [[dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared] autorelease];
	if (!buf || !buf.contents) {
		a04s_log("  compute: no buffer");
		return false;
	}
	memset(buf.contents, 0xab, N * 4);
	STEP("compute: dispatch");
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
	[enc setComputePipelineState:ps];
	[enc setBuffer:buf offset:0 atIndex:0];
	[enc dispatchThreadgroups:MTLSizeMake(N / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[enc endEncoding];
	double t0 = a04s_now();
	[cb commit];
	[cb waitUntilCompleted];
	a04s_log("  compute: committed and completed in %.1f ms, %s", (a04s_now() - t0) * 1000, cb_result(cb));
	const uint32_t *o = buf.contents;
	unsigned bad = 0, first = N;
	for (unsigned i = 0; i < N; i++) {
		if (o[i] != i * 3u + 7u) {
			if (first == N)
				first = i;
			bad++;
		}
	}
	if (bad)
		a04s_log("  compute: %u of %u wrong; first at %u: %#x (want %#x); o[0..3] = %#x %#x %#x %#x", bad, N,
			 first, o[first], first * 3u + 7u, o[0], o[1], o[2], o[3]);
	else
		a04s_log("  compute: all %u values right (o[4095] = %u)", N, o[N - 1]);
	return bad == 0 && cb.status == MTLCommandBufferStatusCompleted;
}

static id<MTLTexture>
target(id<MTLDevice> dev)
{
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
										    width:64 height:64 mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModeShared;
	return [[dev newTextureWithDescriptor:td] autorelease];
}

static id<MTLRenderPipelineState>
render_pipeline(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *vs, NSString *fs)
{
	MTLRenderPipelineDescriptor *pd = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
	pd.vertexFunction = [[lib newFunctionWithName:vs] autorelease];
	pd.fragmentFunction = [[lib newFunctionWithName:fs] autorelease];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
	NSError *err = nil;
	id<MTLRenderPipelineState> ps = [[dev newRenderPipelineStateWithDescriptor:pd error:&err] autorelease];
	a04s_log("  render: pipeline %s + %s: %s%s%s", vs.UTF8String, fs.UTF8String, ps ? "made" : "nil",
		 err ? ", error: " : "", err ? err.localizedDescription.UTF8String : "");
	return ps;
}

static bool
test_triangle(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> m5, const char *mode)
{
	STEP("triangle: pipeline");
	id<MTLRenderPipelineState> ps = render_pipeline(dev, m5, @"tri_vs", @"tri_fs");
	id<MTLTexture> t = target(dev);
	if (!ps || !t) {
		a04s_log("  triangle: %s", t ? "no pipeline" : "no texture");
		return false;
	}
	/* NDC, y up: a triangle of half the target's width, centred */
	static const float pos[6] = { -0.5f, -0.5f, 0.5f, -0.5f, 0.0f, 0.5f };
	static const float red[4] = { 1, 0, 0, 1 };
	id<MTLBuffer> vb = [[dev newBufferWithBytes:pos length:sizeof(pos) options:MTLResourceStorageModeShared] autorelease];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = t;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
	STEP("triangle: draw");
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:ps];
	[enc setVertexBuffer:vb offset:0 atIndex:0];
	[enc setVertexBytes:red length:sizeof(red) atIndex:1];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[enc endEncoding];
	double t0 = a04s_now();
	[cb commit];
	[cb waitUntilCompleted];
	a04s_log("  triangle: committed and completed in %.1f ms, %s", (a04s_now() - t0) * 1000, cb_result(cb));
	static uint8_t px[64 * 64 * 4];
	memset(px, 0x55, sizeof(px));
	[t getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
	save_rgba(mode, "tri", px, sizeof(px));
	unsigned nred = 0, nblue = 0, nother = 0;
	for (unsigned i = 0; i < 64 * 64; i++) {
		const uint8_t *p = px + 4 * i;
		if (p[0] == 255 && p[1] == 0 && p[2] == 0 && p[3] == 255)
			nred++;
		else if (p[0] == 0 && p[1] == 0 && p[2] == 255 && p[3] == 255)
			nblue++;
		else
			nother++;
	}
	const uint8_t *c = px + 4 * (40 * 64 + 32), *k = px + 4 * (2 * 64 + 2), *top = px + 4 * (10 * 64 + 32);
	a04s_log("  triangle: %u red, %u blue, %u other (want about 512 red, the rest blue); pixel (32,40) "
		 "%02x%02x%02x%02x, (32,10) %02x%02x%02x%02x, (2,2) %02x%02x%02x%02x", nred, nblue, nother,
		 c[0], c[1], c[2], c[3], top[0], top[1], top[2], top[3], k[0], k[1], k[2], k[3]);
	/* (32,40) is inside the triangle, (32,10) above its apex (row 16) and (2,2) a corner: both blue */
	bool ok = nother == 0 && nred >= 480 && nred <= 544 && c[0] == 255 && c[2] == 0 && top[2] == 255 &&
		  top[0] == 0 && k[2] == 255 && k[0] == 0 && cb.status == MTLCommandBufferStatusCompleted;
	return ok;
}

static bool
test_quad(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> core, const char *mode)
{
	STEP("quad: pipeline");
	id<MTLRenderPipelineState> ps = render_pipeline(dev, core, @"quad_vs", @"uv_fs");
	id<MTLTexture> t = target(dev);
	if (!ps || !t) {
		a04s_log("  quad: %s", t ? "no pipeline" : "no texture");
		return false;
	}
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = t;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
	STEP("quad: draw");
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:ps];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[enc endEncoding];
	double t0 = a04s_now();
	[cb commit];
	[cb waitUntilCompleted];
	a04s_log("  quad: committed and completed in %.1f ms, %s", (a04s_now() - t0) * 1000, cb_result(cb));
	static uint8_t px[64 * 64 * 4];
	memset(px, 0x55, sizeof(px));
	[t getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
	save_rgba(mode, "quad", px, sizeof(px));
	/* quad_vs: uv = corner * (0.5, -0.5) + 0.5, so pixel (x, y) shows u = (x + 0.5) / 64,
	 * v = (y + 0.5) / 64 (Metal's origin is the top left), blue 0, alpha 1 */
	unsigned bad = 0, worst = 0, wx = 0, wy = 0;
	for (unsigned y = 0; y < 64; y++)
		for (unsigned x = 0; x < 64; x++) {
			const uint8_t *p = px + 4 * (y * 64 + x);
			int want[4] = { (int)((x + 0.5f) / 64 * 255 + 0.5f), (int)((y + 0.5f) / 64 * 255 + 0.5f), 0, 255 };
			unsigned d = 0;
			for (int ch = 0; ch < 4; ch++) {
				unsigned e = (unsigned)abs((int)p[ch] - want[ch]);
				d = e > d ? e : d;
			}
			if (d > 3)
				bad++;
			if (d > worst) {
				worst = d;
				wx = x;
				wy = y;
			}
		}
	const uint8_t *a = px, *b = px + 4 * (63 * 64 + 63);
	a04s_log("  quad: %u of 4096 pixels off by more than 3; worst %u at (%u,%u); (0,0) %02x%02x%02x%02x, "
		 "(63,63) %02x%02x%02x%02x", bad, worst, wx, wy, a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3]);
	return bad == 0 && cb.status == MTLCommandBufferStatusCompleted;
}

int a04s_ca_scenes(id<MTLDevice> d, const char *mode, const char *only);   /* a04s_ca_scenes.m (M6a) */
int a04s_m6_sampling(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> core, id<MTLLibrary> m5,
		      const char *mode);   /* a04s_m6_sampling.m (M6a run 7) */

static bool
env_off(const char *name)
{
	const char *v = getenv(name);
	return v && v[0] == '0';
}

static int
child(const char *mode)
{
	a04s_log("child %s: start (RWA_SOFTWARE=%s)", mode, getenv("RWA_SOFTWARE") ? getenv("RWA_SOFTWARE") : "unset");
	/* Chlorophyll's two QuartzCore/CoreImage settings, before either reads them (M6a) */
	setenv("CA_USE_CGTEXTUREDATA", "0", 0);
	setenv("CI_USE_MTL_DAG_FOR_CIKL_SRC", "0", 0);
	STEP("MTLCreateSystemDefaultDevice");
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	if (!dev) {
		a04s_log("child %s: MTLCreateSystemDefaultDevice: nil", mode);
		return 2;
	}
	a04s_log("child %s: device %s \"%s\" registryID %#llx", mode, object_getClassName(dev), dev.name.UTF8String,
		 (unsigned long long)dev.registryID);
	id<MTLCommandQueue> q = [[dev newCommandQueue] autorelease];
	id<MTLLibrary> core = load_library(dev, "/private/var/a04s/metal/core.metallib");
	id<MTLLibrary> m5 = load_library(dev, "/private/var/a04s/metal/m5.metallib");
	if (!q || !core || !m5) {
		a04s_log("child %s: %s", mode, q ? "a library did not load" : "no command queue");
		return 3;
	}
	bool c = true, t = true, u = true;
	if (!env_off("A04S_M5_TESTS")) {
		c = test_compute(dev, q, core);
		a04s_log("M5 RESULT %s compute: %s", mode, c ? "PASS" : "FAIL");
		t = test_triangle(dev, q, m5, mode);
		a04s_log("M5 RESULT %s triangle: %s", mode, t ? "PASS" : "FAIL");
		u = test_quad(dev, q, core, mode);
		a04s_log("M5 RESULT %s quad: %s", mode, u ? "PASS" : "FAIL");
	}
	/* M6a run 7: texture sampling, from a plain blit up to QuartzCore's downsample with chosen
	 * inputs (A04S_M6_SAMPLING=1) */
	int samp_bad = 0;
	if (getenv("A04S_M6_SAMPLING") && (getenv("A04S_M6_SAMPLING")[0] == '1' || getenv("A04S_M6_SAMPLING")[0] == '2' || getenv("A04S_M6_SAMPLING")[0] == '3')) {
		STEP("sampling");
		samp_bad = a04s_m6_sampling(dev, q, core, m5, mode);
	}
	/* M6a: CoreAnimation's Metal renderer on this device, in this process. Not on softpipe by
	 * default: CoreAnimation's layer contents are IOSurfaces, which only the GPU can import. */
	int ca_bad = 0;
	if (!env_off("A04S_CA") && (strcmp(mode, "softpipe") || getenv("A04S_CA"))) {
		STEP("ca scenes");
		ca_bad = a04s_ca_scenes(dev, mode, getenv("A04S_CA_SCENES"));
	}
	STEP("done");
	return c && t && u && !ca_bad && !samp_bad ? 0 : 1;
}

/* ---- the parent ----------------------------------------------------------------------------- */

static void
run_child(const char *self, const char *mode)
{
	char a_metal[] = "A04S_METAL=1", a_soft[] = "RWA_SOFTWARE=1";
	unsigned n = 0;
	while (environ[n])
		n++;
	char **env = calloc(n + 3, sizeof(char *));
	unsigned k = 0;
	for (unsigned i = 0; i < n; i++)
		if (strncmp(environ[i], "A04S_METAL=", 11) && strncmp(environ[i], "RWA_SOFTWARE=", 13))
			env[k++] = environ[i];
	env[k++] = a_metal;
	if (!strcmp(mode, "softpipe"))
		env[k++] = a_soft;
	env[k] = NULL;
	char *argv[] = { (char *)self, "--child", (char *)mode, NULL };
	pid_t pid;
	int rc = posix_spawn(&pid, self, NULL, NULL, argv, env);
	free(env);
	if (rc) {
		a04s_log("run %s: posix_spawn %s: %s", mode, self, strerror(rc));
		return;
	}
	int st = 0;
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
		;
	if (WIFEXITED(st))
		a04s_log("run %s (pid %d): exit %d (%s)", mode, pid, WEXITSTATUS(st),
			 WEXITSTATUS(st) == 0 ? "all passed" : WEXITSTATUS(st) == 1 ? "a test failed" :
			 WEXITSTATUS(st) == 2 ? "no device" : "setup failed");
	else if (WIFSIGNALED(st))
		a04s_log("run %s (pid %d): ended by signal %d%s", mode, pid, WTERMSIG(st),
			 WTERMSIG(st) == SIGALRM ? " (its time limit)" : "");
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		pthread_t hb;
		if (argc >= 3 && !strcmp(argv[1], "--child")) {
			alarm(timeout_s());
			pthread_create(&hb, NULL, heartbeat, NULL);
			return child(argv[2]);
		}
		a04s_log("a04s-metal-probe (M5): uid %d, argv[0] %s", getuid(), argv[0]);
		alarm(4 * timeout_s());
		pthread_create(&hb, NULL, heartbeat, NULL);
		const char *rm = getenv("A04S_METAL_REMOVE");
		if (rm && !strcmp(rm, "1")) {
			remove_all();
			a04s_log("a04s-metal-probe: removal done");
			return 0;
		}
		STEP("install");
		install_bundle();
		NSError *err = nil;
		NSBundle *b = [NSBundle bundleWithPath:@(DST_BUNDLE)];
		BOOL loaded = [b loadAndReturnError:&err];
		a04s_log("bundle %s: %s%s%s", DST_BUNDLE, loaded ? "loads" : "does NOT load", err ? ": " : "",
			 err ? err.description.UTF8String : "");
		char self[PATH_MAX];
		uint32_t size = sizeof(self);
		if (_NSGetExecutablePath(self, &size) != 0)
			strlcpy(self, argv[0], sizeof(self));
		const char *only = getenv("A04S_M5_ONLY");
		STEP("children");
		if (!only || !strcmp(only, "softpipe"))
			run_child(self, "softpipe");
		if (!only || !strcmp(only, "gpu"))
			run_child(self, "gpu");
		a04s_log("a04s-metal-probe (M5): done");
	}
	return 0;
}
