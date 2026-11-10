/*
 * Galaxy A04s, Metal track M6a: CoreAnimation's own Metal renderer on the A04s's Metal device, in
 * the probe's process only -- backboardd is not touched.
 *
 * Adapted from Chlorophyll's test/bgmtl_carenderer_probe.m (github.com/ry-diffusion/Chlorophyll at
 * 787338f, MIT, Copyright (c) 2026 OOSEX GANG; see ../chlorophyll/NOTICE.md): the same seven layer
 * trees (solid layers, an image, text, a rounded clip, a shape mask, a blur filter, a backdrop
 * material), each drawn by a CARenderer into a texture of the Metal device and, as the
 * reference, by CoreAnimation's CPU path (-[CALayer renderInContext:]). The A04s changes: the
 * device is the one Metal hands out (A04sMetal.bundle), each scene is drawn twice (the first frame
 * pays for building pipelines, the second shows the steady cost), and the results go to the
 * probe's log and to /private/var/a04s/m6-<mode>-{scene,ref}N.bgra (256 x 256, BGRA).
 *
 * QuartzCore's shaders are its own default.metallib, read on the phone; nothing of Apple's is in
 * this repository.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>

#include <math.h>
#include <stdlib.h>

#include "a04s_metal_log.h"

#define W 256
#define H 256

static CGColorRef
rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
	return CGColorCreateGenericRGB(r, g, b, a);   /* leaked: a probe draws seven scenes and exits */
}

static CALayer *
make_scene(int n)
{
	CALayer *root = [CALayer layer];
	root.bounds = CGRectMake(0, 0, W, H);
	root.position = CGPointMake(W / 2, H / 2);
	root.backgroundColor = rgb(0.1, 0.1, 0.2, 1);
	switch (n) {
	case 0: {   /* solid layers, one translucent */
		CGFloat c[3][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 0.5 }, { 0, 0, 1, 1 } };
		for (int i = 0; i < 3; i++) {
			CALayer *l = [CALayer layer];
			l.frame = CGRectMake(20 + i * 50, 20 + i * 40, 120, 120);
			l.backgroundColor = rgb(c[i][0], c[i][1], c[i][2], c[i][3]);
			[root addSublayer:l];
		}
		break;
	}
	case 1: {   /* an image: a gradient made with CoreGraphics */
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGContextRef g = CGBitmapContextCreate(NULL, 64, 64, 8, 0, cs, kCGImageAlphaPremultipliedLast);
		for (int y = 0; y < 64; y++)
			for (int x = 0; x < 64; x++) {
				CGContextSetRGBFillColor(g, x / 63.0, y / 63.0, 0.5, 1);
				CGContextFillRect(g, CGRectMake(x, y, 1, 1));
			}
		CGImageRef img = CGBitmapContextCreateImage(g);
		CALayer *l = [CALayer layer];
		l.frame = CGRectMake(32, 32, 192, 192);
		l.contents = (id)img;
		l.magnificationFilter = kCAFilterLinear;
		[root addSublayer:l];
		break;
	}
	case 2: {   /* text */
		CATextLayer *t = [CATextLayer layer];
		t.frame = CGRectMake(10, 80, 236, 60);
		t.string = @"A04s Metal";
		t.fontSize = 28;
		t.foregroundColor = rgb(1, 1, 1, 1);
		t.contentsScale = 1;
		[root addSublayer:t];
		break;
	}
	case 3: {   /* a rounded clip with a child that overflows */
		CALayer *l = [CALayer layer];
		l.frame = CGRectMake(40, 40, 176, 176);
		l.cornerRadius = 40;
		l.masksToBounds = YES;
		l.backgroundColor = rgb(0.9, 0.7, 0.1, 1);
		CALayer *c = [CALayer layer];
		c.frame = CGRectMake(100, 100, 150, 150);
		c.backgroundColor = rgb(0.8, 0.1, 0.5, 1);
		[l addSublayer:c];
		[root addSublayer:l];
		break;
	}
	case 4: {   /* a mask layer (a circle) */
		CALayer *l = [CALayer layer];
		l.frame = CGRectMake(28, 28, 200, 200);
		l.backgroundColor = rgb(0.2, 0.8, 0.9, 1);
		CAShapeLayer *m = [CAShapeLayer layer];
		m.frame = l.bounds;
		m.path = CGPathCreateWithEllipseInRect(CGRectMake(20, 20, 160, 160), NULL);
		m.fillColor = rgb(0, 0, 0, 1);
		l.mask = m;
		[root addSublayer:l];
		break;
	}
	case 5: {   /* a blur filter over stripes (CAFilter is private; absent: no filter) */
		for (int i = 0; i < 8; i++) {
			CALayer *l = [CALayer layer];
			l.frame = CGRectMake(i * 32, 0, 16, H);
			l.backgroundColor = rgb(1, 1, 1, 1);
			[root addSublayer:l];
		}
		Class cf = NSClassFromString(@"CAFilter");
		id blur = cf ? [cf performSelector:NSSelectorFromString(@"filterWithType:") withObject:@"gaussianBlur"] : nil;
		if (blur) {
			[blur setValue:@6 forKey:@"inputRadius"];
			root.filters = @[ blur ];
		}
		break;
	}
	case 6: {   /* a material: stripes behind a blurring, saturating backdrop and a tint (a platter) */
		for (int i = 0; i < 8; i++) {
			CALayer *l = [CALayer layer];
			l.frame = CGRectMake(i * 32, 0, 16, H);
			l.backgroundColor = rgb(i & 1 ? 1 : 0.1, i & 2 ? 0.8 : 0.2, i & 4 ? 0.9 : 0.1, 1);
			[root addSublayer:l];
		}
		Class bd = NSClassFromString(@"CABackdropLayer"), cf = NSClassFromString(@"CAFilter");
		if (bd && cf) {
			CALayer *b = [bd layer];
			b.frame = CGRectMake(32, 32, 192, 192);
			id blur = [cf performSelector:NSSelectorFromString(@"filterWithType:") withObject:@"gaussianBlur"];
			[blur setValue:@12 forKey:@"inputRadius"];
			id sat = [cf performSelector:NSSelectorFromString(@"filterWithType:") withObject:@"colorSaturate"];
			[sat setValue:@1.8 forKey:@"inputAmount"];
			b.filters = @[ blur, sat ];
			[root addSublayer:b];
			CALayer *tint = [CALayer layer];
			tint.frame = b.frame;
			tint.backgroundColor = rgb(1, 1, 1, 0.3);
			[root addSublayer:tint];
		}
		break;
	}
	}
	return root;
}

