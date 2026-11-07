/*
 * Galaxy A04s, Metal track M4: A04sMetal.bundle, the first Metal device for the Mali-G52 -- a
 * LOGGING one. It draws and computes nothing. It answers what Metal's registration checks (from
 * iOS 16.7's Metal.framework, metal-driver-step1.md and the S9+ port's measurements), hands
 * Metal a compiler whose plug-in is our logging one, and writes down every selector Metal asks of
 * it that it does not answer.
 *
 * How Metal reaches it: MTLRegisterDevices matches IOAcceleratorES, reads MetalPluginName
 * ("A04sMetal") and MetalPluginClassName ("A04sMetalDevice") -- published by HeroGPU only with
 * the boot-arg a04smetal=1 -- loads /System/Library/Extensions/A04sMetal.bundle and calls
 * [[A04sMetalDevice alloc] initWithAcceleratorPort:]. A nil answer is skipped by Metal (a cbz
 * before MTLAddDevice in 16.7's Metal.framework), so this returns nil in every process that is
 * not asking for it: A04S_METAL=1 in the environment, or the process's name as a line of
 * /private/var/a04s/metal.clients. backboardd and SpringBoard keep getting no Metal device.
 *
 * Built with the iPhoneOS SDK against the device's own Metal.framework: _MTLDevice is not in the
 * SDK's headers but is exported by Metal (its class symbol is bound at load, -Wl,-U). Manual
 * reference counting (-fno-objc-arc).
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include "a04s_metal_log.h"

typedef mach_port_t io_registry_entry_t;
extern kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry, uint64_t *id);

/* Metal's private base class: only the name is declared; its ivars are Metal's own, and the
 * non-fragile ABI places ours after them at load. */
@interface _MTLDevice : NSObject
- (instancetype)init;
@end

/* -[_MTLDevice targetDeviceInfo] answers NULL, which crashes backboardd at boot (viva-gpu's
 * note); AGXMetalA11's answers a {u64, u32, char *} from a table. */
struct MTLTargetDeviceArch {
	uint64_t cpu_type;
	uint32_t subtype;
	const char *name;
};
static const struct MTLTargetDeviceArch a04s_arch = { 0, 0, "a04s-mali-g52" };

static bool
a04s_allowed(void)
{
	const char *e = getenv("A04S_METAL");
	if (e && !strcmp(e, "1"))
		return true;
	FILE *f = fopen("/private/var/a04s/metal.clients", "r");
	if (!f)
		return false;
	char line[256];
	bool ok = false;
	while (!ok && fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\r\n")] = 0;
		ok = line[0] && !strcmp(line, getprogname());
	}
	fclose(f);
	return ok;
}

@interface A04sMetalDevice : _MTLDevice
@end

@implementation A04sMetalDevice {
	uint64_t _registry;
	id _compiler;
}

+ (void)load
{
	/* MTLAddDevice asserts conformance to MTLDevice and MTLDeviceSPI (both fatal). The SPI
	 * protocol is private; declared at run time, as the S9+ port's HakiosMetal does. */
	Protocol *spi = objc_getProtocol("MTLDeviceSPI");
	if (spi)
		class_addProtocol(self, spi);
	Protocol *pub = objc_getProtocol("MTLDevice");
	if (pub)
		class_addProtocol(self, pub);
}

/* Everything Metal asks that no class in our chain answers, once per selector. Also called for
 * a respondsToSelector: check, so "asked" covers both. */
+ (BOOL)resolveInstanceMethod:(SEL)sel
{
	a04s_log("asked, not answered: -[A04sMetalDevice %s]", sel_getName(sel));
	return [super resolveInstanceMethod:sel];
}

- (id)initWithAcceleratorPort:(uint32_t)port
{
	if (!a04s_allowed()) {
		/* not this process: Metal skips a nil device. The object is left, not released: it
		 * was never initialised, and _MTLDevice's dealloc is not ours to run on it. */
		return nil;
	}
	a04s_log("initWithAcceleratorPort: %u (A04sMetal M4, logging only)", port);
	self = [super init];
	if (!self)
		return nil;
	IORegistryEntryGetRegistryEntryID(port, &_registry);
	[self a04sSetupCompiler];
	a04s_log("device ready: registryID %#llx, compiler %s", (unsigned long long)_registry,
		 _compiler ? object_getClassName(_compiler) : "(none)");
	return self;
}

