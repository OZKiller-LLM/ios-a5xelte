/*
 * libdrm stand-in for Mesa's Panfrost on the Galaxy S7's iOS: the panfrost
 * DRM ioctls Mesa issues, answered with the kernel's HeroGPU IOKit user
 * client (iokit/Kernel/arm/HeroGPU.cpp). Built as libdrm.2.dylib; Mesa
 * links it in place of the real libdrm (headers from libdrm 2.4.124).
 *
 * One GPU, one connection per process. The "fd" Mesa holds is a real file
 * descriptor on /dev/null (Mesa dups and closes it); every call is ours.
 * BO mmap goes through herodrm_mmap() (Mesa's pan_kmod_bo_mmap is patched
 * to call it on Apple): MMAP_BO hands out handle << 32 as the offset.
 * Kernels up to v63: Submit is synchronous in the kernel, so syncobjs are
 * always signaled. From v64 (A04s 7c-7a) the kernel has a scheduler, and
 * submits, BO waits and syncobjs go to it (selectors 8-15; see "the kernel's
 * scheduler" below). HERO_SCHED=0 keeps the synchronous path.
 *
 * Environment: HERODRM_HEAP_MB caps the tiler heap BO (default 32; the
 * kernel buffers are wired, Mesa asks for 128 MiB), HERODRM_DEBUG=1 logs
 * every call to the kernel log.
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <xf86drm.h>
#include "drm-uapi/panfrost_drm.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>

/* IOKit, declared here: the iOS SDK ships IOKit without its headers. */
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef mach_port_t io_connect_t;
extern const mach_port_t kIOMainPortDefault;
CFMutableDictionaryRef IOServiceMatching(const char *name);
io_service_t IOServiceGetMatchingService(mach_port_t main, CFDictionaryRef matching);
kern_return_t IOServiceOpen(io_service_t service, task_port_t task, uint32_t type,
                            io_connect_t *connect);
kern_return_t IOObjectRelease(io_object_t object);
kern_return_t IOConnectCallMethod(io_connect_t connection, uint32_t selector,
                                  const uint64_t *input, uint32_t inputCnt,
                                  const void *inputStruct, size_t inputStructCnt,
                                  uint64_t *output, uint32_t *outputCnt,
                                  void *outputStruct, size_t *outputStructCnt);

#define EXPORT __attribute__((visibility("default")))

enum { SEL_PARAM, SEL_CREATE, SEL_FREE, SEL_MAP, SEL_SUBMIT, SEL_LOG, SEL_SURFACE_BO, SEL_SYNC_BO,
       /* v64 (A04s 7c-7a): a structure input (the Linux struct, then its u32 arrays), scalar outputs */
       SEL_PAN_SUBMIT, SEL_PAN_WAIT_BO, SEL_PAN_MADVISE, SEL_SYNCOBJ_CREATE, SEL_SYNCOBJ_DESTROY,
       SEL_SYNCOBJ_WAIT, SEL_SYNCOBJ_RESET, SEL_SYNCOBJ_SIGNAL };

#define KR_BAD_ARGUMENT 0xe00002c2u     /* kIOReturnBadArgument */
#define KR_UNSUPPORTED  0xe00002c7u     /* kIOReturnUnsupported: no scheduler (v63, or a04sgpu_sched=0) */
#define KR_TIMEOUT      0xe00002d6u     /* kIOReturnTimeout */
#define KR_ABORTED      0xe00002ebu     /* kIOReturnAborted: the waiting thread was interrupted */

static int sched = -1;                  /* the kernel's scheduler: -1 not asked yet, 0 no, 1 yes */
/* BOs per submit: v65 (7c-7b) takes 4096, v64 1024. A larger submit on v64 fails in the kernel with kIOReturnBadArgument,
 * logged with its count below; HERODRM_MAX_SUBMIT_BOS=1024 refuses it here instead. */
static unsigned max_submit_bos = 4096;
static void sched_probe(void);

#define MAX_BOS 4096

