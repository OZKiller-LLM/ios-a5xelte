/*
 * Galaxy A04s, Metal track M6b: backboardd on the Metal device -- its log, watchdog and statistics.
 *
 * Linked into libA04sMetalDevice.dylib. Active only in backboardd, after the gate (A04sMetal.m) let it
 * take the Metal path and the device was made (a04s_bb_device_ready). Everywhere else every hook below
 * returns at once, so the probe behaves as before.
 *
 * - The log: /private/var/a04s/bb-metal/bb-metal.log (the gate sets A04S_METAL_LOG). A line is queued
 *   (a04s_log_divert) and written, with an fsync per batch, by a thread of its own: the render thread
 *   never waits for the eMMC (run 12 saw single fsyncs of up to 15 s).
 * - IMAGE lines once the device exists: where our libraries, Metal, QuartzCore, the OpenGL ES route's
 *   libraries and the shared cache are loaded, to resolve a crash PC from the kernel's CRASH lines.
 * - The watchdog (the same thread, once a second), counting from the first commit, not from launch
 *   (Chlorophyll's lesson: a display-off restart must not switch Metal off):
 *     - committed GPU work that has not completed after A04S_BB_STALL_S seconds (default 20), or
 *     - A04S_BB_MAX_FAILURES command buffers in a row failing (default 120),
 *   record the fallback for this boot (bb-metal/fallback) and end backboardd, so launchd restarts it and
 *   the gate keeps it on OpenGL ES (A04S_BB_FALLBACK_EXIT=0: record and log only). After 60 s of
 *   compositing with at least 100 command buffers completed, the gate's launch count is reset ("healthy").
 * - A line every 10 s while compositing: command buffers committed, completed and failed, commit to
 *   completion time (average and maximum), pipelines built and refused, textures refused, draws and clears
 *   skipped, Metal selectors the device does not implement.
 * - Each texture over an IOSurface: its size, allocation and whether the kernel imported it (M6b boot 1 panicked wiring a
 *   page past a one-page object), and A04S_SURFACE_IMPORT_MIN_BYTES in bgmtl.m to copy small ones instead.
 * - The first CPU-written (linear) textures: their size, format and whether their rows were reversed, and
 *   the first A04S_BB_DUMP_LINEAR (default 8) of up to 512 x 512 (at least 8 rows) written as stored, before any reversal,
 *   to bb-metal/linear-NN-WxH-fmtF-bprB.raw. Boot 1: labels are upright as stored, so backboardd no longer reverses
 *   them (bgmtl.m); the probe still does (M6a run 12).
 * - Boot 5 (M6b boot 4: backboardd died twice with no line, its GPU buffers at 183 MB during Siri):
 *     - memory: at start backboardd's footprint and its jetsam limit (if the kernel tells it), a line at once whenever the
 *       footprint passes a new 32 MB step, and the footprint and its peak in every stats line;
 *     - how it ends: a line, written straight from the handler, for each of SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT,
 *       SIGBUS, SIGSEGV, SIGILL, SIGFPE, SIGSYS and SIGTRAP (who sent it, or the fault address, PC and LR), then
 *       backboardd's own handler or the default action; and one for exit(). A jetsam kill (SIGKILL) leaves no line;
 *     - bgmtl.m's in-flight cap (A04S_MAX_INFLIGHT, 4 here): its waits and how long they took, in each stats line.
 */
#define A04S_LOG_DIVERT_STRONG 1
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <errno.h>
#include <malloc/malloc.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/ucontext.h>

#include "a04s_metal_log.h"

#define BB_DIR "/private/var/a04s/bb-metal"

static atomic_int bb_on;                 /* 1 once the device is ready in backboardd */
static pthread_t bb_thread;
static double bb_t_ready;

/* ---- the queue of log lines and dumps -------------------------------------------------------- */

#define BB_SLOTS 256
#define BB_LINE 1024
static pthread_mutex_t bb_q_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t bb_q_cond = PTHREAD_COND_INITIALIZER;
static char bb_q[BB_SLOTS][BB_LINE];
static unsigned bb_q_head, bb_q_len, bb_q_dropped;

struct bb_dump { char path[160]; void *bytes; size_t len; struct bb_dump *next; };
static struct bb_dump *bb_dumps;

static void
bb_queue(const char *line, size_t n)
{
   pthread_mutex_lock(&bb_q_lock);
   if (bb_q_len == BB_SLOTS) {
      bb_q_dropped++;
   } else {
      char *slot = bb_q[(bb_q_head + bb_q_len++) % BB_SLOTS];
      if (n >= BB_LINE) {
         n = BB_LINE - 1;
         slot[n - 1] = '\n';
         memcpy(slot, line, n - 1);
      } else {
         memcpy(slot, line, n);
      }
      slot[n] = 0;
   }
   pthread_cond_signal(&bb_q_cond);
   pthread_mutex_unlock(&bb_q_lock);
}

__attribute__((visibility("hidden"))) int
a04s_log_divert(const char *line, size_t n)
{
   if (!atomic_load(&bb_on) || pthread_equal(pthread_self(), bb_thread))
      return 0;
   bb_queue(line, n);
   return 1;
}

