/*
 * Galaxy A04s, Metal track M4: the probe, and the drop package's autorun.
 *
 *  1. Installs /private/var/a04s/metal/A04sMetal.bundle as /System/Library/Extensions/
 *     A04sMetal.bundle (as root; Metal builds the bundle's path from MetalPluginName under that
 *     folder), unless the same files are already there.
 *  2. With A04S_METAL=1 (our device answers only then) and MTL_MONOLITHIC_COMPILER=1 (compile in
 *     this process, so the plug-in's lines are ours and no XPC sandbox is involved), asks Metal
 *     for its device and logs what it is, and its GPU families.
 *  3. Loads our own test library (/private/var/a04s/metal/core.metallib, from
 *     gpu/a04s/metal/shaders/core.metal, never Apple's), lists its functions, and asks for
 *     fill_buffer's compute pipeline: the request that reaches the compiler plug-in.
 *
 * Everything is logged to stderr (autorun.log) and /private/var/a04s/metal-probe.log. Nothing is
 * drawn or computed. Exit 0 once all steps were tried.
 *
 * REMOVAL: with A04S_METAL_REMOVE=1 (autorun.env), it only deletes what M4 installed --
 * /System/Library/Extensions/A04sMetal.bundle, /private/var/a04s/metal/,
 * /private/var/a04s/lib/A04sMetalCompiler.dylib and /private/var/a04s/metal.clients -- logs
 * each, and exits without touching Metal. The log itself is kept for reading back.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <copyfile.h>
#include <errno.h>
#include <sys/stat.h>

#include "a04s_metal_log.h"

static const char *SRC_BUNDLE = "/private/var/a04s/metal/A04sMetal.bundle";
static const char *DST_BUNDLE = "/System/Library/Extensions/A04sMetal.bundle";

static void
install_bundle(void)
{
	struct stat s;
	if (stat(SRC_BUNDLE, &s) != 0) {
		a04s_log("install: no %s (left as it is)", SRC_BUNDLE);
		return;
	}
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *src = @(SRC_BUNDLE), *dst = @(DST_BUNDLE);
	NSData *a = [NSData dataWithContentsOfFile:[src stringByAppendingPathComponent:@"A04sMetal"]];
	NSData *b = [NSData dataWithContentsOfFile:[dst stringByAppendingPathComponent:@"A04sMetal"]];
	if (a && b && [a isEqualToData:b]) {
		a04s_log("install: %s already holds this build", DST_BUNDLE);
		return;
	}
	[fm removeItemAtPath:dst error:nil];
	int rc = copyfile(SRC_BUNDLE, DST_BUNDLE, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE);
	a04s_log("install: copyfile %s -> %s: %s", SRC_BUNDLE, DST_BUNDLE, rc == 0 ? "ok" : strerror(errno));
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

/* M4 run 2: where the probe is, for the heartbeat. The first phone run stopped logging after
 * "supportsFamily Apple4" with no exit; a thread now names the current step every 10 s, so a
 * hang shows as repeated heartbeats on one step and slow disk flushes as slow lines. */
static const char *volatile g_step = "start";
#define STEP(s) (g_step = (s))

