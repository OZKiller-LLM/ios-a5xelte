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
 *   2. backboardd (M6b) only behind its own switch and fallback guard, below (bb_refusal);
 *   3. only a process that asks: A04S_METAL=1 in its environment, or its name as a line of
 *      /private/var/a04s/metal.clients (as M4);
 *   4. the GPU: HeroGPU's service must exist, unless RWA_SOFTWARE=1 asks for softpipe.
 *
 * backboardd (M6b): CoreAnimation's render server composites on Metal when this gate gives it a
 * device, and on the 7c-6 OpenGL ES route (libheroeagl) otherwise. It gets one only if
 *   - /private/var/a04s/bb-metal.env (a drop file, KEY=VALUE lines) says A04S_BB_METAL=1. A missing
 *     or unreadable file, or any other value, keeps OpenGL ES: the switch fails closed;
 *   - this boot has no fallback recorded (bb-metal/fallback, written by the device's watchdog in
 *     a04s_bb.m when committed work stalls or every command buffer fails, or here);
 *   - backboardd has not already started on Metal A04S_BB_MAX_LAUNCHES times (default 3) this boot
 *     without a healthy minute: a crash loop falls back by itself. The device resets the count once
 *     it has composited for a while;
 *   - HeroGPU is there, and the launch count could be written (else the crash-loop guard is blind).
 * Its lines go to /private/var/a04s/bb-metal/bb-metal.log, and bb-metal/mode says which path the
 * running backboardd took ("<pid> metal|eagl <why>"). The other A04S_, BGMTL_, RWA_, MESA_ and CA_
 * settings of bb-metal.env are put into backboardd's environment when it takes the Metal path.
 * Refused in +allocWithZone:, before any object exists, as Chlorophyll's plug-in learnt to: an
 * object released before _MTLDevice's -init ran crashes in its -dealloc.
 *
 * Built with the iPhoneOS SDK against the device's Metal (_MTLDevice bound at load, -Wl,-U).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

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

/* ---- backboardd (M6b) ---------------------------------------------------------------------- */

#define BB_ENV "/private/var/a04s/bb-metal.env"
#define BB_DIR "/private/var/a04s/bb-metal"

static bool
a04s_herogpu_present(void)
{
   a04s_io_object_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("HeroGPU"));
   if (!s)
      return false;
   IOObjectRelease(s);
   return true;
}

/* Calls fn(key, value, arg) for each KEY=VALUE line of bb-metal.env (spaces around both trimmed,
 * '#' starts a comment). 0, or -errno when the file cannot be read. */
static int
bb_env_each(void (*fn)(const char *, const char *, void *), void *arg)
{
   FILE *f = fopen(BB_ENV, "r");
   if (!f)
      return -errno;
   char line[512];
   while (fgets(line, sizeof(line), f)) {
      line[strcspn(line, "#\r\n")] = 0;
      char *eq = strchr(line, '=');
      if (!eq)
         continue;
      *eq = 0;
      char *k = line, *v = eq + 1;
      while (*k == ' ' || *k == '\t') k++;
      while (*v == ' ' || *v == '\t') v++;
      for (char *e = k + strlen(k); e > k && (e[-1] == ' ' || e[-1] == '\t'); ) *--e = 0;
      for (char *e = v + strlen(v); e > v && (e[-1] == ' ' || e[-1] == '\t'); ) *--e = 0;
      if (*k)
         fn(k, v, arg);
   }
   fclose(f);
   return 0;
}

struct bb_lookup { const char *key; char value[128]; bool found; };

static void
bb_lookup_one(const char *k, const char *v, void *arg)
{
   struct bb_lookup *l = arg;
   if (!strcmp(k, l->key)) {
      strlcpy(l->value, v, sizeof(l->value));
      l->found = true;
   }
}

static void
bb_export_one(const char *k, const char *v, void *arg)
{
   (void)arg;
   static const char *prefixes[] = { "A04S_", "BGMTL_", "RWA_", "MESA_", "CA_" };
   for (unsigned i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++)
      if (!strncmp(k, prefixes[i], strlen(prefixes[i]))) {
         setenv(k, v, 1);
         return;
      }
}

/* This boot's identity: kern.bootsessionuuid, else the boot time. */
static void
bb_boot_id(char *out, size_t len)
{
   size_t n = len;
   if (sysctlbyname("kern.bootsessionuuid", out, &n, NULL, 0) == 0 && n > 1) {
      out[len - 1] = 0;
      return;
   }
   struct timeval tv = { 0, 0 };
   n = sizeof(tv);
   sysctlbyname("kern.boottime", &tv, &n, NULL, 0);
   snprintf(out, len, "boottime-%ld", (long)tv.tv_sec);
}

/* "<boot id> <rest>" from a state file of bb-metal/: true when it was written this boot. */
static bool
bb_state_this_boot(const char *name, const char *boot, char *rest, size_t len)
{
   char path[256], line[512];
   snprintf(path, sizeof(path), "%s/%s", BB_DIR, name);
   FILE *f = fopen(path, "r");
   if (!f)
      return false;
   bool ok = fgets(line, sizeof(line), f) != NULL;
   fclose(f);
   if (!ok)
      return false;
   line[strcspn(line, "\r\n")] = 0;
   size_t bl = strlen(boot);
   if (strncmp(line, boot, bl) || line[bl] != ' ')
      return false;
   strlcpy(rest, line + bl + 1, len);
   return true;
}