/* a line in the log's own format, queued */
static void __attribute__((format(printf, 1, 2)))
bb_log(const char *fmt, ...)
{
   char line[BB_LINE];
   int n = snprintf(line, sizeof(line), "[%s %d +%.3fs] ", getprogname(), getpid(), a04s_now());
   va_list ap;
   va_start(ap, fmt);
   n += vsnprintf(line + n, sizeof(line) - (size_t)n - 2, fmt, ap);
   va_end(ap);
   if (n > (int)sizeof(line) - 2)
      n = (int)sizeof(line) - 2;
   line[n++] = '\n';
   line[n] = 0;
   bb_queue(line, (size_t)n);
}

/* writes what is queued; with `sync`, flushed to the eMMC before it returns */
static void
bb_flush(int log_fd, bool sync)
{
   for (;;) {
      char line[BB_LINE];
      struct bb_dump *d = NULL;
      unsigned dropped = 0;
      pthread_mutex_lock(&bb_q_lock);
      bool have = bb_q_len > 0;
      if (have) {
         strlcpy(line, bb_q[bb_q_head], sizeof(line));
         bb_q_head = (bb_q_head + 1) % BB_SLOTS;
         bb_q_len--;
      } else if (bb_dumps) {
         d = bb_dumps;
         bb_dumps = d->next;
      }
      dropped = bb_q_dropped;
      bb_q_dropped = 0;
      pthread_mutex_unlock(&bb_q_lock);
      if (dropped && log_fd >= 0) {
         char m[96];
         int k = snprintf(m, sizeof(m), "[%s %d +%.3fs] (%u log lines dropped: the queue was full)\n", getprogname(),
                          getpid(), a04s_now(), dropped);
         (void)!write(log_fd, m, (size_t)k);
      }
      if (have) {
         if (log_fd >= 0)
            (void)!write(log_fd, line, strlen(line));
         continue;
      }
      if (d) {
         int fd = open(d->path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
         if (fd >= 0) {
            (void)!write(fd, d->bytes, d->len);
            close(fd);
         }
         free(d->bytes);
         free(d);
         continue;
      }
      break;
   }
   if (sync && log_fd >= 0)
      fsync(log_fd);
}

/* ---- counters, from the device's hooks -------------------------------------------------------- */

#define BB_RING 1024
static pthread_mutex_t bb_c_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t bb_ring[BB_RING];        /* commit times (ns) of command buffers not yet completed or failed */
static unsigned bb_ring_head, bb_ring_len;
static uint64_t bb_first_commit;
static uint64_t bb_committed, bb_completed, bb_failed, bb_presents;
static unsigned bb_fail_run;            /* failures since the last completion */
static uint64_t bb_lat_sum, bb_lat_max, bb_lat_n;        /* this window */
static unsigned bb_pipes_made, bb_pipes_refused;
static double bb_pipe_secs;
static unsigned bb_tex_refused, bb_draw_skipped, bb_clear_skipped, bb_other_refused;
static char bb_last_failure[256];
static uint64_t bb_commit_threads[4];    /* the threads that committed in this stats window (the first four) */
static unsigned bb_commit_nthreads;

static uint64_t
bb_ns(void)
{
   return clock_gettime_nsec_np(CLOCK_MONOTONIC);
}

static void
bb_pop(uint64_t now, bool timed)
{
   if (!bb_ring_len)
      return;
   uint64_t t = bb_ring[bb_ring_head];
   bb_ring_head = (bb_ring_head + 1) % BB_RING;
   bb_ring_len--;
   if (timed && now > t) {
      uint64_t l = now - t;
      bb_lat_sum += l;
      bb_lat_n++;
      if (l > bb_lat_max)
         bb_lat_max = l;
   }
}

void
bgmtl_note_committed(void)
{
   if (!atomic_load(&bb_on))
      return;
   uint64_t now = bb_ns();
   pthread_mutex_lock(&bb_c_lock);
   if (!bb_first_commit) {
      bb_first_commit = now;
      bb_log("bb: CoreAnimation committed its first command buffer on Metal, %.1f s after the device was made",
             a04s_now() - bb_t_ready);
   }
   bb_committed++;
   uint64_t tid = 0;
   pthread_threadid_np(NULL, &tid);
   bool seen = false;
   for (unsigned i = 0; i < bb_commit_nthreads && !seen; i++)
      seen = bb_commit_threads[i] == tid;
   if (!seen && bb_commit_nthreads < 4)
      bb_commit_threads[bb_commit_nthreads++] = tid;
   if (bb_ring_len == BB_RING)
      bb_pop(now, false);     /* only if completions go missing; the oldest is dropped */
   bb_ring[(bb_ring_head + bb_ring_len++) % BB_RING] = now;
   pthread_mutex_unlock(&bb_c_lock);
}

void
bgmtl_note_completed(void)
{
   if (!atomic_load(&bb_on))
      return;
   uint64_t now = bb_ns();
   pthread_mutex_lock(&bb_c_lock);
   bb_completed++;
   bb_fail_run = 0;
   bb_pop(now, true);
   pthread_mutex_unlock(&bb_c_lock);
}

void
bgmtl_note_failure(const char *why)
{
   if (!atomic_load(&bb_on))
      return;
   pthread_mutex_lock(&bb_c_lock);
   bb_failed++;
   bb_fail_run++;
   bb_pop(bb_ns(), false);
   strlcpy(bb_last_failure, why ? why : "-", sizeof(bb_last_failure));
   pthread_mutex_unlock(&bb_c_lock);
}

void
bgmtl_note_present(const char *line)
{
   (void)line;
   if (atomic_load(&bb_on))
      __atomic_add_fetch(&bb_presents, 1, __ATOMIC_RELAXED);
}

/* a selector the device does not answer: logged once each (the first 64) */
void
bgmtl_note_unimplemented(const char *sel)
{
   if (!atomic_load(&bb_on) || !sel)
      return;
   static char seen[64][96];
   static unsigned nseen;
   pthread_mutex_lock(&bb_c_lock);
   bool fresh = nseen < 64;
   for (unsigned i = 0; fresh && i < nseen; i++)
      if (!strncmp(seen[i], sel, sizeof(seen[i]) - 1))
         fresh = false;
   if (fresh)
      strlcpy(seen[nseen++], sel, sizeof(seen[0]));
   pthread_mutex_unlock(&bb_c_lock);
   if (fresh)
      bb_log("bgmtl: unimplemented selector %s", sel);
}

/* one of the device's own lines (bg_log): counted by kind, and the first 40 of each kind logged */
void
bgmtl_note_line(const char *line)
{
   if (!atomic_load(&bb_on) || !line)
      return;
   static unsigned shown[5];
   unsigned kind = !strncmp(line, "texture refused", 15) ? 0 : !strncmp(line, "draw skipped", 12) ? 1
                 : !strncmp(line, "clear skipped", 13) ? 2 : strstr(line, "refused") ? 3 : 4;
   pthread_mutex_lock(&bb_c_lock);
   unsigned *count[4] = { &bb_tex_refused, &bb_draw_skipped, &bb_clear_skipped, &bb_other_refused };
   if (kind < 4)
      (*count[kind])++;
   bool show = shown[kind] < 40;
   if (show)
      shown[kind]++;
   pthread_mutex_unlock(&bb_c_lock);
   if (show) {
      size_t n = strcspn(line, "\n");
      bb_log("bgmtl: %.*s%s", (int)n, line, shown[kind] == 40 ? " (the last of its kind logged; the rest are counted)" : "");
   }
}

/* A04sMTLDevice: one render or compute pipeline built (or refused), and its time */
void
a04s_bb_note_pipeline(double secs, int made)
{
   if (!atomic_load(&bb_on))
      return;
   pthread_mutex_lock(&bb_c_lock);
   if (made)
      bb_pipes_made++;
   else
      bb_pipes_refused++;
   bb_pipe_secs += secs;
   pthread_mutex_unlock(&bb_c_lock);
}

/* bgmtl.m: the first refresh of each CPU-written texture, rows as stored (before any reversal) */
void
bgmtl_note_cpu_rows(const char *what, unsigned w, unsigned h, unsigned fmt, const uint8_t *src, size_t bpr, int reversed)
{
   if (!atomic_load(&bb_on))
      return;
   static unsigned seen, dumped;
   static int dump_max = -1;
   if (dump_max < 0) {
      const char *e = getenv("A04S_BB_DUMP_LINEAR");
      dump_max = e ? atoi(e) : 8;
   }
   unsigned k = __atomic_fetch_add(&seen, 1, __ATOMIC_RELAXED);
   if (k < 24)
      bb_log("bb: %s texture %ux%u fmt %u, rows of %zu bytes, rows %s", what, w, h, fmt, bpr,
             reversed ? "reversed (bottom-up, as CoreAnimation samples them)" : "as stored");
   /* boot 1 spent its slots on 256 x 1 lookup tables; text masks are 2 bytes a pixel (RG8), so rows go out whole */
   if (!src || w == 0 || h < 8 || w > 512 || h > 512 || bpr < w || bpr > 4096)
      return;
   unsigned d = __atomic_fetch_add(&dumped, 1, __ATOMIC_RELAXED);
   if ((int)d >= dump_max) {
      __atomic_fetch_sub(&dumped, 1, __ATOMIC_RELAXED);
      return;
   }
   struct bb_dump *job = calloc(1, sizeof(*job));
   uint8_t *bytes = malloc(bpr * h);
   if (!job || !bytes) {
      free(job);
      free(bytes);
      return;
   }
   memcpy(bytes, src, bpr * h);
   snprintf(job->path, sizeof(job->path), BB_DIR "/linear-%02u-%ux%u-fmt%u-bpr%zu.raw", d, w, h, fmt, bpr);
   job->bytes = bytes;
   job->len = bpr * h;
   pthread_mutex_lock(&bb_q_lock);
   job->next = bb_dumps;
   bb_dumps = job;
   pthread_cond_signal(&bb_q_cond);
   pthread_mutex_unlock(&bb_q_lock);
   bb_log("bb: %s texture %ux%u fmt %u written as stored to %s", what, w, h, fmt, job->path);
}

/* bgmtl.m: a texture over an IOSurface, and whether the kernel imported it (M6b boot 1's panic: a page wired past the end
 * of a one-page VM object). The first 400 are logged; the stats line counts them by outcome. */
static unsigned bb_surf_imported, bb_surf_copied, bb_surf_refused;
static size_t bb_surf_smallest = SIZE_MAX;

void
bgmtl_note_surface(unsigned id, size_t w, size_t h, size_t bpr, size_t alloc, unsigned fmt, unsigned planes, unsigned plane,
                   int render_target, const char *result)
{
   if (!atomic_load(&bb_on))
      return;
   static unsigned shown;
   const bool imported = result && !strcmp(result, "imported"), copied = result && !strncmp(result, "copy", 4);
   pthread_mutex_lock(&bb_c_lock);
   if (imported) {
      bb_surf_imported++;
      if (alloc < bb_surf_smallest)
         bb_surf_smallest = alloc;
   } else if (copied) {
      bb_surf_copied++;
   } else {
      bb_surf_refused++;
   }
   bool show = shown < 400;
   if (show)
      shown++;
   pthread_mutex_unlock(&bb_c_lock);
   if (show) {
      char f[5] = { (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, 0 };
      for (unsigned i = 0; i < 4; i++)
         if (f[i] < 0x20 || f[i] > 0x7e)
            f[i] = '?';
      bb_log("bb: IOSurface %u %zux%zu, %zu bytes a row, alloc %zu (%#zx), '%s' %u plane(s) [%u]%s: %s", id, w, h, bpr, alloc,
             alloc, f, planes, plane, render_target ? ", render target" : "", result ? result : "-");
   }
}

/* ---- images ------------------------------------------------------------------------------------ */

static void
bb_images(void)
{
   /* QuartzCore, Metal and IOSurface live in the shared cache: their slide is the cache's */
   static const char *wanted[] = { "A04sMetal.bundle", "/QuartzCore", "/Metal.framework/Metal", "/IOSurface",
                                   "libheroeagl", "OSMesa", "libdrm", "liba04sdrm", "/backboardd", "/libdyld",
                                   "/dyld" };
   uint32_t n = _dyld_image_count();
   for (uint32_t i = 0; i < n; i++) {
      const char *name = _dyld_get_image_name(i);
      if (!name)
         continue;
      for (unsigned k = 0; k < sizeof(wanted) / sizeof(wanted[0]); k++)
         if (strstr(name, wanted[k])) {
            bb_log("IMAGE %p slide %#lx %s", (const void *)_dyld_get_image_header(i),
                   (unsigned long)_dyld_get_image_vmaddr_slide(i), name);
            break;
         }
   }
}

/* ---- the watchdog thread ------------------------------------------------------------------------ */

static unsigned
bb_env_u(const char *name, unsigned dflt)
{
   const char *e = getenv(name);
   return e && *e ? (unsigned)atoi(e) : dflt;
}

static void
bb_state(const char *name, const char *rest)
{
   const char *boot = getenv("A04S_BB_BOOT");
   char path[192], line[512];
   snprintf(path, sizeof(path), BB_DIR "/%s", name);
   int n = snprintf(line, sizeof(line), "%s %s\n", boot ? boot : "?", rest);
   int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
   if (fd >= 0) {
      (void)!write(fd, line, (size_t)n);
      fsync(fd);
      close(fd);
   }
}

static void
bb_fall_back(int log_fd, const char *why)
{
   bb_state("fallback", why);
   char mode[512];
   snprintf(mode, sizeof(mode), "%d metal-fallback %s\n", getpid(), why);
   int fd = open(BB_DIR "/mode", O_WRONLY | O_CREAT | O_TRUNC, 0666);
   if (fd >= 0) {
      (void)!write(fd, mode, strlen(mode));
      fsync(fd);
      close(fd);
   }
   bool leave = bb_env_u("A04S_BB_FALLBACK_EXIT", 1) != 0;
   bb_log("FALLBACK: %s. Recorded for this boot; %s", why,
          leave ? "backboardd ends now, and launchd restarts it on OpenGL ES" : "A04S_BB_FALLBACK_EXIT=0: it stays");
   bb_flush(log_fd, true);
   if (leave)
      _exit(75);
}

/* ---- boot 5: the in-flight cap, memory, and how backboardd ends --------------------------------- */

static uint64_t bb_cap_waits, bb_cap_ns, bb_cap_gave_up;     /* this window (bgmtl.m's A04S_MAX_INFLIGHT) */

void
bgmtl_note_inflight_wait(uint64_t ns, int gave_up)
{
   if (!atomic_load(&bb_on))
      return;
   pthread_mutex_lock(&bb_c_lock);
   bb_cap_waits++;
   bb_cap_ns += ns;
   bool first_give_up = gave_up && bb_cap_gave_up++ == 0;
   pthread_mutex_unlock(&bb_c_lock);
   if (first_give_up)
      bb_log("bb: a commit waited %.1f s for one of the A04S_MAX_INFLIGHT slots and went ahead without one", ns / 1e9);
}

/* ---- boot 7: where a command buffer's time goes ------------------------------------------------------- */

/* bgmtl.m's six parts of each command buffer (its bgmtl_note_timing comment), summed and maxed per stats window and
 * logged as a "bb time" line after "bb stats". Boot 6 ran two minutes at 2.2 s per command buffer with no pipeline
 * being built, and its stats could not say whether that was the CPU, the GPU or the completion queue. */
#define BB_TIMING_PARTS 6
static uint64_t bb_time_n, bb_time_sum[BB_TIMING_PARTS], bb_time_max[BB_TIMING_PARTS];

void
bgmtl_note_timing(const uint64_t parts[BB_TIMING_PARTS])
{
   if (!atomic_load(&bb_on))
      return;
   pthread_mutex_lock(&bb_c_lock);
   bb_time_n++;
   for (unsigned i = 0; i < BB_TIMING_PARTS; i++) {
      bb_time_sum[i] += parts[i];
      if (parts[i] > bb_time_max[i])
         bb_time_max[i] = parts[i];
   }
   pthread_mutex_unlock(&bb_c_lock);
}

/* phys_footprint (what jetsam weighs; it counts IOKit memory mapped into the process, so HeroGPU's buffers too) and its peak */
static void
bb_footprint(double *mb, double *peak_mb)
{
   task_vm_info_data_t vm;
   mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
   *mb = *peak_mb = 0;
   if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) != KERN_SUCCESS)
      return;
   *mb = vm.phys_footprint / 1048576.0;
   *peak_mb = n >= TASK_VM_INFO_REV1_COUNT ? vm.ledger_phys_footprint_peak / 1048576.0 : *mb;
}

