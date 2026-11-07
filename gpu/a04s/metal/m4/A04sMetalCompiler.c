/*
 * Galaxy A04s, Metal track M4: the LOGGING compiler plug-in. MTLCompiler.framework dlopens the
 * driver's plug-in (the path our device gives MTLCompiler) and looks up MTLCompilerCreate,
 * MTLCompilerDelete, MTLCompilerBuildRequestWithOptions (else MTLCompilerBuildRequest),
 * MTLCompilerBuildRequestWithSerializedBitcode, MTLCompilerReleaseReply and, on one branch, five
 * AIRNT* functions (iOS 16.7's MTLCompilerPluginInterface::init). Their argument lists are not
 * known yet: that is what this records. Each entry point logs its first twelve register/stack
 * words, and dumps up to 256 bytes behind each one that is a readable user address.
 *
 * It compiles nothing: a build request returns 1 after logging, and the caller's next step is
 * logged by the device (or is a crash, which comes after these lines are on disk).
 */
#include <stdint.h>
#include <stdlib.h>

#include "a04s_metal_log.h"

#define EXPORT __attribute__((visibility("default")))
#define ARGS uintptr_t a0, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, \
	     uintptr_t a6, uintptr_t a7, uintptr_t a8, uintptr_t a9, uintptr_t a10, uintptr_t a11

static void
log_args(const char *fn, uintptr_t a[12], int dump)
{
	a04s_log("plug-in %s(%#lx, %#lx, %#lx, %#lx, %#lx, %#lx, %#lx, %#lx | %#lx, %#lx, %#lx, %#lx)", fn,
		 (unsigned long)a[0], (unsigned long)a[1], (unsigned long)a[2], (unsigned long)a[3],
		 (unsigned long)a[4], (unsigned long)a[5], (unsigned long)a[6], (unsigned long)a[7],
		 (unsigned long)a[8], (unsigned long)a[9], (unsigned long)a[10], (unsigned long)a[11]);
	if (!dump)
		return;
	for (int i = 0; i < 8; i++) {
		char what[16];
		snprintf(what, sizeof(what), "arg%d", i);
		a04s_log_bytes(what, a[i], 128);
	}
}

#define ENTRY(name, dump, ret) \
	EXPORT uintptr_t name(ARGS) \
	{ \
		uintptr_t a[12] = { a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 }; \
		log_args(#name, a, dump); \
		return ret; \
	}

static uint8_t compiler_handle[64] = "A04sMetalCompiler M4 handle";

EXPORT uintptr_t
MTLCompilerCreate(ARGS)
{
	uintptr_t a[12] = { a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 };
	log_args("MTLCompilerCreate", a, 1);
	return (uintptr_t)compiler_handle;
}

ENTRY(MTLCompilerDelete, 0, 0)
ENTRY(MTLCompilerBuildRequest, 1, 1)
ENTRY(MTLCompilerBuildRequestWithOptions, 1, 1)
ENTRY(MTLCompilerBuildRequestWithSerializedBitcode, 1, 1)
ENTRY(MTLCompilerReleaseReply, 0, 0)
ENTRY(AIRNTEmitPipelineImage, 1, 1)
ENTRY(AIRNTInitCompilationContext, 1, 0)
ENTRY(AIRNTDisposeCompilationContext, 0, 0)
ENTRY(AIRNTInit, 1, 0)
ENTRY(AIRNTDispose, 0, 0)

__attribute__((constructor)) static void
loaded(void)
{
	a04s_log("plug-in A04sMetalCompiler loaded");
}