static void *
heartbeat(void *arg)
{
	(void)arg;
	for (;;) {
		sleep(10);
		a04s_log("heartbeat: alive, step \"%s\"", g_step);
	}
	return NULL;
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		a04s_log("a04s-metal-probe (M4 run 2): uid %d, argv[0] %s", getuid(), argv[0]);
		/* A time limit, so the drop agent always sees the autorun end: A04S_METAL_TIMEOUT
		 * seconds (default 300), then SIGALRM's default action ends the process. */
		const char *to = getenv("A04S_METAL_TIMEOUT");
		alarm(to ? (unsigned)atoi(to) : 300);
		pthread_t hb;
		pthread_create(&hb, NULL, heartbeat, NULL);
		const char *rm = getenv("A04S_METAL_REMOVE");
		if (rm && !strcmp(rm, "1")) {
			remove_all();
			a04s_log("a04s-metal-probe: removal done");
			return 0;
		}
		STEP("install");
		install_bundle();
		setenv("A04S_METAL", "1", 1);
		setenv("MTL_MONOLITHIC_COMPILER", "1", 0);

		STEP("MTLCreateSystemDefaultDevice");
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		if (!dev) {
			a04s_log("MTLCreateSystemDefaultDevice: nil (is a04smetal=1 set, and the bundle in place?)");
			return 0;
		}
		a04s_log("device: %s \"%s\" registryID %#llx", object_getClassName(dev), dev.name.UTF8String,
			 (unsigned long long)dev.registryID);
		static const struct { long f; const char *n; } fam[] = {
			{ 1001, "Apple1" }, { 1002, "Apple2" }, { 1003, "Apple3" }, { 1004, "Apple4" },
			{ 1005, "Apple5" }, { 1006, "Apple6" }, { 1007, "Apple7" }, { 1008, "Apple8" },
			{ 3001, "Common1" }, { 3002, "Common2" }, { 3003, "Common3" }, { 5001, "Metal3" },
		};
		STEP("supportsFamily");
		{
			/* all twelve asked first, then logged on one line: the answers do not wait on
			 * the disk in between */
			char fams[512] = "";
			for (unsigned i = 0; i < sizeof(fam) / sizeof(fam[0]); i++) {
				BOOL yes = [dev supportsFamily:(MTLGPUFamily)fam[i].f];
				strlcat(fams, fam[i].n, sizeof(fams));
				strlcat(fams, yes ? "=YES " : "=no ", sizeof(fams));
			}
			a04s_log("  supportsFamily: %s", fams);
		}
		STEP("respondsToSelector / thread limits");
		/* Anything past the registration path is asked only when answered: a selector the
		 * device lacks is logged by its resolveInstanceMethod: (through respondsToSelector:)
		 * instead of ending the run before the compile request. */
		if ([dev respondsToSelector:@selector(maxThreadsPerThreadgroup)] &&
		    [dev respondsToSelector:@selector(maxThreadgroupMemoryLength)])
			a04s_log("  maxThreadsPerThreadgroup %lu x %lu x %lu, maxThreadgroupMemoryLength %lu",
				 (unsigned long)dev.maxThreadsPerThreadgroup.width,
				 (unsigned long)dev.maxThreadsPerThreadgroup.height,
				 (unsigned long)dev.maxThreadsPerThreadgroup.depth,
				 (unsigned long)dev.maxThreadgroupMemoryLength);
		if (![dev respondsToSelector:@selector(newLibraryWithData:error:)] ||
		    ![dev respondsToSelector:@selector(newComputePipelineStateWithFunction:error:)]) {
			a04s_log("the device does not answer newLibraryWithData:error: or "
				 "newComputePipelineStateWithFunction:error: (see the lines above)");
			return 0;
		}

		NSData *lib = [NSData dataWithContentsOfFile:@"/private/var/a04s/metal/core.metallib"];
		if (!lib) {
			a04s_log("no /private/var/a04s/metal/core.metallib");
			return 0;
		}
		NSError *err = nil;
		dispatch_data_t data = dispatch_data_create(lib.bytes, lib.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
		STEP("newLibraryWithData");
		id<MTLLibrary> library = [dev newLibraryWithData:data error:&err];
		a04s_log("newLibraryWithData: %s%s%s", library ? object_getClassName(library) : "nil",
			 err ? ", error: " : "", err ? err.localizedDescription.UTF8String : "");
		if (!library)
			return 0;
		a04s_log("  functions: %s", [library.functionNames componentsJoinedByString:@", "].UTF8String);
		STEP("newFunctionWithName");
		id<MTLFunction> fn = [library newFunctionWithName:@"fill_buffer"];
		a04s_log("newFunctionWithName: fill_buffer -> %s", fn ? object_getClassName(fn) : "nil");
		if (!fn)
			return 0;
		err = nil;
		a04s_log("newComputePipelineStateWithFunction: fill_buffer ... (the request to the plug-in)");
		STEP("newComputePipelineStateWithFunction (compiler plug-in)");
		id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:fn error:&err];
		STEP("done");
		a04s_log("newComputePipelineStateWithFunction: %s%s%s", ps ? object_getClassName(ps) : "nil",
			 err ? ", error: " : "", err ? err.localizedDescription.UTF8String : "");
		a04s_log("a04s-metal-probe: done");
	}
	return 0;
}
