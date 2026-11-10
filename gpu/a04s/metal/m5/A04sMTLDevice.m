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
#include <sys/stat.h>
#include <time.h>

typedef mach_port_t a04s_io_registry_entry_t;
extern kern_return_t IORegistryEntryGetRegistryEntryID(a04s_io_registry_entry_t entry, uint64_t *id);

/* -[_MTLDevice targetDeviceInfo]: {u64, u32, const char *name}, as M4 answered it. */
static const struct { uint64_t a; uint32_t b; const char *name; } a04s_target_info = { 0, 0, "a04s-mali-g52" };

/* ---- A04s (Metal track M6): function constants -------------------------------------------------
 *
 * QuartzCore's Metal renderer on iOS 16.7 draws through ogl_metal_uber.metal, whose fragment and
 * vertex functions are specialised by some 58 function constants per pipeline
 * (-[MTLLibrary newFunctionWithDescriptor:error:] with constantValues). Metal specialises through
 * the device's compiler, which this device does not have, so here the library's two specialising
 * calls are taken over for libraries of this device: the function comes back unspecialised, with
 * the values kept beside it (since run 12 in a proxy of its own: see A04sSpecialisedFunction), and
 * the pipeline hands them to libhakiosair (rwa_set_function_constants), whose translator folds
 * them. Libraries of any other device are left to Metal. */

static char a04s_fc_key;   /* only with A04S_FC_PROXY=0 */

/* bytes of one MTLDataType value; 0 for a type a function constant cannot have */
static unsigned
a04s_type_size(NSUInteger t)
{
   unsigned comp = 0, base = 0;
   if (t >= MTLDataTypeFloat && t <= MTLDataTypeFloat4) { comp = 4; base = MTLDataTypeFloat; }
   else if (t >= MTLDataTypeHalf && t <= MTLDataTypeHalf4) { comp = 2; base = MTLDataTypeHalf; }
   else if (t >= MTLDataTypeInt && t <= MTLDataTypeInt4) { comp = 4; base = MTLDataTypeInt; }
   else if (t >= MTLDataTypeUInt && t <= MTLDataTypeUInt4) { comp = 4; base = MTLDataTypeUInt; }
   else if (t >= MTLDataTypeShort && t <= MTLDataTypeShort4) { comp = 2; base = MTLDataTypeShort; }
   else if (t >= MTLDataTypeUShort && t <= MTLDataTypeUShort4) { comp = 2; base = MTLDataTypeUShort; }
   else if (t >= MTLDataTypeChar && t <= MTLDataTypeChar4) { comp = 1; base = MTLDataTypeChar; }
   else if (t >= MTLDataTypeUChar && t <= MTLDataTypeUChar4) { comp = 1; base = MTLDataTypeUChar; }
   else if (t >= MTLDataTypeBool && t <= MTLDataTypeBool4) { comp = 1; base = MTLDataTypeBool; }
   else return 0;
   return comp * (unsigned)(t - base + 1);
}

/* The values of `cv` for the constants `fn` declares, as libhakiosair takes them, in an NSData
 * of struct rwa_constant; logged once per specialisation. */
static NSData *
a04s_constants_for(id fn, id cv, NSString *name)
{
   NSDictionary *decl = [fn respondsToSelector:@selector(functionConstantsDictionary)] ? [fn functionConstantsDictionary] : nil;
   SEL getv = sel_registerName("constantValueWithFunctionConstant:");
   if (!decl.count || ![cv respondsToSelector:getv]) {
      a04s_log("specialise %s: %lu constants declared, values %s", name.UTF8String, (unsigned long)decl.count,
               [cv respondsToSelector:getv] ? "readable" : "NOT readable (no constantValueWithFunctionConstant:)");
      return nil;
   }
   NSMutableData *out = [NSMutableData data];
   char shown[900] = "";
   unsigned given = 0;
   for (MTLFunctionConstant *c in decl.allValues) {
      const void *p = ((const void *(*)(id, SEL, id))objc_msgSend)(cv, getv, c);
      if (!p)
         continue;
      unsigned n = a04s_type_size(c.type);
      struct rwa_constant k = { (unsigned)c.index, 0 };
      memcpy(&k.bits, p, n < 8 ? n : 8);
      [out appendBytes:&k length:sizeof(k)];
      given++;
      if (k.bits && strlen(shown) < sizeof(shown) - 48) {
         char one[48];
         snprintf(one, sizeof(one), " %lu=%#llx", (unsigned long)c.index, (unsigned long long)k.bits);
         strlcat(shown, one, sizeof(shown));
      }
   }
   a04s_log("specialise %s: %lu declared, %u given; non-zero:%s", name.UTF8String, (unsigned long)decl.count, given,
            shown[0] ? shown : " none");
   return out;
}

