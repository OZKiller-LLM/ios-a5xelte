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

/* Returns how many scenes drew nothing or were refused. `only`: a comma list of scene numbers, or NULL for all. */
int
a04s_ca_scenes(id<MTLDevice> d, const char *mode, const char *only)
{
	int bad = 0, done = 0;
	id<MTLCommandQueue> q = [[d newCommandQueue] autorelease];
	for (int n = 0; n < 7; n++) {
		@autoreleasepool {
			char tag[8];
			snprintf(tag, sizeof(tag), "%d", n);
			if (only && !strstr(only, tag))
				continue;
			a04s_log("  ca scene %d: start", n);
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
			a04s_log("  ca scene %d: first frame %.2f s, second %.3f s; mean abs diff %.2f, %u of %d channels off by "
				 "more than 32, %u non-zero bytes", n, first, second, sum / (W * H * 4), far, W * H * 4, nonzero);
			a04s_log("M6 RESULT %s ca scene %d: %s (diff %.2f)", mode, n,
				 !nonzero ? "NOTHING DRAWN" : sum / (W * H * 4) < 8 ? "MATCH" : "DIFFERS", sum / (W * H * 4));
			save(mode, "scene", n, out);
			save(mode, "ref", n, ref);
			if (!nonzero)
				bad++;
			done++;
			free(out);
			free(ref);
		}
	}
	a04s_log("  ca: %d scenes rendered, %d with nothing drawn or refused", done, bad);
	return bad;
}
