/*
 * Galaxy A04s, Metal track M5: the Metal device, libA04sMetalDevice.dylib inside A04sMetal.bundle.
 *
 * Chlorophyll's device (../chlorophyll/bgmtl.m, MIT; see that folder's NOTICE.md) is compiled in
 * here whole, as Chlorophyll's own system plug-in does it, over libhakiosair: Gallium Panfrost on
 * the Mali-G52 through HeroGPU (gpu/mesa/herodrm.c), or softpipe with RWA_SOFTWARE=1. Buffers,
 * command queues and buffers, compute and render encoders, textures, samplers and pipelines are
 * Chlorophyll's; a pipeline's shaders go from -[_MTLFunction bitcodeData] through the AIR front
 * end to Panfrost's Bifrost compiler in this process, so Apple's compiler service and its plug-in
 * are never used (M4 run 2 showed iOS 16.7's service only loads plug-ins from system paths).
 *
 * A04sMTLDevice adds what is the A04s's own: the identity M4 gave the device on the phone
 * (featureProfile 4, the GPU's name, the IOKit registry ID of HeroGPU's IOAcceleratorES), the
 * non-NULL targetDeviceInfo, and log lines in /private/var/a04s/metal-probe.log.
 *
 * Nothing registers this class by itself: A04sMetal.bundle's gate (A04sMetal.m) loads this
 * library and hands Metal an instance only in a process that asks for it.
 */
#include "../chlorophyll/bgmtl.m"

#include "a04s_metal_log.h"

typedef mach_port_t a04s_io_registry_entry_t;
extern kern_return_t IORegistryEntryGetRegistryEntryID(a04s_io_registry_entry_t entry, uint64_t *id);

/* -[_MTLDevice targetDeviceInfo]: {u64, u32, const char *name}, as M4 answered it. */
static const struct { uint64_t a; uint32_t b; const char *name; } a04s_target_info = { 0, 0, "a04s-mali-g52" };

@interface A04sMTLDevice : BGMTLDevice
@end

@implementation A04sMTLDevice {
   uint64_t _a04sRegistry;
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
   const char *soft = getenv("RWA_SOFTWARE");
   a04s_log("A04sMTLDevice initWithAcceleratorPort: %u (M5, %s)", port,
            soft && soft[0] == '1' ? "softpipe: RWA_SOFTWARE=1" : "Panfrost on the Mali-G52");
   self = [super initWithAcceleratorPort:port];
   if (!self)
      return nil;
   if (port)
      IORegistryEntryGetRegistryEntryID(port, &_a04sRegistry);
   if (![self rwa]) {
      /* fully initialised by now, so BGMTLDevice's own teardown runs, as Chlorophyll's plug-in does */
      a04s_log("A04sMTLDevice: no GPU behind the device (%s): none is made", [[self bgWhy] UTF8String]);
      [self release];
      return nil;
   }
   /* Chlorophyll's two process settings for CoreImage and QuartzCore (chlorophyll_plugin.m): harmless
    * in a probe, and already right when a client such as backboardd gets this device later (M6). */
   setenv("CI_USE_MTL_DAG_FOR_CIKL_SRC", "0", 0);
   setenv("CA_USE_CGTEXTUREDATA", "0", 0);
   a04s_log("A04sMTLDevice ready: %s, registryID %#llx", rwa_device_name([self rwa]),
            (unsigned long long)_a04sRegistry);
   return self;
}

/* M4's answers on the phone: featureProfile 4 is Apple1-3 (no tile shaders, imageblocks or raster
 * order groups); BGMTLDevice's supportsFamily: keeps Apple1-3 and Common1-2 as well. */
- (NSUInteger)featureProfile { return 4; }
- (const void *)targetDeviceInfo { return &a04s_target_info; }
- (NSString *)name
{
   const char *soft = getenv("RWA_SOFTWARE");
   return soft && soft[0] == '1' ? @"Mali-G52 (A04s Metal M5, softpipe)" : @"Mali-G52 (A04s Metal M5)";
}
- (NSString *)vendorName { return @"ARM"; }
- (NSString *)familyName { return @"Mali-G52"; }
- (NSString *)productName { return @"Galaxy A04s Mali-G52 MP1"; }
- (uint64_t)registryID { return _a04sRegistry ? _a04sRegistry : [super registryID]; }
- (BOOL)isLowPower { return YES; }
- (uint64_t)sharedMemorySize { return 1ull << 30; }
- (uint64_t)recommendedMaxWorkingSetSize { return 512ull << 20; }
/* M4 run 2's one unanswered selector; BGMTLDevice answers it with 1024 x 1024 x 64, the Adreno's. The
 * G52's Panfrost limit is what the pipeline reports (maxTotalThreadsPerThreadgroup); this is the
 * device-wide cap Metal's API documents for Apple3-class GPUs. */
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(512, 512, 512); }
- (NSUInteger)maxThreadgroupMemoryLength { return 16384; }

@end
