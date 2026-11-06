/*
 * The libdrm of xf86drm.h (see there): Linux's DRM requests to the kernel's GPU driver as calls
 * of its IOKit user client. A request's number (the low byte of the ioctl code) is the call's
 * selector, its structure goes in and comes back as it is; a buffer's memory is the client
 * memory of the type that is the buffer's handle.
 *
 * Two of the kernel's services speak so, one for each GPU; a phone has one of them:
 *   HakiosGPU    the POCO X5 Pro's Adreno, as Linux's msm driver, for Mesa's freedreno
 *                (drivers/gpu/hakios.gpu.cpp)
 *   HakiosMali   the Galaxy S9's Mali-G72, as Linux's panfrost driver, for Mesa's panfrost
 *                (drivers/gpu/hakios.mali.cpp)
 * drmOpenWithType() opens the one asked for by the name of its Linux driver, and drmGetVersion()
 * answers with that name: it is what Mesa's panfrost picks its backend by (pan_kmod.c). Every
 * request of freedreno's goes to the kernel as it is. Of panfrost's, two are seen to here first,
 * because HakiosMali does not do them as Linux's driver does (submit(), wait_buffer()), and its
 * fences are made here, of the kernel's job numbers (the sync objects at the end).
 *
 * The driver knows its device by a file descriptor. It gets one that means nothing (/dev/null):
 * there is one GPU and one connection to it in a process.
 */
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <IOKit/IOKitLib.h>

#include "xf86drm.h"
#include "drm-uapi/panfrost_drm.h"

#define HAKIOS_GPU_SURFACE     0x7e            /* the request that is not Linux's (both services) */
#define HAKIOS_GPU_DESCRIBE    0xffffffffu     /* ... asked only what the buffer would be like */
#define HAKIOS_MALI_WAIT       0x7d            /* HakiosMali's own: wait for a job by its number */

/* The kernel's services, by the names of the Linux drivers they stand in for. */
static const struct service {
	const char *name;               /* Linux's: what the driver opens, and what drmGetVersion() says */
	const char *service;            /* the kernel's */
	int major, minor;               /* the version of Linux's interface that it has */
	const char *desc;
} services[] = {
	/* 1.7: buffers at addresses the kernel chooses and tells ("softpin"), nothing newer */
	{ "msm", "HakiosGPU", 1, 7, "Adreno on Darwin" },
	/*
	 * 1.2: buffers that grow on a fault and buffers that are not run (1.1; the kernel takes the
	 * flags and makes every buffer whole), and the AFBC features (1.2; the kernel answers 0, which
	 * Mesa takes as AFBC supported: see hakios_mali_parameter()).
	 * Not 1.3: Mesa would then ask for the frequency of the GPU's timestamps, as a parameter it
	 * must have, and the kernel does not answer that one.
	 */
	{ "panfrost", "HakiosMali", 1, 2, "Mali on Darwin" },
};
#define PANFROST        (&services[1])

static const struct service *opened;
static io_connect_t connection;
static int connection_fd = -1;

int
drmOpenWithType(const char *name, const char *busid, int type)
{
	const struct service *wanted = NULL;
	io_service_t service;

	(void)busid;
	(void)type;
	for (size_t i = 0; i < sizeof(services) / sizeof(services[0]); i++) {
		if (strcmp(name, services[i].name) == 0) {
			wanted = &services[i];
		}
	}
	if (wanted == NULL || (opened != NULL && opened != wanted)) {
		return -1;
	}
	if (connection_fd >= 0) {
		return dup(connection_fd);
	}
	service = IOServiceGetMatchingService(0, IOServiceMatching(wanted->service));
	if (service == 0) {
		return -1;
	}
	if (IOServiceOpen(service, mach_task_self(), 0, &connection) != 0) {
		IOObjectRelease(service);
		return -1;
	}
	IOObjectRelease(service);
	opened = wanted;
	connection_fd = open("/dev/null", O_RDWR);
	return dup(connection_fd);
}

static int
call(unsigned number, void *data, size_t size)
{
	size_t returned = size;
	kern_return_t result = IOConnectCallStructMethod(connection, number, data, size, data, &returned);

	switch (result) {
	case 0:
		return 0;
	case kIOReturnNoMemory:
		return ENOMEM;
	case kIOReturnBadArgument:
		return EINVAL;
	case kIOReturnTimeout:
		return ETIMEDOUT;
	case kIOReturnBusy:
		return EBUSY;
	case kIOReturnNotFound:
		return ENOENT;
	case kIOReturnUnsupported:
		return ENOSYS;
	default:
		return EIO;
	}
}