static void
save(const char *mode, const char *what, int n, const uint8_t *px)
{
	char path[128];
	snprintf(path, sizeof(path), "/private/var/a04s/m6-%s-%s%d.bgra", mode, what, n);
	FILE *f = fopen(path, "wb");
	if (f) {
		fwrite(px, 4, W * H, f);
		fclose(f);
	}
}

/*
 * A04s (M6a run 10): -[CALayer renderInContext:] does not apply layer filters, so scene 5's CPU reference is
 * the stripes unblurred and the plain comparison always DIFFERS. Run 9's output matched, offline, the reference
 * blurred by a Gaussian of sigma 5.5 normalised at the image's edges (mean error 1.0, at most 2.4, no shift).
 * This repeats that check on the phone: the reference blurred (separable, normalised where the kernel leaves
 * the image) for sigma 3..9 in steps of 0.5, against the output's unpremultiplied colour wherever its alpha is
 * at least 128. Returns the smallest mean difference per channel and its sigma; -1 if nothing could be compared.
 */
static double
blur_check(const uint8_t *out, const uint8_t *ref, double *sigma_out, unsigned *pixels_out)
{
	float *t = malloc(sizeof(float) * W * H * 3), *a = malloc(sizeof(float) * W * H * 3);
	double best = -1;
	if (!t || !a) {
		free(t);
		free(a);
		return -1;
	}
	for (int si = 0; si <= 12; si++) {
		const double sig = 3 + 0.5 * si;
		const int R = (int)ceil(3 * sig);
		float k[64];
		for (int i = -R; i <= R; i++)
			k[i + R] = expf(-(float)(i * i) / (float)(2 * sig * sig));
		for (int y = 0; y < H; y++)   /* rows: reference (opaque, so unpremultiplied) into t */
			for (int x = 0; x < W; x++) {
				float s0 = 0, s1 = 0, s2 = 0, n = 0;
				for (int i = -R; i <= R; i++) {
					const int xx = x + i;
					if (xx < 0 || xx >= W)
						continue;
					const uint8_t *p = ref + 4 * (y * W + xx);
					s0 += k[i + R] * p[0];
					s1 += k[i + R] * p[1];
					s2 += k[i + R] * p[2];
					n += k[i + R];
				}
				float *o = t + 3 * (y * W + x);
				o[0] = s0 / n;
				o[1] = s1 / n;
				o[2] = s2 / n;
			}
		for (int y = 0; y < H; y++)   /* columns: t into a */
			for (int x = 0; x < W; x++) {
				float s0 = 0, s1 = 0, s2 = 0, n = 0;
				for (int i = -R; i <= R; i++) {
					const int yy = y + i;
					if (yy < 0 || yy >= H)
						continue;
					const float *p = t + 3 * (yy * W + x);
					s0 += k[i + R] * p[0];
					s1 += k[i + R] * p[1];
					s2 += k[i + R] * p[2];
					n += k[i + R];
				}
				float *o = a + 3 * (y * W + x);
				o[0] = s0 / n;
				o[1] = s1 / n;
				o[2] = s2 / n;
			}
		double sum = 0;
		unsigned px = 0;
		for (int i = 0; i < W * H; i++) {
			const unsigned al = out[4 * i + 3];
			if (al < 128)
				continue;
			for (int c = 0; c < 3; c++)
				sum += fabs(out[4 * i + c] * 255.0 / al - a[3 * i + c]);
			px++;
		}
		if (px && (best < 0 || sum / (3.0 * px) < best)) {
			best = sum / (3.0 * px);
			*sigma_out = sig;
			*pixels_out = px;
		}
	}
	free(t);
	free(a);
	return best;
}