struct hbo {
   uint64_t va, size;
   uint64_t cpu;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static io_connect_t conn;
static struct hbo bos[MAX_BOS + 1];     /* by kernel handle */
#define MAX_PRIME 256
static struct { int fd; uint32_t handle; } primes[MAX_PRIME];  /* imported surfaces' stand-in descriptors */
static int debug = -1;
static uint64_t submits, faults;

/* Where the time goes, logged every 5 s while the GPU is used: submits (GPU
 * time as the kernel measured it, and the whole call) and BO creation (the
 * kernel zeroes, cleans and maps every new buffer). */
static struct {
   uint64_t start_ns, submits, gpu_us, submit_ns, creates, create_bytes, create_ns, frees;
   uint64_t fences_made, fence_ns, waits, wait_ns;  /* v64: kernel syncobjs made (and the calls' time), syncobj waits */
} st;
static unsigned fences_live;            /* v64: kernel syncobjs this process holds now */

EXPORT void herodrm_log(const char *fmt, ...);

static uint64_t
now_ns(void)
{
   return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void
stats_tick(uint64_t t)
{
   if (!st.start_ns) {
      st.start_ns = t;
      return;
   }
   uint64_t wall = t - st.start_ns;
   if (wall < 5000000000ull)
      return;
   herodrm_log("stats %.1f s: %llu submits, GPU %.1f ms (%.0f%%), submit calls %.1f ms | "
               "%llu new BOs %.1f MB in %.1f ms | %llu freed",
               wall / 1e9, (unsigned long long)st.submits, st.gpu_us / 1e3,
               100.0 * st.gpu_us * 1e3 / wall, st.submit_ns / 1e6,
               (unsigned long long)st.creates, st.create_bytes / 1048576.0, st.create_ns / 1e6,
               (unsigned long long)st.frees);
   if (sched == 1)
      herodrm_log("stats (scheduler): %llu fences made in %.1f ms, %u live | %llu syncobj waits, %.1f ms waiting",
                  (unsigned long long)st.fences_made, st.fence_ns / 1e6, fences_live,
                  (unsigned long long)st.waits, st.wait_ns / 1e6);
   memset(&st, 0, sizeof(st));
   st.start_ns = t;
}

static uint32_t
call(uint32_t sel, const uint64_t *in, uint32_t nin, uint64_t *out, uint32_t nout)
{
   uint32_t n = nout;
   kern_return_t kr = IOConnectCallMethod(conn, sel, in, nin, NULL, 0, out, &n, NULL, NULL);
   return kr;
}

static int connect_gpu(void);

EXPORT void
herodrm_log(const char *fmt, ...)
{
   char line[1024];
   va_list ap;
   va_start(ap, fmt);
   int n = vsnprintf(line, sizeof(line), fmt, ap);
   va_end(ap);
   if (n < 0)
      return;
   if (n >= (int)sizeof(line))
      n = sizeof(line) - 1;
   if (!conn)
      connect_gpu();    /* a test's first lines; not under the lock */
   if (conn)
      IOConnectCallMethod(conn, SEL_LOG, NULL, 0, line, n, NULL, NULL, NULL, NULL);
   fprintf(stderr, "herodrm: %s\n", line);
}

#define DBG(...) do { if (debug > 0) herodrm_log(__VA_ARGS__); } while (0)

static int
fail(int e)
{
   errno = e;
   return -1;
}

/* Open the HeroGPU user client once; 0 on success. */
static int
connect_gpu(void)
{
   if (conn)
      return 0;
   if (debug < 0) {
      const char *d = getenv("HERODRM_DEBUG");
      debug = d && *d == '1';
   }
   io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("HeroGPU"));
   if (!svc)
      return -1;
   kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
   IOObjectRelease(svc);
   if (kr != KERN_SUCCESS) {
      conn = 0;
      return -1;
   }
   DBG("connected");
   sched_probe();
   return 0;
}

EXPORT int
drmOpenWithType(const char *name, const char *busid, int type)
{
   (void)busid;
   (void)type;
   if (name && strcmp(name, "panfrost") != 0)
      return fail(ENODEV);
   pthread_mutex_lock(&lock);
   int r = connect_gpu();
   pthread_mutex_unlock(&lock);
   if (r)
      return fail(ENODEV);
   return open("/dev/null", O_RDWR | O_CLOEXEC);
}

EXPORT int
drmOpen(const char *name, const char *busid)
{
   return drmOpenWithType(name, busid, 0);
}

EXPORT int
drmClose(int fd)
{
   return close(fd);
}

EXPORT drmVersionPtr
drmGetVersion(int fd)
{
   (void)fd;
   drmVersionPtr v = calloc(1, sizeof(*v));
   if (!v)
      return NULL;
   /* 1.2: HEAP/NOEXEC BOs and MADVISE; no timestamp query (1.3). */
   v->version_major = 1;
   v->version_minor = 2;
   v->name = strdup("panfrost");
   v->name_len = 8;
   v->date = strdup("20251025");
   v->date_len = 8;
   v->desc = strdup("HeroGPU Mali (Galaxy S7 T880, Galaxy A04s G52)");
   v->desc_len = (int)strlen(v->desc);
   return v;
}

EXPORT void
drmFreeVersion(drmVersionPtr v)
{
   if (!v)
      return;
   free(v->name);
   free(v->date);
   free(v->desc);
   free(v);
}

EXPORT int
drmGetCap(int fd, uint64_t capability, uint64_t *value)
{
   (void)fd;
   (void)capability;
   *value = 0;
   return 0;
}

static unsigned
heap_cap(void)
{
   const char *s = getenv("HERODRM_HEAP_MB");
   unsigned mb = s ? (unsigned)atoi(s) : 32;
   return (mb ? mb : 32) << 20;
}

static int
create_bo(struct drm_panfrost_create_bo *req)
{
   uint64_t size = req->size;
   if (req->flags & PANFROST_BO_HEAP && size > heap_cap())
      size = heap_cap();
   uint64_t in = size, out[3] = {0};
   uint64_t t0 = now_ns();
   uint32_t kr = call(SEL_CREATE, &in, 1, out, 3);
   uint64_t t1 = now_ns();
   st.creates++;
   st.create_bytes += size;
   st.create_ns += t1 - t0;
   stats_tick(t1);
   if (kr || out[0] == 0 || out[0] > MAX_BOS) {
      herodrm_log("CREATE_BO %llu bytes (flags 0x%x) failed: 0x%x",
                  (unsigned long long)size, req->flags, kr);
      return fail(ENOMEM);
   }
   req->handle = (uint32_t)out[0];
   req->offset = out[1];
   /* Mesa takes the BO's size from here (pan_kmod_bo_init): a capped heap
    * must not be described to the tiler as the size asked for. */
   req->size = (uint32_t)out[2];
   bos[out[0]] = (struct hbo){ .va = out[1], .size = out[2] };
   DBG("CREATE_BO %u: %llu bytes at 0x%llx flags 0x%x", req->handle,
       (unsigned long long)out[2], (unsigned long long)out[1], req->flags);
   return 0;
}

static struct hbo *
lookup(uint32_t handle)
{
   return handle && handle <= MAX_BOS && bos[handle].va ? &bos[handle] : NULL;
}

static bool async_on;
static uint64_t bo_last_job[MAX_BOS + 1];       /* by handle: the count of queued jobs when the last one naming it went on */
static void queue_drain(void);
static void bo_wait(uint32_t handle);

static int
free_bo(uint32_t handle)
{
   if (!lookup(handle))
      return fail(EINVAL);
   bo_wait(handle);
   bo_last_job[handle] = 0;
   uint64_t in = handle;
   call(SEL_FREE, &in, 1, NULL, 0);
   st.frees++;
   memset(&bos[handle], 0, sizeof(bos[handle]));
   for (int i = 0; i < MAX_PRIME; i++)
      if (primes[i].handle == handle) {      /* an imported surface: its stand-in descriptor goes too */
         close(primes[i].fd);
         primes[i].handle = 0;
      }
   DBG("FREE_BO %u", handle);
   return 0;
}

/* CPU address of GPU VA va (mapping the BO if needed), or NULL. */
static const uint8_t *
gpu_to_cpu(uint64_t va, uint64_t len)
{
   for (unsigned h = 1; h <= MAX_BOS; h++) {
      struct hbo *bo = &bos[h];
      if (!bo->va || va < bo->va || va + len > bo->va + bo->size)
         continue;
      if (!bo->cpu) {
         uint64_t in = h, out = 0;
         if (call(SEL_MAP, &in, 1, &out, 1) == 0)
            bo->cpu = out;
      }
      return bo->cpu ? (const uint8_t *)(uintptr_t)(bo->cpu + (va - bo->va)) : NULL;
   }
   return NULL;
}

static void
dump_words(const char *what, uint64_t va, unsigned words)
{
   const uint32_t *p = (const uint32_t *)gpu_to_cpu(va, words * 4);
   if (!p) {
      herodrm_log("  %s 0x%llx: not in any BO", what, (unsigned long long)va);
      return;
   }
   for (unsigned i = 0; i < words; i += 8)
      herodrm_log("  %s 0x%llx: %08x %08x %08x %08x %08x %08x %08x %08x", what,
                  (unsigned long long)(va + i * 4), p[i], p[i + 1], p[i + 2], p[i + 3],
                  p[i + 4], p[i + 5], p[i + 6], p[i + 7]);
}

/* After a fault: every job of the chain, and the payload and fault pointer
 * of the ones that did not finish. Called with the lock held. */
static void
dump_chain(uint64_t jc)
{
   static const char *types[] = { "?", "null", "write_value", "cache_flush", "compute",
                                  "vertex", "geometry", "tiler", "fused", "fragment" };
   for (unsigned n = 0; jc && n < 16; n++) {
      const uint8_t *h = gpu_to_cpu(jc, 32);
      if (!h) {
         herodrm_log("  job 0x%llx: not in any BO", (unsigned long long)jc);
         return;
      }
      uint32_t status = *(const uint32_t *)h;
      uint64_t fault = *(const uint64_t *)(h + 8), next = *(const uint64_t *)(h + 24);
      unsigned type = (h[16] >> 1) & 0x7f;
      herodrm_log("  job 0x%llx %s: status 0x%x first_incomplete %u fault_ptr 0x%llx "
                  "index %u deps %u,%u next 0x%llx",
                  (unsigned long long)jc, type < 10 ? types[type] : "?", status,
                  *(const uint32_t *)(h + 4), (unsigned long long)fault,
                  *(const uint16_t *)(h + 18), *(const uint16_t *)(h + 20),
                  *(const uint16_t *)(h + 22), (unsigned long long)next);
      if (status != 1) {        /* not DONE */
         dump_words("payload", jc + 32, 48);
         if (fault)
            dump_words("at fault_ptr", fault & ~31ull, 16);
      }
      jc = h[16] & 1 ? next : (uint32_t)*(const uint32_t *)(h + 24);
   }
}

static int
submit_now(uint64_t jc, uint64_t js)
{
   uint64_t in[2] = { jc, js }, out[2] = {0};
   uint64_t t0 = now_ns();
   uint32_t kr = call(SEL_SUBMIT, in, 2, out, 2);
   uint64_t t1 = now_ns();
   submits++;
   st.submits++;
   st.gpu_us += out[1];
   st.submit_ns += t1 - t0;
   stats_tick(t1);
   if (kr || out[0]) {
      faults++;
      if (faults <= 16 || debug > 0)
         herodrm_log("SUBMIT #%llu jc 0x%llx js %llu: kr 0x%x status 0x%llx (%llu us)",
                     (unsigned long long)submits, (unsigned long long)jc,
                     (unsigned long long)js, kr, (unsigned long long)out[0],
                     (unsigned long long)out[1]);
      if (faults <= 2 && !async_on)
         dump_chain(jc);        /* (the BO table is the caller's, under its lock) */
   } else {
      DBG("SUBMIT #%llu jc 0x%llx js %llu: %llu us", (unsigned long long)submits,
          (unsigned long long)jc, (unsigned long long)js, (unsigned long long)out[1]);
   }
   /* A faulting job is reported, not fatal: Mesa would abort on an error. */
   return kr ? fail(EIO) : 0;
}

/*
 * HERO_ASYNC=1: a submit goes on a queue and returns; a thread of its own
 * makes the kernel's call, which lasts as long as the job. In order, so one
 * job's results are there for the next, as the kernel's synchronous submits
 * always had it. A wait on a BO, or freeing one, waits for the last job that
 * named it (a submit lists its BOs); a wait on a syncobj or cleaning a
 * surface's caches drains the queue. The worker takes no lock of the
 * callers', so they may wait with theirs held.
 */
#define QUEUE_SIZE 64
static struct { uint64_t jc, js; } queue[QUEUE_SIZE];
static uint64_t queued, finished;       /* counts; queue[n % QUEUE_SIZE] */
static pthread_mutex_t qlock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t qwork = PTHREAD_COND_INITIALIZER, qdone = PTHREAD_COND_INITIALIZER;

static void *
queue_worker(void *arg)
{
   (void)arg;
   pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
   pthread_mutex_lock(&qlock);
   for (;;) {
      while (finished == queued)
         pthread_cond_wait(&qwork, &qlock);
      uint64_t jc = queue[finished % QUEUE_SIZE].jc, js = queue[finished % QUEUE_SIZE].js;
      pthread_mutex_unlock(&qlock);
      submit_now(jc, js);
      pthread_mutex_lock(&qlock);
      finished++;
      pthread_cond_broadcast(&qdone);
   }
   return NULL;
}

static void
queue_drain(void)
{
   if (!async_on)
      return;
   pthread_mutex_lock(&qlock);
   while (finished != queued)
      pthread_cond_wait(&qdone, &qlock);
   pthread_mutex_unlock(&qlock);
}

/* Is the last job that named this BO still queued or running? */
static bool
bo_busy(uint32_t handle)
{
   if (!async_on || !handle || handle > MAX_BOS)
      return false;
   pthread_mutex_lock(&qlock);
   bool busy = finished < bo_last_job[handle];
   pthread_mutex_unlock(&qlock);
   return busy;
}

static void
bo_wait(uint32_t handle)
{
   if (!async_on || !handle || handle > MAX_BOS)
      return;
   pthread_mutex_lock(&qlock);
   while (finished < bo_last_job[handle])
      pthread_cond_wait(&qdone, &qlock);
   pthread_mutex_unlock(&qlock);
}

/*
 * ---- The kernel's scheduler (v64, A04s 7c-7a; this side is 7c-7d) ----
 *
 * Selectors 8-15 take the Linux struct from Mesa 25.0.7 with its u32 arrays
 * inline after it (exact size) and answer in scalars. A submit returns at
 * once; the kernel holds every BO it lists until the job ends, and orders jobs
 * by the BOs they share (all count as written, as on Linux). Translated here:
 *
 * - timeouts: Mesa gives SyncobjWait an absolute CLOCK_MONOTONIC time, the
 *   kernel takes a relative one (INT64_MAX is forever both ways). WAIT_BO only
 *   ever gets 0 or INT64_MAX from Mesa, which mean the same either way.
 * - errno: a WAIT_BO timeout is ETIMEDOUT (Mesa asserts ETIMEDOUT or EBUSY),
 *   a SyncobjWait timeout ETIME, as on Linux.
 * - sync files: Mesa makes each pipe fence by exporting its context's syncobj
 *   to a sync file and importing that into a new syncobj, and the kernel has
 *   neither sync files nor transfer. So Mesa's syncobj handles are ours: each
 *   points at a `kfence`, a kernel syncobj holding one job's fence, shared by
 *   reference. A submit with an out_sync makes a new kernel syncobj for the job
 *   and points the handle at it; export, import and transfer copy references.
 *   A sync file is a /dev/null descriptor that stands for one kfence.
 * - waits drop the lock: other threads keep submitting meanwhile.
 */
#define MAX_IN_SYNCS 32
#define MAX_USYNC 4096
#define MAX_SYNCFILE 256

struct kfence {
   uint32_t ksync;      /* the kernel's syncobj, holding the job's fence */
   uint32_t refs;
};
static struct kfence signaled_fence;     /* "already signaled": no kernel object (SIGNALED creates, Signal) */
#define SIGNALED (&signaled_fence)

static struct kfence *usync[MAX_USYNC + 1];  /* Mesa's syncobj handle n: NULL = no fence yet */
static bool usync_used[MAX_USYNC + 1];
static struct { int fd; struct kfence *f; } syncfiles[MAX_SYNCFILE];
static unsigned syncfile_next;

static uint32_t
scall(uint32_t sel, const void *in, size_t size, uint64_t *out, uint32_t nout)
{
   uint32_t n = nout;
   return IOConnectCallMethod(conn, sel, NULL, 0, in, size, out, out ? &n : NULL, NULL, NULL);
}

static void
sched_probe(void)
{
   const char *e = getenv("HERO_SCHED"), *m = getenv("HERODRM_MAX_SUBMIT_BOS");
   if (m && atoi(m) > 0)
      max_submit_bos = (unsigned)atoi(m);
   uint32_t kr = 0;
   if (e && *e == '0') {
      sched = 0;
   } else {
      /* a syncobj made and destroyed: v63, and v64 with a04sgpu_sched=0, answer kIOReturnUnsupported */
      struct { uint32_t handle, flags; } c = { 0, 0 };
      uint64_t h = 0;
      kr = scall(SEL_SYNCOBJ_CREATE, &c, sizeof(c), &h, 1);
      sched = kr == 0;
      if (sched) {
         struct { uint32_t handle, pad; } d = { (uint32_t)h, 0 };
         scall(SEL_SYNCOBJ_DESTROY, &d, sizeof(d), NULL, 0);
      }
   }
   herodrm_log("submits: %s", sched ? "the kernel's scheduler (selectors 8-15)"
               : e && *e == '0' ? "synchronous (HERO_SCHED=0)"
               : kr == KR_UNSUPPORTED ? "synchronous (the kernel has no scheduler)"
                                      : "synchronous (the scheduler probe failed)");
   if (!sched && kr && kr != KR_UNSUPPORTED)
      herodrm_log("scheduler probe: SyncobjCreate returned 0x%x", kr);
}

static int64_t
relative_ns(int64_t absolute)
{
   if (absolute == INT64_MAX)
      return INT64_MAX;
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);    /* Mesa's os_time_get_nano: timespec_get(TIME_MONOTONIC) */
   int64_t now = (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
   return absolute > now ? absolute - now : 0;
}

static struct kfence *
fence_ref(struct kfence *f)
{
   if (f && f != SIGNALED)
      f->refs++;
   return f;
}

static void
fence_unref(struct kfence *f)
{
   if (!f || f == SIGNALED || --f->refs)
      return;
   struct { uint32_t handle, pad; } d = { f->ksync, 0 };
   scall(SEL_SYNCOBJ_DESTROY, &d, sizeof(d), NULL, 0);
   fences_live--;
   free(f);
}

/* a kernel syncobj with no fence yet, for one job's out_sync */
static struct kfence *
fence_new(void)
{
   struct { uint32_t handle, flags; } c = { 0, 0 };
   uint64_t h = 0;
   uint64_t t0 = now_ns();
   uint32_t kr = scall(SEL_SYNCOBJ_CREATE, &c, sizeof(c), &h, 1);
   st.fence_ns += now_ns() - t0;
   struct kfence *f = kr == 0 ? malloc(sizeof(*f)) : NULL;
   if (!f) {
      static unsigned told;
      if (told++ < 8)
         herodrm_log("SyncobjCreate failed: 0x%x (%u live)", kr, fences_live);
      if (kr == 0) {
         struct { uint32_t handle, pad; } d = { (uint32_t)h, 0 };
         scall(SEL_SYNCOBJ_DESTROY, &d, sizeof(d), NULL, 0);
      }
      return NULL;
   }
   *f = (struct kfence){ .ksync = (uint32_t)h, .refs = 1 };
   fences_live++;
   st.fences_made++;
   return f;
}

static bool
usync_valid(uint32_t handle)
{
   return handle && handle <= MAX_USYNC && usync_used[handle];
}

/* points Mesa's handle at f (a reference the caller gives up) */
static void
usync_set(uint32_t handle, struct kfence *f)
{
   struct kfence *old = usync[handle];
   usync[handle] = f;
   fence_unref(old);
}

/* WAIT_BO and selector 7's wait; called without the lock. 0, or the kernel's return. */
static uint32_t
sched_wait_bo_call(uint32_t handle, int64_t timeout_ns)
{
   struct { uint32_t handle, pad; int64_t timeout_ns; } w = { handle, 0, timeout_ns };
   uint32_t kr;
   do
      kr = scall(SEL_PAN_WAIT_BO, &w, sizeof(w), NULL, 0);
   while (kr == KR_ABORTED);
   return kr;
}

/* DRM_IOCTL_PANFROST_WAIT_BO; called with the lock held, which it drops while it waits */
static int
sched_wait_bo(struct drm_panfrost_wait_bo *w)
{
   int64_t t = w->timeout_ns;
   if (t != 0 && t != INT64_MAX)
      t = relative_ns(t);     /* Linux takes it as absolute */
   pthread_mutex_unlock(&lock);
   uint32_t kr = sched_wait_bo_call(w->handle, t);
   pthread_mutex_lock(&lock);
   if (kr == 0)
      return 0;
   if (kr == KR_TIMEOUT)
      return fail(ETIMEDOUT);
   herodrm_log("WAIT_BO %u: 0x%x", w->handle, kr);
   return fail(EINVAL);
}

static int
sched_madvise(struct drm_panfrost_madvise *m)
{
   uint64_t retained = 1;
   uint32_t kr = scall(SEL_PAN_MADVISE, m, 12, &retained, 1);
   m->retained = kr ? 1 : (uint32_t)retained;
   return 0;
}

/* DRM_IOCTL_PANFROST_SUBMIT; called with the lock held */
static int
sched_submit(struct drm_panfrost_submit *s)
{
   if (s->bo_handle_count > max_submit_bos || s->in_sync_count > MAX_IN_SYNCS) {
      herodrm_log("SUBMIT refused: %u BOs (at most %u), %u in_syncs (%u)", s->bo_handle_count,
                  max_submit_bos, s->in_sync_count, MAX_IN_SYNCS);
      return fail(EINVAL);
   }
   if (s->out_sync && !usync_valid(s->out_sync))
      return fail(EINVAL);
   uint8_t stack[4096], *buf = stack;
   size_t most = 40 + 4u * (s->bo_handle_count + s->in_sync_count);
   if (most > sizeof(stack) && !(buf = malloc(most)))
      return fail(ENOMEM);

   struct drm_panfrost_submit k = { .jc = s->jc, .bo_handle_count = s->bo_handle_count,
                                    .requirements = s->requirements };
   _Static_assert(sizeof(k) == 40, "drm_panfrost_submit is 40 bytes");
   uint32_t *bo = (uint32_t *)(buf + 40), *in = bo + s->bo_handle_count;
   if (s->bo_handle_count)
      memcpy(bo, (const void *)(uintptr_t)s->bo_handles, 4u * s->bo_handle_count);
   const uint32_t *ins = (const uint32_t *)(uintptr_t)s->in_syncs;
   for (uint32_t i = 0; i < s->in_sync_count; i++) {
      if (!usync_valid(ins[i])) {
         if (buf != stack)
            free(buf);
         return fail(EINVAL);
      }
      struct kfence *f = usync[ins[i]];
      if (f && f != SIGNALED)
         in[k.in_sync_count++] = f->ksync;     /* signaled, or no fence: nothing to wait for */
   }
   struct kfence *done = NULL;
   if (s->out_sync && !(done = fence_new())) {
      if (buf != stack)
         free(buf);
      return fail(ENOMEM);
   }
   k.out_sync = done ? done->ksync : 0;
   memcpy(buf, &k, 40);
   size_t size = 40 + 4u * (k.bo_handle_count + k.in_sync_count);

   /* this thread's write-combined writes of the chain land before another core starts the job */
   __asm__ volatile ("dsb sy" ::: "memory");
   uint64_t t0 = now_ns();
   uint32_t kr = scall(SEL_PAN_SUBMIT, buf, size, NULL, 0);
   uint64_t t1 = now_ns();
   if (buf != stack)
      free(buf);
   submits++;
   st.submits++;
   st.submit_ns += t1 - t0;
   stats_tick(t1);
   if (kr) {
      faults++;
      if (faults <= 16 || debug > 0)
         herodrm_log("SUBMIT #%llu jc 0x%llx (%s, %u BOs, %u in_syncs): 0x%x", (unsigned long long)submits,
                     (unsigned long long)s->jc, s->requirements & PANFROST_JD_REQ_FS ? "fragment" : "vertex/tiler",
                     k.bo_handle_count, k.in_sync_count, kr);
      if (kr == KR_BAD_ARGUMENT && k.bo_handle_count > 1024)
         herodrm_log("  more than 1024 BOs: v64 takes no more (v65 takes 4096; HERODRM_MAX_SUBMIT_BOS=1024 on v64)");
      fence_unref(done);
      return fail(kr == KR_BAD_ARGUMENT ? EINVAL : EIO);
   }
   DBG("SUBMIT #%llu jc 0x%llx req 0x%x: %u BOs, %u in_syncs, out %u", (unsigned long long)submits,
       (unsigned long long)s->jc, s->requirements, k.bo_handle_count, k.in_sync_count, k.out_sync);
   if (done)
      usync_set(s->out_sync, done);
   return 0;
}

/* drmSyncobjWait with the scheduler: takes and drops the lock itself */
static int
sched_syncobj_wait(const uint32_t *handles, unsigned count, int64_t timeout, unsigned flags, uint32_t *first)
{
   const bool all = flags & DRM_SYNCOBJ_WAIT_FLAGS_WAIT_ALL;
   if (!count || count > MAX_USYNC)
      return fail(EINVAL);
   struct kfence **held = calloc(count, sizeof(*held));
   uint32_t *index = calloc(count, sizeof(*index));
   uint8_t *buf = malloc(40 + 4u * count);
   unsigned n = 0;
   int r = 0;
   if (!held || !index || !buf) {
      r = fail(ENOMEM);
      goto out;
   }
   pthread_mutex_lock(&lock);
   for (unsigned i = 0; i < count; i++) {
      if (!usync_valid(handles[i]) || !usync[handles[i]]) {
         /* no fence: Linux says EINVAL without WAIT_FOR_SUBMIT, and Mesa's JM path never waits for a submit */
         if (usync_valid(handles[i]) && debug > 0)
            herodrm_log("SyncobjWait: syncobj %u has no fence (flags 0x%x)", handles[i], flags);
         pthread_mutex_unlock(&lock);
         r = fail(EINVAL);
         goto out;
      }
      struct kfence *f = usync[handles[i]];
      if (f == SIGNALED) {
         if (!all) {
            if (first)
               *first = i;
            pthread_mutex_unlock(&lock);
            goto out;           /* r = 0 */
         }
         continue;
      }
      held[n] = fence_ref(f);
      index[n] = i;
      ((uint32_t *)(buf + 40))[n++] = f->ksync;
   }
   pthread_mutex_unlock(&lock);
   if (!n) {
      if (first)
         *first = 0;
      goto out;
   }

   struct { uint64_t handles; int64_t timeout_nsec; uint32_t count_handles, flags, first_signaled, pad;
            uint64_t deadline_nsec; } w = { 0, 0, n, flags, 0, 0, 0 };
   _Static_assert(sizeof(w) == 40, "drm_syncobj_wait is 40 bytes");
   uint64_t got = 0, t0 = now_ns();
   uint32_t kr;
   do {
      w.timeout_nsec = relative_ns(timeout);
      memcpy(buf, &w, 40);
      kr = scall(SEL_SYNCOBJ_WAIT, buf, 40 + 4u * n, &got, 1);
   } while (kr == KR_ABORTED);
   pthread_mutex_lock(&lock);
   st.waits++;
   st.wait_ns += now_ns() - t0;
   pthread_mutex_unlock(&lock);
   if (kr == 0) {
      if (first)
         *first = all || got >= n ? 0 : index[got];
   } else if (kr == KR_TIMEOUT) {
      r = fail(ETIME);
   } else {
      herodrm_log("SyncobjWait (%u syncobjs, flags 0x%x): 0x%x", n, flags, kr);
      r = fail(EINVAL);
   }
out:
   if (n) {
      pthread_mutex_lock(&lock);
      for (unsigned i = 0; i < n; i++)
         fence_unref(held[i]);
      pthread_mutex_unlock(&lock);
   }
   free(held);
   free(index);
   free(buf);
   return r;
}

static int
submit(struct drm_panfrost_submit *s)
{
   static bool asked;
   if (sched == 1)
      return sched_submit(s);
   uint64_t js = (s->requirements & PANFROST_JD_REQ_FS) ? 0 : 1;

   if (!asked) {
      const char *a = getenv("HERO_ASYNC");
      pthread_t thread;

      asked = true;
      async_on = a && *a == '1' && pthread_create(&thread, NULL, queue_worker, NULL) == 0;
      herodrm_log("submits are %s", async_on ? "queued (HERO_ASYNC=1)" : "synchronous");
   }
   if (!async_on)
      return submit_now(s->jc, js);
   /* This thread's write-combined writes of the chain land before another core starts the job. */
   __asm__ volatile ("dsb sy" ::: "memory");
   pthread_mutex_lock(&qlock);
   while (queued - finished == QUEUE_SIZE)
      pthread_cond_wait(&qdone, &qlock);
   queue[queued % QUEUE_SIZE].jc = s->jc;
   queue[queued % QUEUE_SIZE].js = js;
   queued++;
   /* the job's BOs are busy until this job is finished (Mesa frees the list when this returns) */
   const uint32_t *handles = (const uint32_t *)(uintptr_t)s->bo_handles;
   for (uint32_t i = 0; i < s->bo_handle_count; i++)
      if (handles[i] && handles[i] <= MAX_BOS)
         bo_last_job[handles[i]] = queued;
   pthread_cond_signal(&qwork);
   pthread_mutex_unlock(&qlock);
   return 0;
}

EXPORT int
drmIoctl(int fd, unsigned long request, void *arg)
{
   (void)fd;
   int r = 0;
   pthread_mutex_lock(&lock);
   if (connect_gpu()) {
      pthread_mutex_unlock(&lock);
      return fail(ENODEV);
   }
   switch (request) {
   case DRM_IOCTL_PANFROST_GET_PARAM: {
      struct drm_panfrost_get_param *p = arg;
      uint64_t in = p->param, out = 0;
      if (call(SEL_PARAM, &in, 1, &out, 1))
         r = fail(EINVAL);
      else
         p->value = out;
      break;
   }
   case DRM_IOCTL_PANFROST_CREATE_BO:
      r = create_bo(arg);
      break;
   case DRM_IOCTL_GEM_CLOSE:
      r = free_bo(((struct drm_gem_close *)arg)->handle);
      break;
   case DRM_IOCTL_PANFROST_GET_BO_OFFSET: {
      struct drm_panfrost_get_bo_offset *p = arg;
      struct hbo *bo = lookup(p->handle);
      if (bo)
         p->offset = bo->va;
      else
         r = fail(EINVAL);
      break;
   }
   case DRM_IOCTL_PANFROST_MMAP_BO: {
      struct drm_panfrost_mmap_bo *p = arg;
      if (lookup(p->handle))
         p->offset = (uint64_t)p->handle << 32;
      else
         r = fail(EINVAL);
      break;
   }
   case DRM_IOCTL_PANFROST_WAIT_BO:
      if (sched == 1) {
         r = sched_wait_bo(arg);       /* drops the lock while it waits */
         break;
      }
      /* Only the jobs that named this BO: an idle one can be reused at once from Mesa's cache. */
      if (((struct drm_panfrost_wait_bo *)arg)->timeout_ns == 0 &&
          bo_busy(((struct drm_panfrost_wait_bo *)arg)->handle))
         r = fail(ETIMEDOUT);
      else
         bo_wait(((struct drm_panfrost_wait_bo *)arg)->handle);
      break;
   case DRM_IOCTL_PANFROST_MADVISE:
      if (sched == 1)
         r = sched_madvise(arg);       /* the kernel's answer (v64: always retained) */
      else
         ((struct drm_panfrost_madvise *)arg)->retained = 1;
      break;
   case DRM_IOCTL_PANFROST_SUBMIT:
      r = submit(arg);
      break;
   default:
      herodrm_log("unhandled ioctl 0x%lx", request);
      r = fail(EINVAL);
      break;
   }
   pthread_mutex_unlock(&lock);
   return r;
}

/* mmap() of a BO: offset is handle << 32 plus the offset inside the BO. */
EXPORT void *
herodrm_mmap(void *addr, size_t size, int prot, int flags, int fd, off_t offset)
{
   (void)addr;
   (void)prot;
   (void)flags;
   (void)fd;
   uint32_t handle = (uint32_t)((uint64_t)offset >> 32);
   uint64_t inner = (uint64_t)offset & 0xffffffffull;
   void *p = MAP_FAILED;
   pthread_mutex_lock(&lock);
   struct hbo *bo = lookup(handle);
   if (bo && inner + size <= bo->size) {
      if (!bo->cpu) {
         uint64_t in = handle, out = 0;
         if (call(SEL_MAP, &in, 1, &out, 1) == 0)
            bo->cpu = out;
      }
      if (bo->cpu)
         p = (void *)(uintptr_t)(bo->cpu + inner);
   }
   pthread_mutex_unlock(&lock);
   if (p == MAP_FAILED) {
      herodrm_log("mmap of BO %u (+0x%llx, %zu bytes) failed", handle,
                  (unsigned long long)inner, size);
      errno = EINVAL;
   }
   return p;
}

/* The kernel keeps one mapping per BO until it is freed. */
EXPORT int
herodrm_munmap(void *addr, size_t size)
{
   (void)addr;
   (void)size;
   return 0;
}

EXPORT int
drmCloseBufferHandle(int fd, uint32_t handle)
{
   (void)fd;
   pthread_mutex_lock(&lock);
   int r = free_bo(handle);
   pthread_mutex_unlock(&lock);
   return r;
}

/*
 * IOSurfaces as GPU buffers (kernel 0248, HeroGPU SurfaceBO): Panfrost
 * imports foreign memory only as a dma-buf file descriptor. A surface import
 * gets a /dev/null descriptor that stands for its BO: drmPrimeFDToHandle
 * gives the handle and herodrm_prime_size() the size (Mesa's
 * pan_kmod_bo_import is patched to ask it instead of lseek on Apple).
 */
struct herodrm_surface {
   uint32_t handle, bytes_per_row, width, height, pixel_format, offset, planes;
   uint64_t size;
};

EXPORT int
herodrm_surface_import(uint32_t surface_id, struct herodrm_surface *info)
{
   int r = -1;
   pthread_mutex_lock(&lock);
   if (connect_gpu() == 0) {
      uint64_t in = surface_id, out[9] = {0};
      uint32_t kr = call(SEL_SURFACE_BO, &in, 1, out, 9);
      if (kr == 0 && out[0] && out[0] <= MAX_BOS) {
         int slot = -1;
         for (int i = 0; i < MAX_PRIME && slot < 0; i++)
            if (!primes[i].handle)
               slot = i;
         int fd = slot >= 0 ? open("/dev/null", O_RDONLY | O_CLOEXEC) : -1;
         if (fd >= 0) {
            bos[out[0]] = (struct hbo){ .va = out[1], .size = out[2] };
            primes[slot].fd = fd;
            primes[slot].handle = (uint32_t)out[0];
            *info = (struct herodrm_surface){ .handle = (uint32_t)out[0], .size = out[2],
               .bytes_per_row = (uint32_t)out[3], .width = (uint32_t)out[4], .height = (uint32_t)out[5],
               .pixel_format = (uint32_t)out[6], .offset = (uint32_t)out[7], .planes = (uint32_t)out[8] };
            r = fd;
            DBG("surface %u imported: BO %u at 0x%llx, %ux%u bpr %u fmt 0x%x", surface_id,
                (unsigned)out[0], (unsigned long long)out[1], info->width, info->height,
                info->bytes_per_row, info->pixel_format);
         } else {
            in = out[0];
            call(SEL_FREE, &in, 1, NULL, 0);
         }
      } else if (debug > 0) {
         herodrm_log("surface %u: no GPU import (kr 0x%x)", surface_id, kr);
      }
   }
   pthread_mutex_unlock(&lock);
   return r < 0 ? fail(ENOENT) : r;
}

/* Make the GPU's writes into an imported surface visible to the CPU and the display. */
EXPORT int
herodrm_bo_sync(uint32_t handle)
{
   /* v64: selector 7 cleans at once, so first wait (without the lock) for the jobs that use the BO */
   if (sched == 1 && conn) {
      uint32_t kr = sched_wait_bo_call(handle, INT64_MAX);
      if (kr)
         herodrm_log("SYNC_BO %u: the wait for its jobs returned 0x%x", handle, kr);
   }
   pthread_mutex_lock(&lock);
   queue_drain();
   uint64_t in = handle;
   uint32_t kr = conn ? call(SEL_SYNC_BO, &in, 1, NULL, 0) : 1;
   pthread_mutex_unlock(&lock);
   return kr ? fail(EINVAL) : 0;
}

EXPORT int64_t
herodrm_prime_size(int prime_fd)
{
   int64_t size = -1;
   pthread_mutex_lock(&lock);
   for (int i = 0; i < MAX_PRIME; i++)
      if (primes[i].handle && primes[i].fd == prime_fd && lookup(primes[i].handle))
         size = (int64_t)bos[primes[i].handle].size;
   pthread_mutex_unlock(&lock);
   return size;
}

/* No export: nothing is shared with another process. */
EXPORT int
drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd)
{
   (void)fd; (void)handle; (void)flags; (void)prime_fd;
   return fail(ENOSYS);
}