/* 0, or -errno */
static int
bb_state_write(const char *name, const char *boot, const char *rest)
{
   char path[256], line[512];
   snprintf(path, sizeof(path), "%s/%s", BB_DIR, name);
   int n = snprintf(line, sizeof(line), "%s %s\n", boot, rest);
   int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
   if (fd < 0)
      return -errno;
   int rc = write(fd, line, (size_t)n) == n ? 0 : -errno;
   fsync(fd);
   close(fd);
   return rc;
}

static void
bb_mode(const char *mode, const char *why)
{
   char path[256], line[512];
   snprintf(path, sizeof(path), "%s/mode", BB_DIR);
   int n = snprintf(line, sizeof(line), "%d %s %s\n", getpid(), mode, why);
   int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
   if (fd >= 0) {
      (void)!write(fd, line, (size_t)n);
      fsync(fd);
      close(fd);
   }
}

/* NULL: backboardd composites on Metal; else why it stays on OpenGL ES. Decided once per process. */
static const char *
bb_refusal(void)
{
   static char why[256];
   static int decided;
   if (decided)
      return why[0] ? why : NULL;
   decided = 1;
   setenv("A04S_METAL_LOG", BB_DIR "/bb-metal.log", 1);
   char boot[64], rest[256];
   bb_boot_id(boot, sizeof(boot));
   struct stat st;
   struct bb_lookup sw = { "A04S_BB_METAL", "", false }, mx = { "A04S_BB_MAX_LAUNCHES", "", false };
   int rc = bb_env_each(bb_lookup_one, &sw);
   if (rc == 0)
      bb_env_each(bb_lookup_one, &mx);
   unsigned max = mx.found && atoi(mx.value) > 0 ? (unsigned)atoi(mx.value) : 3, launches = 0;
   if (stat("/System/Library/Extensions/A04sMetal.bundle/a04smetal.off", &st) == 0)
      snprintf(why, sizeof(why), "a04smetal.off exists (kill switch)");
   else if (rc)
      snprintf(why, sizeof(why), "%s cannot be read (%s)", BB_ENV, strerror(-rc));
   else if (!sw.found)
      snprintf(why, sizeof(why), "no A04S_BB_METAL in %s", BB_ENV);
   else if (strcmp(sw.value, "1"))
      snprintf(why, sizeof(why), "A04S_BB_METAL=%s in %s", sw.value, BB_ENV);
   else if (bb_state_this_boot("fallback", boot, rest, sizeof(rest)))
      snprintf(why, sizeof(why), "fell back earlier this boot: %s", rest);
   else if ((launches = bb_state_this_boot("launches", boot, rest, sizeof(rest)) ? (unsigned)atoi(rest) : 0) >= max) {
      snprintf(why, sizeof(why), "%u launches on Metal this boot without a healthy minute (A04S_BB_MAX_LAUNCHES %u)",
               launches, max);
      bb_state_write("fallback", boot, why);
   } else if (!a04s_herogpu_present())
      snprintf(why, sizeof(why), "no HeroGPU service");
   else {
      char n[16];
      snprintf(n, sizeof(n), "%u", launches + 1);
      int wr = bb_state_write("launches", boot, n);
      if (wr)
         snprintf(why, sizeof(why), "cannot keep the launch count in %s (%s)", BB_DIR, strerror(-wr));
   }
   if (why[0]) {
      a04s_log("A04sMetal: backboardd[%d]: OpenGL ES path: %s", getpid(), why);
      bb_mode("eagl", why);
      return why;
   }
   bb_env_each(bb_export_one, NULL);
   char n[16];
   snprintf(n, sizeof(n), "%u", launches + 1);
   setenv("A04S_BB_LAUNCH", n, 1);
   setenv("A04S_BB_BOOT", boot, 1);
   char what[128];
   snprintf(what, sizeof(what), "launch %u of at most %u this boot (boot %s)", launches + 1, max, boot);
   a04s_log("A04sMetal: backboardd[%d]: Metal path: %s, uid %d", getpid(), what, getuid());
   bb_mode("metal", what);
   return NULL;
}

/* NULL when this process may have a device, else why not. Nothing is logged for a process that did
 * not ask (gate 3), so SpringBoard and every app stay silent and unchanged. */
static const char *
a04s_refusal(bool *asked)
{
   const char *name = getprogname() ? getprogname() : "?";
   if (!strcmp(name, "backboardd")) {
      *asked = false;   /* bb_refusal logs its own decision */
      return bb_refusal();
   }
   const char *e = getenv("A04S_METAL");
   *asked = (e && !strcmp(e, "1")) || a04s_listed("/private/var/a04s/metal.clients", name);
   struct stat st;
   if (stat("/System/Library/Extensions/A04sMetal.bundle/a04smetal.off", &st) == 0)
      return "a04smetal.off exists (kill switch)";
   if (!*asked)
      return "not asked for (A04S_METAL=1 or /private/var/a04s/metal.clients)";
   const char *soft = getenv("RWA_SOFTWARE");
   if (!(soft && soft[0] == '1') && !a04s_herogpu_present())
      return "no HeroGPU service";
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
   if (!impl) {
      if (!strcmp(getprogname(), "backboardd"))
         bb_mode("eagl", "the device library did not load (see bb-metal.log)");
      return nil;
   }
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