static id
a04s_base_function(id lib, NSString *name)
{
   id fn = [lib newFunctionWithName:name];
   SEL internal = sel_registerName("newFunctionWithNameInternal:");
   if (!fn && [lib respondsToSelector:internal])
      fn = ((id (*)(id, SEL, id))objc_msgSend)(lib, internal, name);
   return fn;
}

static id (*a04s_orig_nfd)(id, SEL, id, NSError **);
static id (*a04s_orig_nfncv)(id, SEL, id, id, NSError **);

/* A04s (M6a run 12): one object per specialisation.
 *
 * Until run 11 the constants were an associated object on the function -newFunctionWithName: returned. Metal's library
 * keeps one function object per name and hands that same object back each time, so every specialisation of, say,
 * fixed_frag_lph_cpf was one object, and each new specialisation replaced the values of all the earlier ones.
 * CoreAnimation keeps its specialised functions and builds further pipelines from them later. Those pipelines got
 * whatever values came last. Run 11's scene 6 shows it: the tint over the backdrop panel (a plain colour, src-over)
 * was built from the solid-colour function after the textured, saturating composite had been specialised. So it
 * compiled as that composite, sampled the backdrop through texture coordinates CoreAnimation never meant to be read
 * (the composite's corners, in another vertex order) and drew bands at 45 degrees over the panel.
 *
 * So each specialisation is now its own object: a proxy that forwards everything to the library's function and carries
 * its own values. The device reaches a function only through messages (bitcodeData, name, functionConstantsDictionary),
 * and the proxy forwards those. Pipelines whose functions have no constants still get the plain function. */
@interface A04sSpecialisedFunction : NSProxy {
@public
   id _fn;
   NSData *_k;
}
@end

@implementation A04sSpecialisedFunction
- (id)forwardingTargetForSelector:(SEL)s { (void)s; return _fn; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [_fn methodSignatureForSelector:s]; }
- (void)forwardInvocation:(NSInvocation *)inv { [inv invokeWithTarget:_fn]; }
- (BOOL)respondsToSelector:(SEL)s { return [_fn respondsToSelector:s]; }
- (BOOL)isKindOfClass:(Class)c { return [_fn isKindOfClass:c]; }
- (BOOL)isMemberOfClass:(Class)c { return [_fn isMemberOfClass:c]; }
- (BOOL)conformsToProtocol:(Protocol *)p { return [_fn conformsToProtocol:p]; }
- (NSString *)description { return [_fn description]; }
- (NSString *)debugDescription { return [_fn debugDescription]; }
- (void)dealloc
{
   [_fn release];
   [_k release];
   [super dealloc];
}
@end

static id
a04s_specialise(id lib, NSString *name, id cv, NSError **error)
{
   id fn = a04s_base_function(lib, name);
   if (!fn) {
      a04s_log("specialise %s: the library has no such function", name.UTF8String);
      if (error)
         *error = [NSError errorWithDomain:@"MTLLibraryErrorDomain" code:5
                                  userInfo:@{ NSLocalizedDescriptionKey : [NSString stringWithFormat:@"no function %@", name] }];
      return nil;
   }
   NSData *k = cv ? a04s_constants_for(fn, cv, name) : nil;
   if (!k)
      return fn;
   /* A04S_FC_PROXY=0: the run 11 way (values on the shared object), should something reach into a proxy's internals */
   const char *px = getenv("A04S_FC_PROXY");
   if (px && px[0] == '0') {
      objc_setAssociatedObject(fn, &a04s_fc_key, k, OBJC_ASSOCIATION_RETAIN);
      return fn;
   }
   /* the caller owns what this returns (new...), and the proxy takes over the reference to fn */
   A04sSpecialisedFunction *p = [A04sSpecialisedFunction alloc];
   p->_fn = fn;
   p->_k = [k retain];
   return p;
}