EXPORT int
drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle)
{
   (void)fd;
   int r = fail(ENOENT);
   pthread_mutex_lock(&lock);
   for (int i = 0; i < MAX_PRIME; i++)
      if (primes[i].handle && primes[i].fd == prime_fd) {
         *handle = primes[i].handle;
         r = 0;
      }
   pthread_mutex_unlock(&lock);
   return r;
}

/* Syncobjs. Without the kernel's scheduler, submits are synchronous, so every
 * syncobj is signaled. With it (sched == 1), see "the kernel's scheduler". */
static uint32_t next_syncobj = 1;

EXPORT int
drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle)
{
   (void)fd;
   pthread_mutex_lock(&lock);
   if (sched == 1) {
      uint32_t h = 0;
      for (uint32_t i = 1; i <= MAX_USYNC && !h; i++)
         if (!usync_used[i])
            h = i;
      if (!h) {
         pthread_mutex_unlock(&lock);
         herodrm_log("SyncobjCreate: all %u handles in use", MAX_USYNC);
         return fail(ENOMEM);
      }
      usync_used[h] = true;
      usync[h] = flags & DRM_SYNCOBJ_CREATE_SIGNALED ? SIGNALED : NULL;
      *handle = h;
   } else {
      (void)flags;
      *handle = next_syncobj++;
   }
   pthread_mutex_unlock(&lock);
   return 0;
}