static int submit(struct drm_panfrost_submit *request);
static int wait_buffer(struct drm_panfrost_wait_bo *request);

/* Opt-in for the pinned HakiosMali no-purge implementation. Its MADVISE
 * handler unconditionally sets retained=1, without checking/changing a BO or
 * waiting for the GPU. Keep those advisory calls local; waits/submissions and
 * real mappings still go through IOKit. HMD is short to fit boot_args.
 * Revisit this contract if the kernel ever starts purging BOs.
 */
static pthread_once_t madvise_once = PTHREAD_ONCE_INIT;
static bool madvise_local_enabled;

static void
init_local_madvise(void)
{
	const char *value = getenv("HMD");
	madvise_local_enabled = value != NULL && strcmp(value, "1") == 0;
}

static bool
local_madvise(void *arg, size_t size)
{
	static uint32_t saved;
	_Static_assert(sizeof(struct drm_panfrost_madvise) == 12, "MADVISE ABI size");
	_Static_assert(offsetof(struct drm_panfrost_madvise, retained) == 8, "MADVISE ABI field");
	pthread_once(&madvise_once, init_local_madvise);
	if (!madvise_local_enabled || arg == NULL || size != sizeof(struct drm_panfrost_madvise)) return false;
	((struct drm_panfrost_madvise *)arg)->retained = 1;
	uint32_t count = __atomic_add_fetch(&saved, 1, __ATOMIC_RELAXED);
	if (count == 1 || count == 1024) {
		fprintf(stderr, "hakios-drm: HMD=1: %u no-purge MADVISE requests answered locally\n", count);
	}
	return true;
}

int
drmIoctl(int fd, unsigned long request, void *arg)
{
	unsigned number = (unsigned)(request & 0xff);
	int error;

	(void)fd;
	if (opened == PANFROST && number == DRM_COMMAND_BASE + DRM_PANFROST_SUBMIT) {
		error = submit(arg);
	} else if (opened == PANFROST && number == DRM_COMMAND_BASE + DRM_PANFROST_WAIT_BO) {
		error = wait_buffer(arg);
	} else if (opened == PANFROST && number == DRM_COMMAND_BASE + DRM_PANFROST_MADVISE &&
	    local_madvise(arg, IOCPARM_LEN(request))) {
		error = 0;
	} else {
		error = call(number, arg, IOCPARM_LEN(request));
	}
	if (error != 0) {
		errno = error;
		return -1;
	}
	return 0;
}

int
drmCommandWrite(int fd, unsigned long index, const void *data, unsigned long size)
{
	(void)fd;
	return -call((unsigned)(DRM_COMMAND_BASE + index), (void *)(uintptr_t)data, size);
}

int
drmCommandWriteRead(int fd, unsigned long index, void *data, unsigned long size)
{
	(void)fd;
	return -call((unsigned)(DRM_COMMAND_BASE + index), data, size);
}

/* The driver calls itself what Linux's is called, and is of the version whose interface it has. */
drmVersionPtr
drmGetVersion(int fd)
{
	drmVersionPtr version;

	(void)fd;
	if (opened == NULL) {
		errno = ENODEV;
		return NULL;
	}
	version = calloc(1, sizeof(*version));
	if (version != NULL) {
		version->version_major = opened->major;
		version->version_minor = opened->minor;
		version->name = strdup(opened->name);
		version->name_len = (int)strlen(opened->name);
		version->date = strdup("");
		version->desc = strdup(opened->desc);
		version->desc_len = (int)strlen(opened->desc);
	}
	return version;
}

void
drmFreeVersion(drmVersionPtr version)
{
	if (version != NULL) {
		free(version->name);
		free(version->date);
		free(version->desc);
		free(version);
	}
}

int
drmGetCap(int fd, uint64_t capability, uint64_t *value)
{
	(void)fd;
	(void)capability;
	*value = 0;
	return 0;
}

int
drmCloseBufferHandle(int fd, uint32_t handle)
{
	struct drm_gem_close request = { .handle = handle };

	return drmIoctl(fd, DRM_IOCTL_GEM_CLOSE, &request);
}