static id
a04s_nfd(id lib, SEL cmd, MTLFunctionDescriptor *d, NSError **error)
{
   if (![[lib device] isKindOfClass:[BGMTLDevice class]])
      return a04s_orig_nfd(lib, cmd, d, error);
   return a04s_specialise(lib, d.name, d.constantValues, error);
}

static id
a04s_nfncv(id lib, SEL cmd, NSString *name, MTLFunctionConstantValues *cv, NSError **error)
{
   if (![[lib device] isKindOfClass:[BGMTLDevice class]])
      return a04s_orig_nfncv(lib, cmd, name, cv, error);
   return a04s_specialise(lib, name, cv, error);
}

/* the function's kept values to libhakiosair, for one stage (NULL clears it) */
static void
a04s_apply_constants(struct rwa_device *rwa, unsigned stage, id fn)
{
   NSData *k = !fn ? nil
             : object_getClass(fn) == [A04sSpecialisedFunction class] ? ((A04sSpecialisedFunction *)fn)->_k
                                                                   : objc_getAssociatedObject(fn, &a04s_fc_key);
   rwa_set_function_constants(rwa, stage, k.bytes, (unsigned)(k.length / sizeof(struct rwa_constant)));
}

static double
a04s_cpu_now(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
   return ts.tv_sec + ts.tv_nsec / 1e9;
}

@interface BGMTLDevice (A04sPrivate)
- (id)bgPipelineForFunction:(id)function descriptor:(id)descriptor error:(NSError **)error;
@end

@interface A04sMTLDevice : BGMTLDevice
@end

@implementation A04sMTLDevice {
   uint64_t _a04sRegistry;
}

+ (void)load
{
   Class lib = objc_getClass("_MTLLibrary");
   Method m = lib ? class_getInstanceMethod(lib, @selector(newFunctionWithDescriptor:error:)) : NULL;
   if (m)
      a04s_orig_nfd = (void *)method_setImplementation(m, (IMP)a04s_nfd);
   m = lib ? class_getInstanceMethod(lib, @selector(newFunctionWithName:constantValues:error:)) : NULL;
   if (m)
      a04s_orig_nfncv = (void *)method_setImplementation(m, (IMP)a04s_nfncv);
   a04s_log("A04sMTLDevice: function specialisation taken over for this device's libraries (%s, %s)",
            a04s_orig_nfd ? "newFunctionWithDescriptor:error:" : "-", a04s_orig_nfncv ? "newFunctionWithName:constantValues:error:" : "-");
}