/* A04sMTLDevice (M6b boot 7): what one pipeline did to memory. a04s_bb_footprint_mb before it; after it, the footprint,
 * malloc's bytes in use and the bytes its zones hold (in use plus freed but still resident: the difference is
 * fragmentation), and, unless A04S_PIPE_RELIEF=0, what malloc_zone_pressure_relief gave back first (-1 when off).
 * Boot 6's footprint grew by 2-3 MB with each pipeline and never came down; these say whether that was live memory or
 * freed memory malloc still held. */
double
a04s_bb_footprint_mb(void)
{
   double mb, peak;
   bb_footprint(&mb, &peak);
   return mb;
}

void
a04s_bb_memory(double *footprint_mb, double *in_use_mb, double *held_mb, double *relieved_mb)
{
   static int relief = -1;
   if (relief < 0)
      relief = !(getenv("A04S_PIPE_RELIEF") && getenv("A04S_PIPE_RELIEF")[0] == '0');
   *relieved_mb = relief ? malloc_zone_pressure_relief(NULL, 0) / 1048576.0 : -1;
   malloc_statistics_t ms = { 0 };
   malloc_zone_statistics(NULL, &ms);
   *in_use_mb = ms.size_in_use / 1048576.0;
   *held_mb = ms.size_allocated / 1048576.0;
   *footprint_mb = a04s_bb_footprint_mb();
}