void *
hakios_drm_map(int fd, uint32_t handle, uint64_t size)
{
	mach_vm_address_t address = 0;
	mach_vm_size_t mapped = 0;

	(void)fd;
	(void)size;
	/*
	 * Linux gives freedreno and panfrost their buffers write-combined, with no cache of this
	 * processor's between the program and the memory the GPU sees. So do the kernel's drivers
	 * here: the memory is made that way, and this mapping is as the memory is.
	 */
	if (IOConnectMapMemory64(connection, handle, mach_task_self(), &address, &mapped, kIOMapAnywhere) != 0) {
		return (void *)-1;              /* mmap()'s MAP_FAILED */
	}
	return (void *)(uintptr_t)address;
}

void
hakios_drm_unmap(int fd, uint32_t handle, void *address)
{
	(void)fd;
	IOConnectUnmapMemory64(connection, handle, mach_task_self(), (mach_vm_address_t)(uintptr_t)address);
}

int
hakios_drm_surface(int fd, struct hakios_drm_surface *surface)
{
	int error;

	(void)fd;
	surface->handle = HAKIOS_GPU_DESCRIBE;
	error = call(HAKIOS_GPU_SURFACE, surface, sizeof(*surface));
	if (error != 0) {
		errno = error;
		return -1;
	}
	return 0;
}

int
drmPrimeFDToHandle(int fd, int surface, uint32_t *handle)
{
	struct hakios_drm_surface request = { .surface = (uint32_t)surface };
	int error = call(HAKIOS_GPU_SURFACE, &request, sizeof(request));

	(void)fd;
	if (error != 0) {
		errno = error;
		return -1;
	}
	*handle = request.handle;
	return 0;
}

static int
none(void)
{
	errno = ENOSYS;
	return -1;
}

/* ---- the Mali's jobs ------------------------------------------------------------------------- */

/*
 * HakiosMali puts every job chain it is given into a queue, which a thread of its own runs one
 * chain at a time, in the order given; a submission comes back at once with the job's number, and
 * its request 0x7d waits for a number (struct mali_wait: the number, then how long at most). Since
 * the jobs end in that order, a job that is done is done with every job before it.
 */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t submitted;              /* the last job number the kernel gave (to this process) */
static uint64_t finished;               /* a job known to be done, and with it every one before it */

/*
 * Mesa's deadlines are moments of its clock (os_time_get_nano(): CLOCK_MONOTONIC on this system),
 * as Linux's are; the kernel's waits take a length of time. What is left until one, then.
 */