EXPORT int
drmSyncobjDestroy(int fd, uint32_t handle)
{
   (void)fd;
   int r = 0;
   pthread_mutex_lock(&lock);
   if (sched == 1) {
      if (usync_valid(handle)) {
         usync_set(handle, NULL);
         usync_used[handle] = false;
      } else {
         r = fail(EINVAL);
      }
   }
   pthread_mutex_unlock(&lock);
   return r;
}

EXPORT int
drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles, int64_t timeout_nsec,
               unsigned flags, uint32_t *first_signaled)
{
   (void)fd;
   if (sched == 1)
      return sched_syncobj_wait(handles, num_handles, timeout_nsec, flags, first_signaled);
   (void)handles; (void)num_handles; (void)timeout_nsec; (void)flags;
   queue_drain();
   if (first_signaled)
      *first_signaled = 0;
   return 0;
}

EXPORT int
drmSyncobjTimelineWait(int fd, uint32_t *handles, uint64_t *points, unsigned num_handles,
                       int64_t timeout_nsec, unsigned flags, uint32_t *first_signaled)
{
   (void)points;
   return drmSyncobjWait(fd, handles, num_handles, timeout_nsec, flags, first_signaled);
}

/* Reset (to no fence) or Signal (to signaled): with the scheduler, Mesa's handles are repointed here */
static int
usync_point_all(const uint32_t *handles, uint32_t count, struct kfence *to)
{
   int r = 0;
   pthread_mutex_lock(&lock);
   for (uint32_t i = 0; i < count; i++) {
      if (usync_valid(handles[i]))
         usync_set(handles[i], to);
      else
         r = fail(EINVAL);
   }
   pthread_mutex_unlock(&lock);
   return r;
}