/* backboardd's jetsam limit, if the kernel tells a process its own (memorystatus_control, GET_MEMLIMIT_PROPERTIES) */
static void
bb_memlimit(char *out, size_t size)
{
   struct { int32_t active; uint32_t active_attr; int32_t inactive; uint32_t inactive_attr; } props = { 0, 0, 0, 0 };
   int (*mc)(uint32_t, int32_t, uint32_t, void *, size_t) =
      (int (*)(uint32_t, int32_t, uint32_t, void *, size_t))dlsym(RTLD_DEFAULT, "memorystatus_control");
   if (!mc) {
      snprintf(out, size, "unknown (no memorystatus_control)");
      return;
   }
   if (mc(8 /* MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES */, getpid(), 0, &props, sizeof(props)) != 0) {
      snprintf(out, size, "unknown (memorystatus_control: %s)", strerror(errno));
      return;
   }
   snprintf(out, size, "%d MB active%s, %d MB inactive%s", props.active, props.active_attr & 1 ? " (fatal)" : "",
            props.inactive, props.inactive_attr & 1 ? " (fatal)" : "");
}

/* A line written straight to the log from a signal handler: no locks, no stdio, no allocation. Lines still queued for
 * the log thread may be lost; this one is not. A jetsam kill (SIGKILL) cannot be caught: then the last memory lines
 * are the evidence. */