static int64_t
left_ns(int64_t deadline)
{
	struct timespec t;
	int64_t now;

	clock_gettime(CLOCK_MONOTONIC, &t);
	now = (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
	return deadline > now ? deadline - now : 0;
}

/*
 * Job `seq` done before `deadline` (INT64_MAX: whenever that is): 0, or an errno. The kernel waits
 * ten seconds at most at a time and is asked again until the deadline; a job does not run for that
 * long, since the kernel resets the GPU under one that has not ended within a second.
 */
static int
wait_job(uint64_t seq, int64_t deadline)
{
	struct {
		uint64_t seq;
		int64_t timeout_ns;
	} request;                              /* struct mali_wait */
	bool done;
	int error;

	pthread_mutex_lock(&lock);
	done = seq <= finished;
	pthread_mutex_unlock(&lock);
	if (done) {
		return 0;
	}
	do {
		request.seq = seq;
		request.timeout_ns = left_ns(deadline);
		error = call(HAKIOS_MALI_WAIT, &request, sizeof(request));
	} while (error == ETIMEDOUT && left_ns(deadline) > 0);
	if (error == 0) {
		pthread_mutex_lock(&lock);
		finished = seq > finished ? seq : finished;
		pthread_mutex_unlock(&lock);
	}
	return error;
}

static uint64_t *syncobj(uint32_t handle);

/*
 * A job chain to the GPU. Linux's driver gives back nothing and puts the job's fence into the sync
 * object out_sync; HakiosMali gives back the job's number where the chain's address was (jc). The
 * address is put back, as Linux leaves it, and the number goes into the sync object. The fences to
 * wait for before the job (in_syncs) are looked at neither here nor by the kernel: they can only
 * stand for jobs given before this one, which the queue has run by the time this one begins.
 */
static int
submit(struct drm_panfrost_submit *request)
{
	uint64_t chain = request->jc, seq, *fence;
	int error = call(DRM_COMMAND_BASE + DRM_PANFROST_SUBMIT, request, sizeof(*request));

	if (error != 0) {
		return error;
	}
	seq = request->jc;
	request->jc = chain;
	pthread_mutex_lock(&lock);
	submitted = seq > submitted ? seq : submitted;
	if (request->out_sync != 0 && (fence = syncobj(request->out_sync)) != NULL) {
		*fence = seq;
	}
	pthread_mutex_unlock(&lock);
	return 0;
}

/*
 * Whether the GPU is done with a buffer. HakiosMali waits for the last job that named it, for a
 * length of time; Linux's timeout_ns is a moment (panfrost_drm.h: "absolute"), which panfrost gives
 * as 0 (only a look) or INT64_MAX (until it is done).
 */
static int
wait_buffer(struct drm_panfrost_wait_bo *request)
{
	struct drm_panfrost_wait_bo asked = *request;
	int error;

	do {
		asked.timeout_ns = left_ns(request->timeout_ns);
		error = call(DRM_COMMAND_BASE + DRM_PANFROST_WAIT_BO, &asked, sizeof(asked));
	} while (error == ETIMEDOUT && left_ns(request->timeout_ns) > 0);
	return error;
}

/* ---- sync objects ---------------------------------------------------------------------------- */

/*
 * Linux's fences that a program holds by a handle. Here, for panfrost, each is the number of the
 * job it waits for, kept in this process: the kernel has no fences, it has numbers. 0 is no job,
 * nothing to wait for -- a sync object made signalled, and one made without a fence (Linux would
 * refuse to wait on that, which panfrost never asks). Waiting for several is waiting for the
 * highest of their numbers (all of them) or the lowest (any), since the jobs end in order.
 * freedreno waits by requests of its own and has none of these, as before (ENOSYS).
 */
#define SYNCOBJ_FREE    UINT64_MAX
static uint64_t *syncobjs;              /* handle n is syncobjs[n - 1]: its job, or SYNCOBJ_FREE */
static uint32_t syncobj_count;

/* (with the lock held) NULL: no such sync object */
static uint64_t *
syncobj(uint32_t handle)
{
	if (handle == 0 || handle > syncobj_count || syncobjs[handle - 1] == SYNCOBJ_FREE) {
		return NULL;
	}
	return &syncobjs[handle - 1];
}

int
drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle)
{
	uint32_t i;

	(void)fd;
	(void)flags;            /* (signalled or without a fence: no job either way) */
	if (opened != PANFROST) {
		return none();
	}
	pthread_mutex_lock(&lock);
	for (i = 0; i < syncobj_count && syncobjs[i] != SYNCOBJ_FREE; i++) {
	}
	if (i == syncobj_count) {
		uint32_t count = syncobj_count != 0 ? 2 * syncobj_count : 64;
		uint64_t *grown = realloc(syncobjs, count * sizeof(*grown));

		if (grown == NULL) {
			pthread_mutex_unlock(&lock);
			errno = ENOMEM;
			return -1;
		}
		for (uint32_t k = syncobj_count; k < count; k++) {
			grown[k] = SYNCOBJ_FREE;
		}
		syncobjs = grown;
		syncobj_count = count;
	}
	syncobjs[i] = 0;
	*handle = i + 1;
	pthread_mutex_unlock(&lock);
	return 0;
}

int
drmSyncobjDestroy(int fd, uint32_t handle)
{
	uint64_t *fence;

	(void)fd;
	if (opened != PANFROST) {
		return none();
	}
	pthread_mutex_lock(&lock);
	if ((fence = syncobj(handle)) != NULL) {
		*fence = SYNCOBJ_FREE;
	}
	pthread_mutex_unlock(&lock);
	if (fence == NULL) {
		errno = EINVAL;
		return -1;
	}
	return 0;
}

int
drmSyncobjReset(int fd, const uint32_t *handles, uint32_t count)
{
	uint64_t *fence;

	(void)fd;
	if (opened != PANFROST) {
		return none();
	}
	pthread_mutex_lock(&lock);
	for (uint32_t i = 0; i < count; i++) {
		if ((fence = syncobj(handles[i])) != NULL) {
			*fence = 0;
		}
	}
	pthread_mutex_unlock(&lock);
	return 0;
}

/* As libdrm's: 0, or minus an errno (ETIME: not done by the deadline, a moment of Mesa's clock). */
int
drmSyncobjWait(int fd, uint32_t *handles, unsigned count, int64_t timeout_nsec, unsigned flags,
    uint32_t *first_signaled)
{
	bool all = (flags & DRM_SYNCOBJ_WAIT_FLAGS_WAIT_ALL) != 0;
	uint64_t seq = 0, *fence;
	unsigned first = 0;
	int error;

	(void)fd;
	if (opened != PANFROST) {
		return -ENOSYS;
	}
	pthread_mutex_lock(&lock);
	for (unsigned i = 0; i < count; i++) {
		if ((fence = syncobj(handles[i])) == NULL) {
			pthread_mutex_unlock(&lock);
			return -EINVAL;
		}
		if (i == 0 || (all ? *fence > seq : *fence < seq)) {
			seq = *fence;
			first = i;
		}
	}
	pthread_mutex_unlock(&lock);
	error = wait_job(seq, timeout_nsec);
	if (error != 0) {
		return error == ETIMEDOUT ? -ETIME : -error;
	}
	if (first_signaled != NULL) {
		*first_signaled = first;
	}
	return 0;
}