EXPORT int
drmSyncobjReset(int fd, const uint32_t *handles, uint32_t handle_count)
{
   (void)fd;
   if (sched == 1)
      return usync_point_all(handles, handle_count, NULL);
   (void)handles; (void)handle_count;
   return 0;
}

EXPORT int
drmSyncobjSignal(int fd, const uint32_t *handles, uint32_t handle_count)
{
   (void)fd;
   if (sched == 1)
      return usync_point_all(handles, handle_count, SIGNALED);
   (void)handles; (void)handle_count;
   return 0;
}

/* binary syncobjs only (points 0): dst takes src's fence */
EXPORT int
drmSyncobjTransfer(int fd, uint32_t dst_handle, uint64_t dst_point, uint32_t src_handle,
                   uint64_t src_point, uint32_t flags)
{
   (void)fd; (void)flags;
   if (sched != 1) {
      (void)dst_handle; (void)dst_point; (void)src_handle; (void)src_point;
      return 0;
   }
   if (dst_point || src_point)
      return fail(EINVAL);
   int r = 0;
   pthread_mutex_lock(&lock);
   if (usync_valid(dst_handle) && usync_valid(src_handle))
      usync_set(dst_handle, fence_ref(usync[src_handle]));
   else
      r = fail(EINVAL);
   pthread_mutex_unlock(&lock);
   return r;
}