static int bb_sig_fd = -1;
static struct sigaction bb_sig_old[NSIG];
static const int bb_sigs[] = { SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGBUS, SIGSEGV, SIGILL, SIGFPE, SIGSYS, SIGTRAP };

static size_t
bb_put(char *b, size_t n, size_t cap, const char *s)
{
   while (*s && n < cap)
      b[n++] = *s++;
   return n;
}

static size_t
bb_put_num(char *b, size_t n, size_t cap, unsigned long long v, unsigned base)
{
   char d[24];
   size_t k = 0;
   do {
      d[k++] = "0123456789abcdef"[v % base];
      v /= base;
   } while (v && k < sizeof(d));
   while (k && n < cap)
      b[n++] = d[--k];
   return n;
}

static void
bb_sig_write(const char *what, int sig, siginfo_t *si, void *ucv)
{
   if (bb_sig_fd < 0)
      return;
   char b[400];
   const size_t cap = sizeof(b) - 1;
   size_t n = 0;
   double t = a04s_now();
   unsigned long long whole = (unsigned long long)t, ms = (unsigned long long)((t - (double)whole) * 1000);
   n = bb_put(b, n, cap, "[backboardd ");
   n = bb_put_num(b, n, cap, (unsigned long long)getpid(), 10);
   n = bb_put(b, n, cap, " +");
   n = bb_put_num(b, n, cap, whole, 10);
   n = bb_put(b, n, cap, ms < 10 ? ".00" : ms < 100 ? ".0" : ".");
   n = bb_put_num(b, n, cap, ms, 10);
   n = bb_put(b, n, cap, "s] bb: ");
   n = bb_put(b, n, cap, what);
   if (sig) {
      n = bb_put(b, n, cap, " ");
      n = bb_put_num(b, n, cap, (unsigned long long)sig, 10);
      n = bb_put(b, n, cap, " (SIG");
      n = bb_put(b, n, cap, sig < NSIG && sys_signame[sig] ? sys_signame[sig] : "?");
      n = bb_put(b, n, cap, ")");
   }
   if (si) {
      n = bb_put(b, n, cap, ", code ");
      n = bb_put_num(b, n, cap, (unsigned long long)(unsigned)si->si_code, 10);
      if (si->si_code == SI_USER || si->si_code == SI_QUEUE) {
         n = bb_put(b, n, cap, ", sent by pid ");
         n = bb_put_num(b, n, cap, (unsigned long long)si->si_pid, 10);
      } else {
         n = bb_put(b, n, cap, ", address 0x");
         n = bb_put_num(b, n, cap, (unsigned long long)(uintptr_t)si->si_addr, 16);
      }
   }
#if defined(__arm64__)
   ucontext_t *uc = (ucontext_t *)ucv;
   if (uc && uc->uc_mcontext && si && si->si_code != SI_USER && si->si_code != SI_QUEUE) {
#if defined(__darwin_arm_thread_state64_get_pc)
      unsigned long long pc = (unsigned long long)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
      unsigned long long lr = (unsigned long long)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
#else
      unsigned long long pc = uc->uc_mcontext->__ss.__pc, lr = uc->uc_mcontext->__ss.__lr;
#endif
      n = bb_put(b, n, cap, ", pc 0x");
      n = bb_put_num(b, n, cap, pc, 16);
      n = bb_put(b, n, cap, ", lr 0x");
      n = bb_put_num(b, n, cap, lr, 16);
      n = bb_put(b, n, cap, " (IMAGE lines above)");
   }
#else
   (void)ucv;
#endif
   b[n++] = '\n';
   (void)!write(bb_sig_fd, b, n);
   fsync(bb_sig_fd);
}