- (void)a04sSetupCompiler
{
	Class C = NSClassFromString(@"MTLCompiler");
	if (!C) {
		a04s_log("no MTLCompiler class");
		return;
	}
	const char *p = getenv("A04S_METAL_PLUGIN");
	NSString *plugin = [NSString stringWithUTF8String:p ? p : "/private/var/a04s/lib/A04sMetalCompiler.dylib"];
	const char *f = getenv("A04S_METAL_COMPILER_FLAGS");
	uint64_t flags = strtoull(f ? f : "0x200", NULL, 0);
	/* the target data: ours to define, read by our own plug-in only */
	static const char target[] = "A04S-METAL-M4 gpu=0x7212 arch=v7 sc=1";
	dispatch_data_t td = dispatch_data_create(target, sizeof(target), NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
	struct { uint8_t b[32]; } uuid;
	memcpy(uuid.b, "A04sMetalM4-logging-cache-uuid", 31);
	uuid.b[31] = 0;
	a04s_log("MTLCompiler initWithTargetData: (%zu bytes) cacheUUID: pluginPath: %s device: self "
		 "compilerFlags: %#llx", sizeof(target), plugin.UTF8String, (unsigned long long)flags);
	id (*init)(id, SEL, id, void *, id, id, uint64_t) = (void *)objc_msgSend;
	_compiler = init([C alloc], sel_registerName("initWithTargetData:cacheUUID:pluginPath:device:compilerFlags:"),
			 (id)td, &uuid, plugin, self, flags);
	dispatch_release(td);
}

/* --- what MTLAddDevice and _MTLDevice's own init read ------------------------------------ */
- (NSUInteger)featureProfile { return 4; }   /* Apple3: no tile shaders, imageblocks, ROGs */
- (uint64_t)maxBufferLength { return 256ull << 20; }
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count { return count <= 1; }
- (const struct MTLTargetDeviceArch *)targetDeviceInfo { return &a04s_arch; }
- (id)compiler { return _compiler; }

/* --- identity, and what CoreImage's CIMetalDeviceGetLimits needs ------------------------- */
- (NSString *)name { return @"Mali-G52 (A04s Metal M4, logging)"; }
- (NSString *)vendorName { return @"ARM"; }
- (NSString *)familyName { return @"Mali-G52"; }
- (NSString *)productName { return @"Galaxy A04s Mali-G52 MP1"; }
- (uint64_t)registryID { return _registry; }
- (uint64_t)dedicatedMemorySize { return 0; }
- (uint64_t)sharedMemorySize { return 1ull << 30; }
- (uint64_t)recommendedMaxWorkingSetSize { return 512ull << 20; }
- (BOOL)hasUnifiedMemory { return YES; }
- (BOOL)isLowPower { return YES; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }

/* --- the driver's duties, logged and refused for now ------------------------------------- */
- (id)newBufferWithLength:(NSUInteger)length options:(NSUInteger)options
{
	a04s_log("newBufferWithLength:%lu options:%#lx -> nil (M4 logs only)", (unsigned long)length,
		 (unsigned long)options);
	return nil;
}

- (id)newCommandQueueWithDescriptor:(id)descriptor
{
	a04s_log("newCommandQueueWithDescriptor: %s -> nil (M4 logs only)", object_getClassName(descriptor));
	return nil;
}

- (id)computeVariantWithCompilerOutput:(id)output pipelineStatisticsOutput:(id)stats
{
	a04s_log("computeVariantWithCompilerOutput: %s pipelineStatisticsOutput: %s -> nil",
		 output ? object_getClassName(output) : "nil", stats ? object_getClassName(stats) : "nil");
	return nil;
}

- (id)newComputePipelineWithDescriptor:(id)descriptor variant:(id)variant
{
	a04s_log("newComputePipelineWithDescriptor: %s variant: %s -> nil",
		 descriptor ? object_getClassName(descriptor) : "nil",
		 variant ? object_getClassName(variant) : "nil");
	return nil;
}

@end
