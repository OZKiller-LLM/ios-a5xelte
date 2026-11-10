/*
 * Galaxy A04s, Metal track M6a run 7: texture sampling on the G52, from the simplest case up to
 * QuartzCore's own downsample shader with inputs this file chooses.
 *
 * Run 6 showed CoreAnimation's blur chain on this device: the layer copy (258 x 258) is right,
 * and the first downsample from it (QuartzCore's downsample_4_frag_lph into 68 x 68) is all
 * zero, alpha included. Nothing before M6 sampled a texture on the GPU (M5's quad draws a
 * varying), so each step here adds one thing CoreAnimation's pass has and the first to fail
 * names the cause:
 *
 *   blit         core's quad_vs + blit_fs: a 4x4 texture filled by the CPU, nearest sampler,
 *                texture and sampler in slot 0
 *   blit-gpu     the same, the texture drawn by the GPU first (private BGRA8, as QuartzCore's
 *                off-screen layers are)
 *   ds-like      m5's ds_like_fs: texture in slot 3, sampler in slot 0, offsets and half
 *                weights from constant buffer 1 (setFragmentBytes), a half scale from buffer 6
 *   ds-like-noscale  the same without buffer 6: Metal reads zeros there, so rgb 0 and alpha 1
 *   qc-ds-cpu    QuartzCore's downsample_blur_vert_lph + downsample_4_frag_lph, with
 *                CoreAnimation's vertex layout and the matrix run 6 traced, from a 258x258
 *                texture the CPU filled
 *   qc-ds-gpu    the same from a private 258x258 texture a render pass cleared on the GPU
 *
 * Each prints "M6 RESULT <mode> sample <name>: PASS|FAIL" with the pixels it looked at.
 * QuartzCore's library is read on the phone, as CoreAnimation reads it; nothing of Apple's is
 * in this repository.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "a04s_metal_log.h"

static const char *QC_LIB = "/System/Library/Frameworks/QuartzCore.framework/default.metallib";

/* the colour every source but blit's holds: (0.25, 0.5, 0.75, 1), as BGRA8 bytes */
static const uint8_t COL_BGRA[4] = { 0xbf, 0x80, 0x40, 0xff };

static int g_bad;