static void
bb_on_signal(int sig, siginfo_t *si, void *uc)
{
   int saved = errno;
   bb_sig_write("signal", sig, si, uc);
   struct sigaction *o = sig > 0 && sig < NSIG ? &bb_sig_old[sig] : NULL;
   if (o && (o->sa_flags & SA_SIGINFO) && o->sa_sigaction) {
      o->sa_sigaction(sig, si, uc);
   } else if (o && o->sa_handler == SIG_IGN) {
      /* backboardd ignores it (it may watch it with a dispatch source instead) */
   } else if (o && o->sa_handler != SIG_DFL && o->sa_handler) {
      o->sa_handler(sig);
   } else {
      /* the default action: put it back and deliver the signal again (a fault re-runs the faulting instruction) */
      struct sigaction dfl;
      memset(&dfl, 0, sizeof(dfl));
      dfl.sa_handler = SIG_DFL;
      sigemptyset(&dfl.sa_mask);
      sigaction(sig, &dfl, NULL);
      if (!si || si->si_code == SI_USER || si->si_code == SI_QUEUE ||
          (sig != SIGSEGV && sig != SIGBUS && sig != SIGILL && sig != SIGFPE && sig != SIGTRAP))
         raise(sig);
   }
   errno = saved;
}

static void
bb_on_exit(void)
{
   bb_sig_write("backboardd is exiting (exit() or a return from main)", 0, NULL, NULL);
}

static void
bb_watch_exit(void)
{
   bb_sig_fd = open(getenv("A04S_METAL_LOG") ? getenv("A04S_METAL_LOG") : BB_DIR "/bb-metal.log", O_WRONLY | O_CREAT | O_APPEND,
                    0666);
   if (bb_sig_fd < 0)
      return;
   for (unsigned i = 0; i < sizeof(bb_sigs) / sizeof(bb_sigs[0]); i++) {
      struct sigaction sa;
      memset(&sa, 0, sizeof(sa));
      sa.sa_sigaction = bb_on_signal;
      sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
      sigemptyset(&sa.sa_mask);
      sigaction(bb_sigs[i], &sa, &bb_sig_old[bb_sigs[i]]);
   }
   atexit(bb_on_exit);
}