/* One frame of `r`, waited for; seconds taken. */
static double
frame(CARenderer *r, id<MTLCommandQueue> q)
{
	double t0 = a04s_now();
	[r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
	[r addUpdateRect:r.bounds];
	[r render];
	[r endFrame];
	/* CARenderer commits without waiting: a command buffer behind it on the same queue completes after its work */
	id<MTLCommandBuffer> fence = [q commandBuffer];
	[fence commit];
	[fence waitUntilCompleted];
	return a04s_now() - t0;
}

/*
 * Returns how many scenes drew nothing or were refused. `only`: a comma list of scene numbers, or NULL for all.
 *
 * A04s (M6a run 11), two lists in the environment:
 * - A04S_CA_FLIP_SCENES: each of these scenes is drawn a second time with BGMTL_FLIP_CPU_TEXTURES=1, which makes the
 *   device write CPU-drawn textures' rows in reverse order (run 10 drew scenes 1 and 2 upside down). Its files are
 *   m6-<mode>-scene-flipN.bgra.
 * - A04S_PASS_STATS_SCENES: A04S_PASS_STATS is set only while these scenes draw, so the 24 pass pictures the device
 *   writes are theirs.
 */
int
a04s_ca_scenes(id<MTLDevice> d, const char *mode, const char *only)
{
	int bad = 0, done = 0;
	id<MTLCommandQueue> q = [[d newCommandQueue] autorelease];
	const char *flips = getenv("A04S_CA_FLIP_SCENES"), *stats = getenv("A04S_PASS_STATS_SCENES");
	const int stats_was = getenv("A04S_PASS_STATS") != NULL;
	for (int n = 0; n < 7; n++)
	for (int flip = 0; flip < 2; flip++) {
		@autoreleasepool {
			char tag[8];
			snprintf(tag, sizeof(tag), "%d", n);
			if (only && !strstr(only, tag))
				continue;
			if (flip && !(flips && strstr(flips, tag)))
				continue;
			const char *fl = flip ? " (CPU textures flipped)" : "";
			if (flip)
				setenv("BGMTL_FLIP_CPU_TEXTURES", "1", 1);
			else
				unsetenv("BGMTL_FLIP_CPU_TEXTURES");
			if (stats) {
				if (strstr(stats, tag))
					setenv("A04S_PASS_STATS", "1", 1);
				else
					unsetenv("A04S_PASS_STATS");
			}
			a04s_log("  ca scene %d%s: start", n, fl);
			CALayer *scene = make_scene(n);

			/* the reference: CoreAnimation's CPU path into a bitmap, BGRA as the texture */
			CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
			uint8_t *ref = calloc(W * H, 4);
			CGContextRef g = CGBitmapContextCreate(ref, W, H, 8, W * 4, cs,
							       kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
			CGContextTranslateCTM(g, 0, H);   /* layer space is top-left, a bitmap context bottom-left */
			CGContextScaleCTM(g, 1, -1);
			[scene renderInContext:g];
			CGContextRelease(g);
			CGColorSpaceRelease(cs);

			/* the subject: a CARenderer over a texture of the device */
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
												    width:W height:H mipmapped:NO];
			td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
			id<MTLTexture> tex = [[d newTextureWithDescriptor:td] autorelease];
			CARenderer *r = tex ? [CARenderer rendererWithMTLTexture:tex options:@{ kCARendererMetalCommandQueue : q }] : nil;
			if (!r) {
				a04s_log("  ca scene %d: %s", n, tex ? "CARenderer refused the texture" : "no texture");
				bad++;
				free(ref);
				continue;
			}
			r.layer = scene;
			r.bounds = CGRectMake(0, 0, W, H);
			[CATransaction flush];   /* the renderer draws the render tree, which exists only after a commit */
			double first = frame(r, q);
			double second = frame(r, q);
			usleep(200000);   /* CoreAnimation may commit its own buffer after ours */

			uint8_t *out = calloc(W * H, 4);
			[tex getBytes:out bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
			double sum = 0;
			unsigned nonzero = 0, far = 0;
			for (int i = 0; i < W * H * 4; i++) {
				int dlt = abs((int)out[i] - (int)ref[i]);
				sum += dlt;
				far += dlt > 32;
				if (out[i])
					nonzero++;
			}
			a04s_log("  ca scene %d%s: first frame %.2f s, second %.3f s; mean abs diff %.2f, %u of %d channels off by "
				 "more than 32, %u non-zero bytes", n, fl, first, second, sum / (W * H * 4), far, W * H * 4, nonzero);
			/* A04s (M6a run 11): MATCH needs few far-off channels as well as a small mean. Run 10's scene 3 had square
			 * corners where the rounded clip belonged and still averaged 2.19 (5447 channels off by more than 32). */
			a04s_log("M6 RESULT %s ca scene %d%s: %s (diff %.2f, %u channels off by more than 32)", mode, n, fl,
				 !nonzero ? "NOTHING DRAWN" : sum / (W * H * 4) < 8 && far < W * H * 4 / 400 ? "MATCH" : "DIFFERS",
				 sum / (W * H * 4), far);
			if (n == 5 && nonzero && !flip) {
				double sig = 0;
				unsigned px = 0;
				const double bd = blur_check(out, ref, &sig, &px);
				const uint8_t *o = out;
				a04s_log("  ca scene 5: the CPU reference ignores layer filters; against it blurred: best sigma %.1f, "
					 "mean diff %.2f on %u pixels; edge alpha left %u right %u top %u bottom %u, centre %u",
					 sig, bd, px, o[4 * (H / 2 * W) + 3], o[4 * (H / 2 * W + W - 1) + 3], o[4 * (W / 2) + 3],
					 o[4 * ((H - 1) * W + W / 2) + 3], o[4 * (H / 2 * W + W / 2) + 3]);
				a04s_log("M6 RESULT %s ca scene 5 blurred reference: %s (diff %.2f, sigma %.1f)", mode,
					 bd < 0 ? "NOT COMPARED" : bd < 4 ? "MATCH" : "DIFFERS", bd, sig);
			}
			if (n == 6 && nonzero && !flip)
				a04s_log("  ca scene 6: the CPU reference draws no backdrop (blur and saturation under the panel); "
					 "the panel is checked offline from the .bgra files");
			save(mode, flip ? "scene-flip" : "scene", n, out);
			if (!flip)
				save(mode, "ref", n, ref);
			if (!nonzero)
				bad++;
			done++;
			free(out);
			free(ref);
		}
	}
	unsetenv("BGMTL_FLIP_CPU_TEXTURES");
	if (stats) {
		if (stats_was)
			setenv("A04S_PASS_STATS", "1", 1);
		else
			unsetenv("A04S_PASS_STATS");
	}
	a04s_log("  ca: %d scenes rendered, %d with nothing drawn or refused", done, bad);
	return bad;
}