/* With the scheduler, a sync file's descriptor stands for a reference to one
 * kfence until the descriptor is closed (Mesa closes it right after importing
 * it). Descriptors closed meanwhile are swept here; with the lock held. */
static void
syncfile_sweep(void)
{
   for (unsigned i = 0; i < MAX_SYNCFILE; i++)
      if (syncfiles[i].f && fcntl(syncfiles[i].fd, F_GETFD) == -1) {
         fence_unref(syncfiles[i].f);
         syncfiles[i].f = NULL;
      }
}

/* A sync file is a /dev/null descriptor; without the scheduler, already
 * signaled. (Mesa treats -1 as a failed export and makes no fence.) */
EXPORT int
drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd)
{
   (void)fd;
   if (sched == 1) {
      pthread_mutex_lock(&lock);
      if (!usync_valid(handle)) {
         pthread_mutex_unlock(&lock);
         return fail(EINVAL);
      }
      syncfile_sweep();
      int sf = open("/dev/null", O_RDONLY | O_CLOEXEC);
      if (sf < 0) {
         pthread_mutex_unlock(&lock);
         return -1;
      }
      unsigned slot = MAX_SYNCFILE;
      for (unsigned i = 0; i < MAX_SYNCFILE && slot == MAX_SYNCFILE; i++)
         if (!syncfiles[i].f || syncfiles[i].fd == sf)
            slot = i;
      if (slot == MAX_SYNCFILE) {        /* full of descriptors still open: drop the oldest */
         slot = syncfile_next++ % MAX_SYNCFILE;
         herodrm_log("sync files: all %u in use; one dropped", MAX_SYNCFILE);
      }
      fence_unref(syncfiles[slot].f);
      /* no fence yet: Linux fails the export; signaled keeps Mesa's fence usable, as before v64 */
      syncfiles[slot].f = usync[handle] ? fence_ref(usync[handle]) : SIGNALED;
      syncfiles[slot].fd = sf;
      *sync_file_fd = sf;
      pthread_mutex_unlock(&lock);
      return 0;
   }
   (void)handle;
   *sync_file_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
   return *sync_file_fd < 0 ? -1 : 0;
}