static void *
bb_main(void *arg)
{
   (void)arg;
   pthread_setname_np("a04s.bb-metal");
   int log_fd = open(getenv("A04S_METAL_LOG") ? getenv("A04S_METAL_LOG") : BB_DIR "/bb-metal.log",
                     O_WRONLY | O_CREAT | O_APPEND, 0666);
   const unsigned stall_s = bb_env_u("A04S_BB_STALL_S", 20), max_fail = bb_env_u("A04S_BB_MAX_FAILURES", 120);
   const unsigned period = bb_env_u("A04S_BB_STATS_S", 10);
   bool fell_back = false, healthy = false, told_idle = false;
   double last_stats = a04s_now();
   uint64_t w_committed = 0, w_completed = 0, w_failed = 0;
   char limit[160];
   bb_memlimit(limit, sizeof(limit));
   double fp_mb, fp_peak, fp_told;
   bb_footprint(&fp_mb, &fp_peak);
   bb_log("bb: memory: footprint %.1f MB (peak %.1f MB); jetsam limit %s; a line whenever the footprint passes a new 32 MB step",
          fp_mb, fp_peak, limit);
   fp_told = fp_mb;
   for (;;) {
      struct timespec until;
      clock_gettime(CLOCK_REALTIME, &until);
      until.tv_sec += 1;
      pthread_mutex_lock(&bb_q_lock);
      if (!bb_q_len && !bb_dumps)
         pthread_cond_timedwait(&bb_q_cond, &bb_q_lock, &until);
      pthread_mutex_unlock(&bb_q_lock);

      uint64_t now = bb_ns();
      pthread_mutex_lock(&bb_c_lock);
      uint64_t first = bb_first_commit, committed = bb_committed, completed = bb_completed, failed = bb_failed;
      double oldest = bb_ring_len ? (now - bb_ring[bb_ring_head]) / 1e9 : 0;
      unsigned outstanding = bb_ring_len, fail_run = bb_fail_run;
      char last_failure[256];
      strlcpy(last_failure, bb_last_failure, sizeof(last_failure));
      pthread_mutex_unlock(&bb_c_lock);

      if (!fell_back && first && outstanding && stall_s && oldest > stall_s) {
         char why[384];
         snprintf(why, sizeof(why), "committed GPU work has not completed in %.0f s (A04S_BB_STALL_S %u); %u command buffers outstanding",
                  oldest, stall_s, outstanding);
         fell_back = true;
         bb_fall_back(log_fd, why);
      }
      if (!fell_back && max_fail && fail_run >= max_fail) {
         char why[384];
         snprintf(why, sizeof(why), "%u command buffers in a row failed (A04S_BB_MAX_FAILURES %u), the last: %s", fail_run,
                  max_fail, last_failure);
         fell_back = true;
         bb_fall_back(log_fd, why);
      }
      if (!healthy && first && (now - first) / 1e9 >= 60 && completed >= 100 && fail_run < 10) {
         healthy = true;
         bb_state("launches", "0");
         bb_log("bb: healthy: %llu command buffers completed in the first %.0f s on Metal; the launch count is reset",
                (unsigned long long)completed, (now - first) / 1e9);
      }
      if (!first && !told_idle && a04s_now() - bb_t_ready > 120) {
         told_idle = true;
         bb_log("bb: no command buffer committed in the 120 s since the device was made (CoreAnimation still building "
                "pipelines, or drawing some other way)");
      }

      bb_footprint(&fp_mb, &fp_peak);
      if (fp_mb >= fp_told + 32) {
         int lvl = 0;
         size_t ln = sizeof(lvl);
         if (sysctlbyname("kern.memorystatus_level", &lvl, &ln, NULL, 0) != 0)
            lvl = -1;
         bb_log("bb: memory: footprint %.1f MB, a new high (peak %.1f MB); %u command buffers outstanding; system memory %d%% free",
                fp_mb, fp_peak, outstanding, lvl);
         fp_told = fp_mb;
      }

      double t = a04s_now();
      if (period && t - last_stats >= period) {
         pthread_mutex_lock(&bb_c_lock);
         uint64_t lat_n = bb_lat_n, lat_sum = bb_lat_sum, lat_max = bb_lat_max, presents = bb_presents;
         unsigned pm = bb_pipes_made, pr = bb_pipes_refused, tr = bb_tex_refused, ds = bb_draw_skipped,
                  cs = bb_clear_skipped, orf = bb_other_refused;
         double ps = bb_pipe_secs;
         unsigned si = bb_surf_imported, sc = bb_surf_copied, sr = bb_surf_refused;
         size_t ss = bb_surf_smallest;
         uint64_t cw = bb_cap_waits, cns = bb_cap_ns, cg = bb_cap_gave_up;
         bb_cap_waits = bb_cap_ns = bb_cap_gave_up = 0;
         char threads[96] = "";
         for (unsigned i = 0; i < bb_commit_nthreads; i++) {
            char one[24];
            snprintf(one, sizeof(one), "%s%llu", i ? "," : "", (unsigned long long)bb_commit_threads[i]);
            strlcat(threads, one, sizeof(threads));
         }
         bb_commit_nthreads = 0;
         bb_surf_imported = bb_surf_copied = bb_surf_refused = 0;
         bb_surf_smallest = SIZE_MAX;
         bb_lat_n = bb_lat_sum = bb_lat_max = 0;
         bb_pipes_made = bb_pipes_refused = 0;
         bb_pipe_secs = 0;
         bb_tex_refused = bb_draw_skipped = bb_clear_skipped = bb_other_refused = 0;
         bb_presents = 0;
         const uint64_t tn = bb_time_n;
         uint64_t tsum[BB_TIMING_PARTS], tmax[BB_TIMING_PARTS];
         memcpy(tsum, bb_time_sum, sizeof(tsum));
         memcpy(tmax, bb_time_max, sizeof(tmax));
         bb_time_n = 0;
         memset(bb_time_sum, 0, sizeof(bb_time_sum));
         memset(bb_time_max, 0, sizeof(bb_time_max));
         pthread_mutex_unlock(&bb_c_lock);
         uint64_t dc = committed - w_committed, dd = completed - w_completed, df = failed - w_failed;
         if (dc || dd || df || pm || pr || outstanding || si || sc || sr)
            bb_log("bb stats %.1f s: %llu committed, %llu completed (%.1f/s), %llu failed, %u outstanding (oldest %.2f s); "
                   "commit to completion avg %.1f ms, max %.1f ms; %llu presents; pipelines %u made, %u refused, %.1f s building; "
                   "textures refused %u, draws skipped %u, clears skipped %u, other refusals %u; IOSurfaces %u imported "
                   "(smallest %zu bytes), %u copied, %u refused; committing threads %s; in-flight cap: %llu waits, %.1f ms waiting, "
                   "%llu gave up; footprint %.1f MB (peak %.1f MB)",
                   t - last_stats, (unsigned long long)dc, (unsigned long long)dd, dd / (t - last_stats),
                   (unsigned long long)df, outstanding, oldest, lat_n ? lat_sum / 1e6 / lat_n : 0, lat_max / 1e6,
                   (unsigned long long)presents, pm, pr, ps, tr, ds, cs, orf, si, si ? ss : 0, sc, sr,
                   threads[0] ? threads : "-", (unsigned long long)cw, cns / 1e6, (unsigned long long)cg, fp_mb, fp_peak);
         if (tn) {
#define BB_T(i) tsum[i] / 1e6 / tn, tmax[i] / 1e6
            bb_log("bb time %llu command buffers, avg/max ms: lock %.1f/%.1f, encode %.1f/%.1f, scheduled handlers %.1f/%.1f, "
                   "completion queue %.1f/%.1f, fence %.1f/%.1f, completion work %.1f/%.1f",
                   (unsigned long long)tn, BB_T(0), BB_T(1), BB_T(2), BB_T(3), BB_T(4), BB_T(5));
#undef BB_T
         }
         w_committed = committed;
         w_completed = completed;
         w_failed = failed;
         last_stats = t;
      }
      bb_flush(log_fd, true);
   }
   return NULL;
}

