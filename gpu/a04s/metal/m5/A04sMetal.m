/*
 * Galaxy A04s, Metal track M5: A04sMetal.bundle's executable, the GATE in front of the Metal device.
 *
 * Metal loads this bundle in every process that asks for a device (MTLRegisterDevices: HeroGPU's
 * IOAcceleratorES names it with a04smetal=1) and does [[A04sMetalDevice alloc]
 * initWithAcceleratorPort:]. So this executable stays as small as M4's, and the device itself --
 * Mesa, Panfrost, the AIR front end, Chlorophyll's Metal classes -- is a separate library beside it
 * (libA04sMetalDevice.dylib, with libhakiosair.dylib and libdrm.2.dylib), loaded only in a process
 * that is allowed a device. Everywhere else +alloc answers nil, Metal skips a nil device (a cbz
 * before MTLAddDevice in iOS 16.7's Metal), and the process runs as it did before M4.
 *
 * The gates, each failing closed (no device):
 *   1. a kill switch: /System/Library/Extensions/A04sMetal.bundle/a04smetal.off exists;
 *   2. backboardd never gets one in M5: its compositing stays on the 7c-6 OpenGL ES route;
 *   3. only a process that asks: A04S_METAL=1 in its environment, or its name as a line of
 *      /private/var/a04s/metal.clients (as M4);
 *   4. the GPU: HeroGPU's service must exist, unless RWA_SOFTWARE=1 asks for softpipe.
 * Refused in +allocWithZone:, before any object exists, as Chlorophyll's plug-in learnt to: an
 * object released before _MTLDevice's -init ran crashes in its -dealloc.
 *
 * Built with the iPhoneOS SDK against the device's Metal (_MTLDevice bound at load, -Wl,-U).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <libgen.h>
#include <sys/stat.h>

#include "a04s_metal_log.h"

typedef mach_port_t a04s_io_object_t;
extern const mach_port_t kIOMainPortDefault;
extern CFMutableDictionaryRef IOServiceMatching(const char *name);
extern a04s_io_object_t IOServiceGetMatchingService(mach_port_t main, CFDictionaryRef matching);
extern kern_return_t IOObjectRelease(a04s_io_object_t object);

@interface _MTLDevice : NSObject
@end

@interface A04sMetalDevice : _MTLDevice
@end

static int
a04s_listed(const char *path, const char *name)
{
   FILE *f = fopen(path, "r");
   if (!f)
      return 0;
   char line[256];
   int hit = 0;
   while (!hit && fgets(line, sizeof(line), f)) {
      line[strcspn(line, "\r\n")] = 0;
      hit = line[0] && !strcmp(line, name);
   }
   fclose(f);
   return hit;
}

/* NULL when this process may have a device, else why not. Nothing is logged for a process that did
 * not ask (gate 3), so backboardd, SpringBoard and every app stay silent and unchanged. */
static const char *
a04s_refusal(bool *asked)
{
   const char *name = getprogname() ? getprogname() : "?";
   const char *e = getenv("A04S_METAL");
   *asked = (e && !strcmp(e, "1")) || a04s_listed("/private/var/a04s/metal.clients", name);
   struct stat st;
   if (stat("/System/Library/Extensions/A04sMetal.bundle/a04smetal.off", &st) == 0)
      return "a04smetal.off exists (kill switch)";
   if (!strcmp(name, "backboardd"))
      return "backboardd stays on the OpenGL ES route in M5";
   if (!*asked)
      return "not asked for (A04S_METAL=1 or /private/var/a04s/metal.clients)";
   const char *soft = getenv("RWA_SOFTWARE");
   if (!(soft && soft[0] == '1')) {
      a04s_io_object_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("HeroGPU"));
      if (!s)
         return "no HeroGPU service";
      IOObjectRelease(s);
   }
   return NULL;
}

/* The device library beside this executable, loaded once; its class, or Nil. */
static Class
a04s_device_class(void)
{
   static Class cls;
   static bool tried;
   if (tried)
      return cls;
   tried = true;
   Dl_info info;
   if (!dladdr((const void *)a04s_device_class, &info) || !info.dli_fname) {
      a04s_log("A04sMetal: where is this bundle? (dladdr failed)");
      return Nil;
   }
   char dir[PATH_MAX], path[PATH_MAX];
   strlcpy(dir, info.dli_fname, sizeof(dir));
   snprintf(path, sizeof(path), "%s/libA04sMetalDevice.dylib", dirname(dir));
   void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
   if (!h) {
      a04s_log("A04sMetal: dlopen %s: %s", path, dlerror());
      return Nil;
   }
   cls = objc_getClass("A04sMTLDevice");
   a04s_log("A04sMetal: loaded %s, class A04sMTLDevice %s", path, cls ? "found" : "MISSING");
   return cls;
}

@implementation A04sMetalDevice

/* As M4: the protocols MTLAddDevice asserts, declared on the class Metal names too (the device
 * handed out, A04sMTLDevice, gets them from BGMTLDevice's own +load). */
+ (void)load
{
   Protocol *spi = objc_getProtocol("MTLDeviceSPI");
   if (spi)
      class_addProtocol(self, spi);
   Protocol *pub = objc_getProtocol("MTLDevice");
   if (pub)
      class_addProtocol(self, pub);
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
   if (self != [A04sMetalDevice class])
      return [super allocWithZone:zone];
   bool asked = false;
   const char *why = a04s_refusal(&asked);
   if (why) {
      if (asked)
         a04s_log("A04sMetal: %s[%d]: no device: %s", getprogname(), getpid(), why);
      return nil;
   }
   Class impl = a04s_device_class();
   if (!impl)
      return nil;
   a04s_log("A04sMetal: %s[%d]: a device of class A04sMTLDevice", getprogname(), getpid());
   return [impl allocWithZone:zone];
}

+ (instancetype)alloc
{
   return [self allocWithZone:NULL];
}

/* Never reached for an instance of this class (+alloc hands out A04sMTLDevice or nil); here so
 * that the class Metal checks still answers the selector it sends. */
- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
   (void)port;
   return nil;
}

@end