EXPORT int
drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd)
{
   (void)fd;
   if (sched != 1) {
      (void)handle; (void)sync_file_fd;
      return 0;
   }
   int r = 0;
   pthread_mutex_lock(&lock);
   if (!usync_valid(handle)) {
      r = fail(EINVAL);
   } else {
      struct kfence *f = NULL;
      for (unsigned i = 0; i < MAX_SYNCFILE && !f; i++)
         if (syncfiles[i].f && syncfiles[i].fd == sync_file_fd)
            f = syncfiles[i].f;
      if (!f) {                 /* not one of ours: nothing to wait for */
         static unsigned told;
         if (told++ < 4)
            herodrm_log("ImportSyncFile: descriptor %d is not a sync file of this process; taken as signaled",
                        sync_file_fd);
         f = SIGNALED;
      }
      usync_set(handle, fence_ref(f));
   }
   pthread_mutex_unlock(&lock);
   return r;
}

EXPORT int
drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle)
{
   int r = drmSyncobjCreate(fd, 0, handle);
   if (r == 0 && sched == 1 && drmSyncobjImportSyncFile(fd, *handle, obj_fd) != 0) {
      drmSyncobjDestroy(fd, *handle);
      return -1;
   }
   (void)obj_fd;
   return r;
}

EXPORT int
drmSyncobjHandleToFD(int fd, uint32_t handle, int *obj_fd)
{
   (void)fd; (void)handle;
   *obj_fd = -1;
   return fail(ENOSYS);
}