/* ---- from A04sMTLDevice -------------------------------------------------------------------------- */

/* The device exists in backboardd: logs go through the thread from now on. */
void
a04s_bb_device_ready(const char *name, const char *cache_dir)
{
   if (strcmp(getprogname(), "backboardd") || atomic_load(&bb_on))
      return;
   bb_t_ready = a04s_now();
   if (pthread_create(&bb_thread, NULL, bb_main, NULL) != 0) {
      a04s_log("bb: no watchdog thread (%s): the log stays synchronous and nothing falls back by itself", strerror(errno));
      return;
   }
   atomic_store(&bb_on, 1);
   bb_watch_exit();
   bb_log("bb: backboardd composites on %s (launch %s this boot, uid %d); shader cache %s; watchdog: stall %u s, "
          "%u failures in a row; %s",
          name, getenv("A04S_BB_LAUNCH") ?: "?", getuid(), cache_dir ?: "off", bb_env_u("A04S_BB_STALL_S", 20),
          bb_env_u("A04S_BB_MAX_FAILURES", 120),
          bb_env_u("A04S_BB_FALLBACK_EXIT", 1) ? "a fallback ends backboardd" : "a fallback only logs (A04S_BB_FALLBACK_EXIT=0)");
   bb_images();
}

/* The gate let backboardd in, but no device came of it: the render server stays on OpenGL ES. */
void
a04s_bb_device_failed(const char *why)
{
   if (strcmp(getprogname(), "backboardd"))
      return;
   char mode[512];
   snprintf(mode, sizeof(mode), "%d eagl the device could not be made: %s\n", getpid(), why);
   int fd = open(BB_DIR "/mode", O_WRONLY | O_CREAT | O_TRUNC, 0666);
   if (fd >= 0) {
      (void)!write(fd, mode, strlen(mode));
      close(fd);
   }
}