/* Every pipeline: its constants to the library, and how long it took, in wall and CPU time
 * (M5 run 2 spent 40-70 s per pipeline: compiling, or waiting on the storage?). */
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error
{
   bg_lock();
   a04s_apply_constants([self rwa], RWA_STAGE_VERTEX, d.vertexFunction);
   a04s_apply_constants([self rwa], RWA_STAGE_FRAGMENT, d.fragmentFunction);
   double t = a04s_now(), c = a04s_cpu_now();
   NSError *e = nil;
   id p = [super newRenderPipelineStateWithDescriptor:d error:&e];
   a04s_log("render pipeline %s + %s: %s in %.2f s (CPU %.2f s)%s%s", d.vertexFunction.name.UTF8String ?: "-",
            d.fragmentFunction.name.UTF8String ?: "-", p ? "made" : "REFUSED", a04s_now() - t, a04s_cpu_now() - c,
            !p && e ? ": " : "", !p && e ? e.localizedDescription.UTF8String : "");
   a04s_apply_constants([self rwa], RWA_STAGE_VERTEX, nil);
   a04s_apply_constants([self rwa], RWA_STAGE_FRAGMENT, nil);
   if (p)
      rwa_shader_cache_sync([self rwa]);
   /* A04s (M6): QuartzCore ends its process when a render pipeline is refused ("Metal failed to build
    * render pipeline"), so a refused one is answered with a stand-in whose draws are skipped and logged
    * (bgmtl.m, BG_WORK_DRAW): one wrong layer instead of no picture at all. A04S_NULL_PIPELINES=0
    * returns nil and the error instead, as Metal would. */
   if (!p && !(getenv("A04S_NULL_PIPELINES") && getenv("A04S_NULL_PIPELINES")[0] == '0')) {
      BGMTLRenderPipeline *np = [[BGMTLRenderPipeline alloc] initWithDevice:self pipelineStateDescriptor:d];
      if (np) {
         np->_owner = self;
         snprintf(np->_names, sizeof(np->_names), "%s+%s", d.vertexFunction.name.UTF8String ?: "gen",
                  d.fragmentFunction.name.UTF8String ?: "-");
         a04s_log("render pipeline %s: a stand-in that draws nothing is handed back", np->_names);
         p = np;
         e = nil;
      }
   }
   if (error)
      *error = e;
   bg_unlock();
   return p;
}

- (id)bgPipelineForFunction:(id)function descriptor:(id)descriptor error:(NSError **)error
{
   bg_lock();
   a04s_apply_constants([self rwa], RWA_STAGE_COMPUTE, function);
   double t = a04s_now(), c = a04s_cpu_now();
   id p = [super bgPipelineForFunction:function descriptor:descriptor error:error];
   if (p)
      rwa_shader_cache_sync([self rwa]);
   a04s_log("compute pipeline %s: %s in %.2f s (CPU %.2f s)%s%s", [[function name] UTF8String] ?: "-",
            p ? "made" : "REFUSED", a04s_now() - t, a04s_cpu_now() - c, !p && error && *error ? ": " : "",
            !p && error && *error ? (*error).localizedDescription.UTF8String : "");
   a04s_apply_constants([self rwa], RWA_STAGE_COMPUTE, nil);
   bg_unlock();
   return p;
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
   const char *soft = getenv("RWA_SOFTWARE");
   a04s_log("A04sMTLDevice initWithAcceleratorPort: %u (M6, %s)", port,
            soft && soft[0] == '1' ? "softpipe: RWA_SOFTWARE=1" : "Panfrost on the Mali-G52");
   /* A04s (M6): Panfrost's compiled shaders kept across processes and boots (Mesa's disk cache),
    * in a folder every client of the device can write. */
   if (!getenv("MESA_SHADER_CACHE_DIR")) {
      mkdir("/private/var/a04s/mesa-cache", 0777);
      chmod("/private/var/a04s/mesa-cache", 0777);
      setenv("MESA_SHADER_CACHE_DIR", "/private/var/a04s/mesa-cache", 0);
   }
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
   /* A04s (M6a run 9): on Panfrost the cb-delta path (an unsized constant buffer at an offset that is
    * not 16-aligned, read through a delta table in constant buffer 15) draws nothing, while the copying
    * path draws right (r9-*-nodelta). The table pushes Panfrost's system-value buffer to a 17th slot,
    * past PAN_MAX_CONST_BUFFERS (16); that is the likely cause, not yet proven. Off by default for every
    * client of this device; RWA_CB_DELTA=1 turns it back on. libhakiosair reads it at each pipeline. */
   setenv("RWA_CB_DELTA", "0", 0);
   a04s_log("A04sMTLDevice ready: %s, registryID %#llx, shader cache %s (%s)", rwa_device_name([self rwa]),
            (unsigned long long)_a04sRegistry, rwa_shader_cache_sync([self rwa]) ? "on" : "OFF",
            getenv("MESA_SHADER_CACHE_DIR") ? getenv("MESA_SHADER_CACHE_DIR") : "no MESA_SHADER_CACHE_DIR");
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