static void
result(const char *mode, const char *name, bool ok, const char *fmt, ...)
{
	char detail[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(detail, sizeof(detail), fmt, ap);
	va_end(ap);
	a04s_log("M6 RESULT %s sample %s: %s (%s)", mode, name, ok ? "PASS" : "FAIL", detail);
	if (!ok)
		g_bad++;
}

static id<MTLTexture>
tex2d(id<MTLDevice> dev, MTLPixelFormat f, unsigned w, unsigned h, MTLStorageMode sm, MTLTextureUsage u)
{
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
	td.usage = u;
	td.storageMode = sm;
	return [[dev newTextureWithDescriptor:td] autorelease];
}

static id<MTLRenderPipelineState>
pipeline(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *vs, NSString *fs, MTLPixelFormat f, MTLVertexDescriptor *vd)
{
	MTLRenderPipelineDescriptor *pd = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
	pd.vertexFunction = [[lib newFunctionWithName:vs] autorelease];
	pd.fragmentFunction = [[lib newFunctionWithName:fs] autorelease];
	if (!pd.vertexFunction || !pd.fragmentFunction) {
		a04s_log("  sample: no function %s", pd.vertexFunction ? fs.UTF8String : vs.UTF8String);
		return nil;
	}
	pd.colorAttachments[0].pixelFormat = f;
	if (vd)
		pd.vertexDescriptor = vd;
	NSError *err = nil;
	double t0 = a04s_now();
	id<MTLRenderPipelineState> ps = [[dev newRenderPipelineStateWithDescriptor:pd error:&err] autorelease];
	a04s_log("  sample: pipeline %s + %s: %s in %.1f s%s%s", vs.UTF8String, fs.UTF8String, ps ? "made" : "nil",
		 a04s_now() - t0, err ? ", error: " : "", err ? err.localizedDescription.UTF8String : "");
	return ps;
}

static id<MTLSamplerState>
sampler(id<MTLDevice> dev, MTLSamplerMinMagFilter filter)
{
	MTLSamplerDescriptor *sd = [[[MTLSamplerDescriptor alloc] init] autorelease];
	sd.minFilter = sd.magFilter = filter;
	sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
	return [[dev newSamplerStateWithDescriptor:sd] autorelease];
}

static MTLRenderPassDescriptor *
pass(id<MTLTexture> t, MTLLoadAction load, MTLClearColor clear)
{
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = t;
	rp.colorAttachments[0].loadAction = load;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = clear;
	return rp;
}

static void
run(id<MTLCommandBuffer> cb, const char *what)
{
	double t0 = a04s_now();
	[cb commit];
	[cb waitUntilCompleted];
	a04s_log("  sample %s: completed in %.1f ms, status %ld%s%s", what, (a04s_now() - t0) * 1000, (long)cb.status,
		 cb.error ? ", error: " : "", cb.error ? cb.error.localizedDescription.UTF8String : "");
}

/* how many of n pixels differ from want (4 bytes) by more than tol in any byte, and how many bytes are non-zero */
static unsigned
count_off(const uint8_t *px, unsigned n, const uint8_t *want, unsigned tol, unsigned *nonzero)
{
	unsigned bad = 0, nz = 0;
	for (unsigned i = 0; i < n; i++) {
		bool off = false;
		for (int c = 0; c < 4; c++) {
			nz += px[4 * i + c] != 0;
			if ((unsigned)abs((int)px[4 * i + c] - (int)want[c]) > tol)
				off = true;
		}
		bad += off;
	}
	if (nonzero)
		*nonzero = nz;
	return bad;
}

static void
fill(uint8_t *px, unsigned w, unsigned h, const uint8_t *c, unsigned border)
{
	for (unsigned y = 0; y < h; y++)
		for (unsigned x = 0; x < w; x++) {
			bool edge = x < border || y < border || x >= w - border || y >= h - border;
			for (int k = 0; k < 4; k++)
				px[4 * (y * w + x) + k] = edge ? 0 : c[k];
		}
}

/* ---- blit: core's quad_vs + blit_fs, a 4x4 RGBA8 texture, nearest ------------------------------- */
static void
test_blit(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> core, const char *mode)
{
	id<MTLRenderPipelineState> ps = pipeline(dev, core, @"quad_vs", @"blit_fs", MTLPixelFormatRGBA8Unorm, nil);
	id<MTLTexture> src = tex2d(dev, MTLPixelFormatRGBA8Unorm, 4, 4, MTLStorageModeShared, MTLTextureUsageShaderRead);
	id<MTLTexture> dst = tex2d(dev, MTLPixelFormatRGBA8Unorm, 64, 64, MTLStorageModeShared,
				   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
	id<MTLSamplerState> smp = sampler(dev, MTLSamplerMinMagFilterNearest);
	if (!ps || !src || !dst || !smp) {
		result(mode, "blit", false, "setup: pipeline %d texture %d target %d sampler %d", !!ps, !!src, !!dst, !!smp);
		return;
	}
	uint8_t texels[4 * 4 * 4];
	for (unsigned y = 0; y < 4; y++)
		for (unsigned x = 0; x < 4; x++) {
			uint8_t *p = texels + 4 * (y * 4 + x);
			p[0] = (uint8_t)(40 + 60 * x); p[1] = (uint8_t)(40 + 60 * y); p[2] = 200; p[3] = 255;
		}
	[src replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:16];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass(dst, MTLLoadActionClear, MTLClearColorMake(0, 0, 0, 0))];
	[enc setRenderPipelineState:ps];
	[enc setFragmentTexture:src atIndex:0];
	[enc setFragmentSamplerState:smp atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[enc endEncoding];
	run(cb, "blit");
	static uint8_t px[64 * 64 * 4];
	[dst getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
	unsigned bad = 0;
	for (unsigned y = 0; y < 64; y++)
		for (unsigned x = 0; x < 64; x++)
			bad += count_off(px + 4 * (y * 64 + x), 1, texels + 4 * ((y / 16) * 4 + x / 16), 2, NULL);
	const uint8_t *a = px + 4 * (8 * 64 + 8), *b = px + 4 * (56 * 64 + 40);
	result(mode, "blit", bad == 0 && cb.status == MTLCommandBufferStatusCompleted,
	       "%u of 4096 pixels off; (8,8) %02x%02x%02x%02x want %02x%02x%02x%02x; (40,56) %02x%02x%02x%02x want %02x%02x%02x%02x",
	       bad, a[0], a[1], a[2], a[3], texels[0], texels[1], texels[2], texels[3], b[0], b[1], b[2], b[3],
	       texels[4 * 14], texels[4 * 14 + 1], texels[4 * 14 + 2], texels[4 * 14 + 3]);
}

/* ---- blit-gpu: the source is a private BGRA8 texture the GPU drew (uv_fs) ------------------------- */
static void
test_blit_gpu(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> core, const char *mode)
{
	id<MTLRenderPipelineState> draw = pipeline(dev, core, @"quad_vs", @"uv_fs", MTLPixelFormatBGRA8Unorm, nil);
	id<MTLRenderPipelineState> blit = pipeline(dev, core, @"quad_vs", @"blit_fs", MTLPixelFormatRGBA8Unorm, nil);
	id<MTLTexture> src = tex2d(dev, MTLPixelFormatBGRA8Unorm, 64, 64, MTLStorageModePrivate,
				   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
	id<MTLTexture> dst = tex2d(dev, MTLPixelFormatRGBA8Unorm, 64, 64, MTLStorageModeShared,
				   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
	id<MTLSamplerState> smp = sampler(dev, MTLSamplerMinMagFilterNearest);
	if (!draw || !blit || !src || !dst || !smp) {
		result(mode, "blit-gpu", false, "setup: pipelines %d %d textures %d %d sampler %d", !!draw, !!blit, !!src, !!dst, !!smp);
		return;
	}
	/* one command buffer, two passes: as CoreAnimation draws its layer copy and then samples it */
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> e1 = [cb renderCommandEncoderWithDescriptor:pass(src, MTLLoadActionClear, MTLClearColorMake(0, 0, 0, 0))];
	[e1 setRenderPipelineState:draw];
	[e1 drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[e1 endEncoding];
	id<MTLRenderCommandEncoder> e2 = [cb renderCommandEncoderWithDescriptor:pass(dst, MTLLoadActionClear, MTLClearColorMake(0, 0, 0, 0))];
	[e2 setRenderPipelineState:blit];
	[e2 setFragmentTexture:src atIndex:0];
	[e2 setFragmentSamplerState:smp atIndex:0];
	[e2 drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[e2 endEncoding];
	run(cb, "blit-gpu");
	static uint8_t px[64 * 64 * 4];
	[dst getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
	unsigned bad = 0, nz = 0;
	for (unsigned y = 0; y < 64; y++)
		for (unsigned x = 0; x < 64; x++) {
			uint8_t want[4] = { (uint8_t)((x + 0.5f) / 64 * 255 + 0.5f), (uint8_t)((y + 0.5f) / 64 * 255 + 0.5f), 0, 255 };
			unsigned n1;
			bad += count_off(px + 4 * (y * 64 + x), 1, want, 3, &n1);
			nz += n1;
		}
	const uint8_t *a = px + 4 * (32 * 64 + 32);
	result(mode, "blit-gpu", bad == 0 && cb.status == MTLCommandBufferStatusCompleted,
	       "%u of 4096 pixels off by more than 3, %u bytes non-zero; (32,32) %02x%02x%02x%02x want about 8282 00ff", bad, nz,
	       a[0], a[1], a[2], a[3]);
}

/* ---- ds-like: m5's ds_like_fs, texture slot 3, constant buffers 1 and 6 ---------------------------- */
static void
test_ds_like(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> m5, const char *mode)
{
	id<MTLRenderPipelineState> ps = pipeline(dev, m5, @"ds_quad_vs", @"ds_like_fs", MTLPixelFormatBGRA8Unorm, nil);
	id<MTLTexture> src = tex2d(dev, MTLPixelFormatBGRA8Unorm, 64, 64, MTLStorageModeShared, MTLTextureUsageShaderRead);
	id<MTLSamplerState> smp = sampler(dev, MTLSamplerMinMagFilterLinear);
	if (!ps || !src || !smp) {
		result(mode, "ds-like", false, "setup: pipeline %d texture %d sampler %d", !!ps, !!src, !!smp);
		return;
	}
	static uint8_t texels[64 * 64 * 4];
	fill(texels, 64, 64, COL_BGRA, 0);
	[src replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:texels bytesPerRow:64 * 4];
	struct { float off[8]; float unused[8]; __fp16 w[4]; __fp16 unused2[4]; } taps;
	_Static_assert(sizeof(taps) == 80, "DsTaps is 80 bytes");
	memset(&taps, 0, sizeof(taps));
	const float d = 0.5f / 64;
	const float o[8] = { -d, -d, d, -d, -d, d, d, d };
	memcpy(taps.off, o, sizeof(o));
	for (int k = 0; k < 4; k++)
		taps.w[k] = (__fp16)0.25f;
	const __fp16 scale = (__fp16)1.0f;
	for (int variant = 0; variant < 2; variant++) {
		const char *name = variant ? "ds-like-noscale" : "ds-like";
		id<MTLTexture> dst = tex2d(dev, MTLPixelFormatBGRA8Unorm, 64, 64, MTLStorageModeShared,
					   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass(dst, MTLLoadActionClear, MTLClearColorMake(0, 0, 0, 0))];
		[enc setRenderPipelineState:ps];
		[enc setFragmentTexture:src atIndex:3];
		[enc setFragmentSamplerState:smp atIndex:0];
		[enc setFragmentBytes:&taps length:sizeof(taps) atIndex:1];
		if (!variant)
			[enc setFragmentBytes:&scale length:sizeof(scale) atIndex:6];
		[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		[enc endEncoding];
		run(cb, name);
		static uint8_t px[64 * 64 * 4];
		[dst getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		const uint8_t want[4] = { variant ? 0 : COL_BGRA[0], variant ? 0 : COL_BGRA[1], variant ? 0 : COL_BGRA[2], 0xff };
		unsigned nz, bad = count_off(px, 64 * 64, want, 3, &nz);
		const uint8_t *a = px + 4 * (32 * 64 + 32);
		result(mode, name, bad == 0 && cb.status == MTLCommandBufferStatusCompleted,
		       "%u of 4096 pixels off by more than 3, %u bytes non-zero; (32,32) %02x%02x%02x%02x want %02x%02x%02x%02x", bad, nz,
		       a[0], a[1], a[2], a[3], want[0], want[1], want[2], want[3]);
	}
}

/* ---- qc-ds: QuartzCore's own downsample, CoreAnimation's layout, run 6's numbers ------------------ */
static id<MTLLibrary>
qc_library(id<MTLDevice> dev)
{
	NSError *err = nil;
	NSData *d = [NSData dataWithContentsOfFile:@(QC_LIB) options:NSDataReadingMappedIfSafe error:&err];
	if (!d) {
		a04s_log("  sample: %s: %s", QC_LIB, err ? err.localizedDescription.UTF8String : "unreadable");
		return nil;
	}
	[d retain];
	dispatch_data_t data = dispatch_data_create(d.bytes, d.length, NULL, ^{ [d release]; });
	double t0 = a04s_now();
	id<MTLLibrary> lib = [dev newLibraryWithData:data error:&err];
	dispatch_release(data);
	a04s_log("  sample: library %s (%lu bytes): %s in %.1f s%s%s", QC_LIB, (unsigned long)d.length, lib ? "loaded" : "nil",
		 a04s_now() - t0, err ? ", error: " : "", err ? err.localizedDescription.UTF8String : "");
	return [lib autorelease];
}

static void
test_qc_downsample(id<MTLDevice> dev, id<MTLCommandQueue> q, const char *mode)
{
	id<MTLLibrary> qc = qc_library(dev);
	if (!qc) {
		result(mode, "qc-ds-cpu", false, "QuartzCore's library did not load");
		return;
	}
	/* CoreAnimation's vertex layout (run 6's trace): buffer 1, stride 48; position float4 at 0,
	 * texcoord0 float2 at 16, texcoord1 float2 at 24, colour half4 at 32 */
	MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
	const MTLVertexFormat fmts[4] = { MTLVertexFormatFloat4, MTLVertexFormatFloat2, MTLVertexFormatFloat2, MTLVertexFormatHalf4 };
	const NSUInteger offs[4] = { 0, 16, 24, 32 };
	for (int i = 0; i < 4; i++) {
		vd.attributes[i].format = fmts[i];
		vd.attributes[i].offset = offs[i];
		vd.attributes[i].bufferIndex = 1;
	}
	vd.layouts[1].stride = 48;
	vd.layouts[1].stepFunction = MTLVertexStepFunctionPerVertex;
	vd.layouts[1].stepRate = 1;
	id<MTLRenderPipelineState> ps = pipeline(dev, qc, @"downsample_blur_vert_lph", @"downsample_4_frag_lph", MTLPixelFormatBGRA8Unorm, vd);
	id<MTLSamplerState> smp = sampler(dev, MTLSamplerMinMagFilterLinear);
	if (!ps || !smp) {
		result(mode, "qc-ds-cpu", false, "setup: pipeline %d sampler %d", !!ps, !!smp);
		return;
	}
	/* run 6's downsample draw: a quad from (-1,-1) to (65,65) in the 68x68 target's pixels, texcoords
	 * (-3,-3) to (261,261) in the 258x258 source's, the orthographic matrix and the 1/258 texture scale */
	struct vtx { float pos[4]; float tc0[2]; float tc1[2]; __fp16 col[4]; float pad[2]; } v[4] = {
		{ { -1, -1, 0, 1 }, { -3, -3 }, { 0, 0 }, { 0, 0, 0, 0 }, { 0, 0 } },
		{ { 65, -1, 0, 1 }, { 261, -3 }, { 0, 0 }, { 0, 0, 0, 0 }, { 0, 0 } },
		{ { 65, 65, 0, 1 }, { 261, 261 }, { 0, 0 }, { 0, 0, 0, 0 }, { 0, 0 } },
		{ { -1, 65, 0, 1 }, { -3, 261 }, { 0, 0 }, { 0, 0, 0, 0 }, { 0, 0 } },
	};
	_Static_assert(sizeof(struct vtx) == 48, "CoreAnimation's vertex is 48 bytes");
	const uint16_t idx[6] = { 0, 1, 2, 2, 3, 0 };
	const float mvp[16] = { 2.0f / 68, 0, 0, 0, 0, -2.0f / 68, 0, 0, 0, 0, 0, 0, -64.0f / 68, 64.0f / 68, 0, 1 };
	const float texmat[4] = { 1.0f / 258, 1.0f / 258, 0, 0 };
	/* the fragment stage's u (80 bytes): four tap offsets of half a source texel, weights 0.25 at byte 64 */
	struct { float off[8]; float unused[8]; __fp16 w[4]; __fp16 unused2[4]; } u;
	memset(&u, 0, sizeof(u));
	const float d = 0.5f / 258;
	const float o[8] = { -d, -d, d, -d, -d, d, d, d };
	memcpy(u.off, o, sizeof(o));
	for (int k = 0; k < 4; k++)
		u.w[k] = (__fp16)0.25f;
	const __fp16 edr = (__fp16)1.0f;
	id<MTLBuffer> vb = [[dev newBufferWithBytes:v length:sizeof(v) options:MTLResourceStorageModeShared] autorelease];
	id<MTLBuffer> ib = [[dev newBufferWithBytes:idx length:sizeof(idx) options:MTLResourceStorageModeShared] autorelease];

	static uint8_t texels[258 * 258 * 4];
	fill(texels, 258, 258, COL_BGRA, 1);   /* a one-pixel clear border, as CoreAnimation's layer copy */
	for (int variant = 0; variant < 2; variant++) {
		const char *name = variant ? "qc-ds-gpu" : "qc-ds-cpu";
		id<MTLTexture> src = variant ? tex2d(dev, MTLPixelFormatBGRA8Unorm, 258, 258, MTLStorageModePrivate,
						     MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)
					     : tex2d(dev, MTLPixelFormatBGRA8Unorm, 258, 258, MTLStorageModeShared, MTLTextureUsageShaderRead);
		id<MTLTexture> dst = tex2d(dev, MTLPixelFormatBGRA8Unorm, 68, 68, MTLStorageModeShared,
					   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
		if (!src || !dst) {
			result(mode, name, false, "setup: textures %d %d", !!src, !!dst);
			continue;
		}
		id<MTLCommandBuffer> cb = [q commandBuffer];
		if (variant) {
			/* cleared on the GPU to the same colour (border included) */
			id<MTLRenderCommandEncoder> e0 = [cb renderCommandEncoderWithDescriptor:pass(src, MTLLoadActionClear,
								MTLClearColorMake(0.25, 0.5, 0.75, 1))];
			[e0 endEncoding];
		} else {
			[src replaceRegion:MTLRegionMake2D(0, 0, 258, 258) mipmapLevel:0 withBytes:texels bytesPerRow:258 * 4];
		}
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass(dst, MTLLoadActionClear, MTLClearColorMake(0, 0, 0, 0))];
		[enc setRenderPipelineState:ps];
		[enc setViewport:(MTLViewport){ 0, 0, 68, 68, 0, 1 }];
		[enc setScissorRect:(MTLScissorRect){ 0, 0, 68, 68 }];
		[enc setVertexBuffer:vb offset:0 atIndex:1];
		[enc setVertexBytes:mvp length:sizeof(mvp) atIndex:2];
		[enc setVertexBytes:texmat length:sizeof(texmat) atIndex:3];
		[enc setFragmentTexture:src atIndex:3];
		[enc setFragmentSamplerState:smp atIndex:0];
		[enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
		[enc setFragmentBytes:&edr length:sizeof(edr) atIndex:6];
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
		[enc endEncoding];
		run(cb, name);
		static uint8_t px[68 * 68 * 4];
		[dst getBytes:px bytesPerRow:68 * 4 fromRegion:MTLRegionMake2D(0, 0, 68, 68) mipmapLevel:0];
		/* the inner 60x60 (well inside the quad and the source's border) must be the colour */
		unsigned bad = 0, nz = 0;
		for (unsigned y = 4; y < 64; y++) {
			unsigned n1;
			bad += count_off(px + 4 * (y * 68 + 4), 60, COL_BGRA, 3, &n1);
		}
		count_off(px, 68 * 68, COL_BGRA, 3, &nz);
		const uint8_t *a = px + 4 * (34 * 68 + 34), *b = px + 4 * (1 * 68 + 1);
		result(mode, name, bad == 0 && cb.status == MTLCommandBufferStatusCompleted,
		       "%u of 3600 inner pixels off by more than 3, %u of 18496 bytes non-zero; (34,34) %02x%02x%02x%02x want "
		       "%02x%02x%02x%02x; (1,1) %02x%02x%02x%02x", bad, nz, a[0], a[1], a[2], a[3], COL_BGRA[0], COL_BGRA[1],
		       COL_BGRA[2], COL_BGRA[3], b[0], b[1], b[2], b[3]);
		char path[128];
		snprintf(path, sizeof(path), "/private/var/a04s/m6-%s-%s-68x68.bgra", mode, name);
		FILE *f = fopen(path, "wb");
		if (f) {
			fwrite(px, 1, sizeof(px), f);
			fclose(f);
		}
	}
}

/* ---- run 8: QuartzCore's halves swapped one at a time with m5's look-alikes --------------------------
 *
 * Run 7: m5's ds_like_fs samples a texture in slot 3 with buffers 1 and 6 correctly, and QuartzCore's
 * own pair writes nothing, from a CPU-filled source and from a GPU-cleared one alike. Here every case
 * samples the same private 258x258 source the GPU cleared to the colour (border included, so any
 * coordinate that is a number reads the colour) into a 68x68 target cleared to a SENTINEL, so the
 * target says which of three things happened:
 *   colour    the pair works
 *   sentinel  nothing was drawn there (no primitive reached those pixels, or every fragment was killed)
 *   zero      fragments ran and wrote zero (the texture read zero, or the weights did)
 *
 *   mix-qc-qc           QuartzCore's vertex + QuartzCore's fragment (run 7's qc-ds-gpu, with the sentinel)
 *   mix-qcvs-m5fs       QuartzCore's vertex + m5's ds_q_fs
 *   mix-m5vs-qcfs       m5's ds_q_quad_vs (no attributes) + QuartzCore's fragment
 *   mix-m5attr-m5fs     m5's ds_q_attr_vs (QuartzCore's vertex interface) + m5's ds_q_fs
 *   mix-m5vs-m5fs       m5's ds_q_quad_vs + ds_q_fs: the control, with the 258 source and the 68 target
 */
static const uint8_t SENT_BGRA[4] = { 0x30, 0x20, 0x10, 0x40 };   /* clear (r .0625, g .125, b .1875, a .25) */

static bool
near4(const uint8_t *p, const uint8_t *w)
{
	for (int c = 0; c < 4; c++)
		if (abs((int)p[c] - (int)w[c]) > 3)
			return false;
	return true;
}

static void
test_mix(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> m5, const char *mode)
{
	id<MTLLibrary> qc = qc_library(dev);
	if (!qc)
		a04s_log("  sample: QuartzCore's library did not load; only the m5 pairs run");

	MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
	const MTLVertexFormat fmts[4] = { MTLVertexFormatFloat4, MTLVertexFormatFloat2, MTLVertexFormatFloat2, MTLVertexFormatHalf4 };
	const NSUInteger offs[4] = { 0, 16, 24, 32 };
	for (int i = 0; i < 4; i++) {
		vd.attributes[i].format = fmts[i];
		vd.attributes[i].offset = offs[i];
		vd.attributes[i].bufferIndex = 1;
	}
	vd.layouts[1].stride = 48;
	vd.layouts[1].stepFunction = MTLVertexStepFunctionPerVertex;
	vd.layouts[1].stepRate = 1;

	struct vtx { float pos[4]; float tc0[2]; float tc1[2]; __fp16 col[4]; float pad[2]; } v[4] = {
		{ { -1, -1, 0, 1 }, { -3, -3 }, { 0, 0 }, { 0, 0, 0, 0 }, { 0, 0 } },
		{ { 65, -1, 0, 1 }, { 261, -3 }, { 0, 0 }, { 0, 0, 0, 0 }, { 0, 0 } },
		{ { 65, 65, 0, 1 }, { 261, 261 }, { 0, 0 }, { 0, 0, 0, 0 }, { 0, 0 } },
		{ { -1, 65, 0, 1 }, { -3, 261 }, { 0, 0 }, { 0, 0, 0, 0 }, { 0, 0 } },
	};
	const uint16_t idx[6] = { 0, 1, 2, 2, 3, 0 };
	const float mvp[16] = { 2.0f / 68, 0, 0, 0, 0, -2.0f / 68, 0, 0, 0, 0, 0, 0, -64.0f / 68, 64.0f / 68, 0, 1 };
	const float texmat[4] = { 1.0f / 258, 1.0f / 258, 0, 0 };
	struct { float off[8]; float unused[8]; __fp16 w[4]; __fp16 unused2[4]; } u;
	memset(&u, 0, sizeof(u));
	const float d = 0.5f / 258;
	const float o[8] = { -d, -d, d, -d, -d, d, d, d };
	memcpy(u.off, o, sizeof(o));
	for (int k = 0; k < 4; k++)
		u.w[k] = (__fp16)0.25f;
	const __fp16 edr = (__fp16)1.0f;
	id<MTLBuffer> vb = [[dev newBufferWithBytes:v length:sizeof(v) options:MTLResourceStorageModeShared] autorelease];
	id<MTLBuffer> ib = [[dev newBufferWithBytes:idx length:sizeof(idx) options:MTLResourceStorageModeShared] autorelease];
	id<MTLSamplerState> smp = sampler(dev, MTLSamplerMinMagFilterLinear);

	static const struct {
		const char *name, *vs, *fs;
		bool qc_vs, qc_fs, attrs;
	} cases[] = {
		{ "mix-qc-qc", "downsample_blur_vert_lph", "downsample_4_frag_lph", true, true, true },
		{ "mix-qcvs-m5fs", "downsample_blur_vert_lph", "ds_q_fs", true, false, true },
		{ "mix-m5vs-qcfs", "ds_q_quad_vs", "downsample_4_frag_lph", false, true, false },
		{ "mix-m5attr-m5fs", "ds_q_attr_vs", "ds_q_fs", false, false, true },
		{ "mix-m5vs-m5fs", "ds_q_quad_vs", "ds_q_fs", false, false, false },
	};
	for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
		const char *name = cases[c].name;
		id<MTLLibrary> vl = cases[c].qc_vs ? qc : m5, fl = cases[c].qc_fs ? qc : m5;
		if (!vl || !fl) {
			result(mode, name, false, "QuartzCore's library did not load");
			continue;
		}
		MTLRenderPipelineDescriptor *pd = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
		pd.vertexFunction = [[vl newFunctionWithName:@(cases[c].vs)] autorelease];
		pd.fragmentFunction = [[fl newFunctionWithName:@(cases[c].fs)] autorelease];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		if (cases[c].attrs)
			pd.vertexDescriptor = vd;
		NSError *err = nil;
		double t0 = a04s_now();
		id<MTLRenderPipelineState> ps = pd.vertexFunction && pd.fragmentFunction
			? [[dev newRenderPipelineStateWithDescriptor:pd error:&err] autorelease] : nil;
		a04s_log("  sample: pipeline %s + %s: %s in %.1f s%s%s", cases[c].vs, cases[c].fs, ps ? "made" : "nil",
			 a04s_now() - t0, err ? ", error: " : "", err ? err.localizedDescription.UTF8String : "");
		id<MTLTexture> src = tex2d(dev, MTLPixelFormatBGRA8Unorm, 258, 258, MTLStorageModePrivate,
					   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
		id<MTLTexture> dst = tex2d(dev, MTLPixelFormatBGRA8Unorm, 68, 68, MTLStorageModeShared,
					   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
		if (!ps || !src || !dst || !smp) {
			result(mode, name, false, "setup: pipeline %d textures %d %d sampler %d", !!ps, !!src, !!dst, !!smp);
			continue;
		}
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLRenderCommandEncoder> e0 = [cb renderCommandEncoderWithDescriptor:pass(src, MTLLoadActionClear,
							MTLClearColorMake(0.25, 0.5, 0.75, 1))];
		[e0 endEncoding];
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass(dst, MTLLoadActionClear,
							MTLClearColorMake(0.0625, 0.125, 0.1875, 0.25))];
		[enc setRenderPipelineState:ps];
		[enc setViewport:(MTLViewport){ 0, 0, 68, 68, 0, 1 }];
		[enc setScissorRect:(MTLScissorRect){ 0, 0, 68, 68 }];
		/* every binding either half might read, whichever pair this is */
		[enc setVertexBuffer:vb offset:0 atIndex:1];
		[enc setVertexBytes:mvp length:sizeof(mvp) atIndex:2];
		[enc setVertexBytes:texmat length:sizeof(texmat) atIndex:3];
		[enc setFragmentTexture:src atIndex:3];
		[enc setFragmentSamplerState:smp atIndex:0];
		[enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
		[enc setFragmentBytes:&edr length:sizeof(edr) atIndex:6];
		if (cases[c].attrs)
			[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0];
		else
			[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		[enc endEncoding];
		run(cb, name);
		static uint8_t px[68 * 68 * 4];
		[dst getBytes:px bytesPerRow:68 * 4 fromRegion:MTLRegionMake2D(0, 0, 68, 68) mipmapLevel:0];
		/* the inner 60x60, inside both quads: how many are the colour, the sentinel, zero, other */
		unsigned ncol = 0, nsent = 0, nzero = 0, nother = 0;
		static const uint8_t ZERO[4] = { 0, 0, 0, 0 };
		for (unsigned y = 4; y < 64; y++)
			for (unsigned x = 4; x < 64; x++) {
				const uint8_t *p = px + 4 * (y * 68 + x);
				if (near4(p, COL_BGRA)) ncol++;
				else if (near4(p, SENT_BGRA)) nsent++;
				else if (near4(p, ZERO)) nzero++;
				else nother++;
			}
		const uint8_t *a = px + 4 * (34 * 68 + 34), *b = px + 4 * (1 * 68 + 1);
		const char *verdict = ncol == 3600 ? "colour" : nsent == 3600 ? "SENTINEL: nothing drawn" :
				      nzero == 3600 ? "ZERO: fragments wrote zero" : "MIXED";
		result(mode, name, ncol == 3600 && cb.status == MTLCommandBufferStatusCompleted,
		       "%s; inner 3600: %u colour, %u sentinel, %u zero, %u other; (34,34) %02x%02x%02x%02x want %02x%02x%02x%02x; (1,1) %02x%02x%02x%02x",
		       verdict, ncol, nsent, nzero, nother, a[0], a[1], a[2], a[3], COL_BGRA[0], COL_BGRA[1], COL_BGRA[2], COL_BGRA[3],
		       b[0], b[1], b[2], b[3]);
		char path[128];
		snprintf(path, sizeof(path), "/private/var/a04s/m6-%s-%s-68x68.bgra", mode, name);
		FILE *f = fopen(path, "wb");
		if (f) {
			fwrite(px, 1, sizeof(px), f);
			fclose(f);
		}
	}
}

/* A04S_M6_SAMPLING=1: run 7's ladder and run 8's matrix; =2: the matrix alone */
int
a04s_m6_sampling(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> core, id<MTLLibrary> m5, const char *mode)
{
	g_bad = 0;
	const char *sel = getenv("A04S_M6_SAMPLING");
	bool matrix_only = sel && sel[0] == '2';
	@autoreleasepool {
		if (!matrix_only) {
			test_blit(dev, q, core, mode);
			test_blit_gpu(dev, q, core, mode);
			test_ds_like(dev, q, m5, mode);
			test_qc_downsample(dev, q, mode);
		}
		test_mix(dev, q, m5, mode);
	}
	return g_bad;
}