/*
 * A sync object's fence as a file descriptor (a "sync file"): panfrost makes one of its context's
 * sync object for every fence it hands out, and takes it into a new sync object at once
 * (pan_fence.c). Here it is another descriptor of /dev/null, with the job number kept beside its
 * number. The program closes it when it likes, without a word, so a number that comes back may be
 * another descriptor by then: one made here again (the entry is made anew whenever a number is
 * made here, so it is the newest), or one that was not made here at all, which is taken for the
 * last job given to the GPU so far -- later than the one meant, if anything, never earlier.
 */
#define SYNC_FILES      64
static struct {
	bool used;
	int fd;
	uint64_t seq;
} sync_files[SYNC_FILES];
static unsigned sync_file_next;

int
drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd)
{
	uint64_t *fence;
	int file;

	(void)fd;
	if (opened != PANFROST) {
		return none();
	}
	if ((file = fcntl(connection_fd, F_DUPFD_CLOEXEC, 0)) < 0) {
		return -1;
	}
	pthread_mutex_lock(&lock);
	if ((fence = syncobj(handle)) == NULL) {
		pthread_mutex_unlock(&lock);
		close(file);
		errno = EINVAL;
		return -1;
	}
	for (unsigned i = 0; i < SYNC_FILES; i++) {
		if (sync_files[i].used && sync_files[i].fd == file) {
			sync_files[i].used = false;     /* (a number made here before, closed since) */
		}
	}
	sync_files[sync_file_next % SYNC_FILES].used = true;
	sync_files[sync_file_next % SYNC_FILES].fd = file;
	sync_files[sync_file_next % SYNC_FILES].seq = *fence;
	sync_file_next++;
	pthread_mutex_unlock(&lock);
	*sync_file_fd = file;
	return 0;
}

int
drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd)
{
	uint64_t *fence, seq;

	(void)fd;
	if (opened != PANFROST) {
		return none();
	}
	pthread_mutex_lock(&lock);
	if ((fence = syncobj(handle)) == NULL) {
		pthread_mutex_unlock(&lock);
		errno = EINVAL;
		return -1;
	}
	seq = submitted;
	for (unsigned i = 0; i < SYNC_FILES; i++) {
		if (sync_files[i].used && sync_files[i].fd == sync_file_fd) {
			seq = sync_files[i].seq;
		}
	}
	*fence = seq;
	pthread_mutex_unlock(&lock);
	return 0;
}

/*
 * Buffers and sync objects as file descriptors of their own, for handing them to other programs and
 * drivers, and timelines (panthor's): none of that here.
 */
#define NONE(name, ...) int name(__VA_ARGS__) { return none(); }
NONE(drmPrimeHandleToFD, __attribute__((unused)) int fd, __attribute__((unused)) uint32_t handle,
    __attribute__((unused)) uint32_t flags, __attribute__((unused)) int *prime_fd)
NONE(drmSyncobjFDToHandle, __attribute__((unused)) int fd, __attribute__((unused)) int obj_fd,
    __attribute__((unused)) uint32_t *handle)
NONE(drmSyncobjHandleToFD, __attribute__((unused)) int fd, __attribute__((unused)) uint32_t handle,
    __attribute__((unused)) int *obj_fd)
NONE(drmSyncobjTimelineWait, __attribute__((unused)) int fd, __attribute__((unused)) uint32_t *handles,
    __attribute__((unused)) uint64_t *points, __attribute__((unused)) unsigned count,
    __attribute__((unused)) int64_t timeout_nsec, __attribute__((unused)) unsigned flags,
    __attribute__((unused)) uint32_t *first_signaled)
NONE(drmSyncobjTransfer, __attribute__((unused)) int fd, __attribute__((unused)) uint32_t dst_handle,
    __attribute__((unused)) uint64_t dst_point, __attribute__((unused)) uint32_t src_handle,
    __attribute__((unused)) uint64_t src_point, __attribute__((unused)) uint32_t flags)
