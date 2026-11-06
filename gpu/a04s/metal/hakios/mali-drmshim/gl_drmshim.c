/*
 * Copyright (c) 2026 Scion-Project contributors
 * SPDX-License-Identifier: MIT
 *
 * userland/src/gl_test.c's drawing, for a Linux machine: the same OSMesa OpenGL ES 2 context
 * (OSMESA_ES_PROFILE, tools/mesa/osmesa-es-profile.patch), the same triangle into the same
 * WIDTH x HEIGHT texture, read back the same way and summed up in the same line -- without the
 * panel, which a Linux machine does not have. tools/mali-drmshim-check.sh runs it twice: on
 * panfrost under drm-shim as the Galaxy S9's Mali-G72 (the job chains are what is checked; no
 * GPU runs them, so the pixels are not), and on softpipe, whose pixels are kept as the picture a
 * phone run can be compared with.
 *
 *   gl_drmshim WIDTH HEIGHT OUT.rgba [fill]
 *
 * OUT.rgba: the pixels as glReadPixels gives them (RGBA, bottom row first), WIDTH x HEIGHT x 4
 * bytes. "fill" also draws gl_test fill's ten kinds of frame once each into a texture of the same
 * size -- a clear, rectangles, a texture blended over them -- and one with a blend that needs a
 * blend shader (more of what panfrost makes).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <GL/osmesa.h>
#include <GLES2/gl2.h>

#ifndef OSMESA_ES_PROFILE
#define OSMESA_ES_PROFILE 0x38
#endif

static unsigned
shader(unsigned type, const char *text)
{
	unsigned name = glCreateShader(type);
	int good = 0;

	glShaderSource(name, 1, &text, NULL);
	glCompileShader(name);
	glGetShaderiv(name, GL_COMPILE_STATUS, &good);
	if (!good) {
		printf("gl_drmshim: a shader does not compile\n");
		exit(1);
	}
	return name;
}

/* gl_test.c fill(), each kind once */
static void
fill(int width, int height)
{
	static const float all[] = { -1, -1, 1, -1, -1, 1, 1, 1 }, some[] = { -0.1f, -0.1f, 0.1f, -0.1f, -0.1f, 0.1f, 0.1f, 0.1f };
	static const struct {
		int clear, layers, textured, small;
	} kinds[] = {
		{ 1, 0, 0, 0 }, { 0, 1, 0, 1 }, { 1, 1, 0, 0 }, { 1, 2, 0, 0 }, { 1, 4, 0, 0 },
		{ 1, 8, 0, 0 }, { 1, 1, 1, 0 }, { 1, 2, 1, 0 }, { 1, 4, 1, 0 }, { 1, 8, 1, 0 },
	};
	unsigned target = 0, source = 0, framebuffer = 0, program;
	uint32_t *pixels = malloc((size_t)width * (size_t)height * 4);
	int textured, colour, good = 0;

	for (size_t i = 0; i < (size_t)width * (size_t)height; i++)
		pixels[i] = 0x80404040u + ((uint32_t)i * 2654435761u >> 28);
	glGenTextures(1, &source);
	glBindTexture(GL_TEXTURE_2D, source);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
	free(pixels);
	glGenTextures(1, &target);
	glBindTexture(GL_TEXTURE_2D, target);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &framebuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
	program = glCreateProgram();
	glAttachShader(program, shader(GL_VERTEX_SHADER,
	    "attribute vec2 where; varying vec2 at;\n"
	    "void main() { gl_Position = vec4(where, 0.0, 1.0); at = where * 0.5 + 0.5; }\n"));
	glAttachShader(program, shader(GL_FRAGMENT_SHADER,
	    "precision mediump float; varying vec2 at; uniform sampler2D picture; uniform int textured; uniform vec4 colour;\n"
	    "void main() { gl_FragColor = textured != 0 ? texture2D(picture, at) * colour : colour; }\n"));
	glBindAttribLocation(program, 0, "where");
	glLinkProgram(program);
	glGetProgramiv(program, GL_LINK_STATUS, &good);
	if (!good || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		printf("gl_drmshim: fill: no program or no framebuffer\n");
		exit(1);
	}
	glUseProgram(program);
	textured = glGetUniformLocation(program, "textured");
	colour = glGetUniformLocation(program, "colour");
	glUniform1i(glGetUniformLocation(program, "picture"), 0);
	glBindTexture(GL_TEXTURE_2D, source);
	glViewport(0, 0, width, height);
	glEnableVertexAttribArray(0);
	glClearColor(0.1f, 0.1f, 0.2f, 1.0f);
	for (unsigned k = 0; k < sizeof(kinds) / sizeof(kinds[0]); k++) {
		glUniform1i(textured, kinds[k].textured);
		if (kinds[k].textured) {
			glEnable(GL_BLEND);
			glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
		} else {
			glDisable(GL_BLEND);
		}
		glVertexAttribPointer(0, 2, GL_FLOAT, 0, 0, kinds[k].small ? some : all);
		if (kinds[k].clear)
			glClear(GL_COLOR_BUFFER_BIT);
		for (int layer = 0; layer < kinds[k].layers; layer++) {
			glUniform4f(colour, 0.2f + 0.1f * (float)layer, 0.5f, 0.3f, 0.5f);
			glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		}
		glFinish();
	}
	/*
	 * And one gl_test does not draw: a blend the Mali has no fixed function for (GL_MIN), which
	 * panfrost draws with a blend shader -- whose address a Bifrost blend descriptor holds in 32
	 * bits, the reason HakiosMali keeps every address under 4 GB (drivers/gpu/hakios.mali_va.h).
	 */
	glEnable(GL_BLEND);
	glBlendEquation(GL_MIN);
	glUniform1i(textured, 1);
	glVertexAttribPointer(0, 2, GL_FLOAT, 0, 0, all);
	glClear(GL_COLOR_BUFFER_BIT);
	glUniform4f(colour, 0.7f, 0.5f, 0.3f, 0.5f);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	glFinish();
	glBlendEquation(GL_FUNC_ADD);
	printf("gl_drmshim: fill: 10 kinds of frame of %d x %d drawn, and one with a blend shader; error %#x\n", width,
	    height, glGetError());
}

int
main(int argc, char **argv)
{
	static const int attributes[] = { OSMESA_FORMAT, OSMESA_RGBA, OSMESA_PROFILE, OSMESA_ES_PROFILE,
		                          OSMESA_CONTEXT_MAJOR_VERSION, 2, 0 };
	static const float corners[] = {
		-0.8f, -0.6f, 1, 0, 0,
		0.8f, -0.6f, 0, 1, 0,
		0.0f, 0.7f, 0, 0, 1,
	};
	static unsigned char window[16 * 16 * 4];
	unsigned texture = 0, framebuffer = 0, program, coloured = 0;
	int width, height, good = 0;
	OSMesaContext context;
	uint8_t *drawn;
	FILE *out;

	setvbuf(stdout, NULL, _IOLBF, 0);       /* every line out, should the driver abort later */
	if (argc < 4) {
		fprintf(stderr, "usage: gl_drmshim WIDTH HEIGHT OUT.rgba [fill]\n");
		return 2;
	}
	width = atoi(argv[1]);
	height = atoi(argv[2]);
	context = OSMesaCreateContextAttribs(attributes, NULL);
	if (context == NULL || !OSMesaMakeCurrent(context, window, GL_UNSIGNED_BYTE, 16, 16)) {
		printf("gl_drmshim: no OpenGL ES context\n");
		return 1;
	}
	printf("gl_drmshim: %s; %s; %s\n", (const char *)glGetString(GL_VENDOR), (const char *)glGetString(GL_RENDERER),
	    (const char *)glGetString(GL_VERSION));

	glGenTextures(1, &texture);
	glBindTexture(GL_TEXTURE_2D, texture);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &framebuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		printf("gl_drmshim: the framebuffer is not complete\n");
		return 1;
	}
	program = glCreateProgram();
	glAttachShader(program, shader(GL_VERTEX_SHADER,
	    "attribute vec2 where; attribute vec3 colour; varying vec3 c;\n"
	    "void main() { gl_Position = vec4(where, 0.0, 1.0); c = colour; }\n"));
	glAttachShader(program, shader(GL_FRAGMENT_SHADER,
	    "precision mediump float; varying vec3 c;\n"
	    "void main() { gl_FragColor = vec4(c, 1.0); }\n"));
	glBindAttribLocation(program, 0, "where");
	glBindAttribLocation(program, 1, "colour");
	glLinkProgram(program);
	glGetProgramiv(program, GL_LINK_STATUS, &good);
	if (!good) {
		printf("gl_drmshim: the program does not link\n");
		return 1;
	}
	glUseProgram(program);
	glViewport(0, 0, width, height);
	glClearColor(0.1f, 0.1f, 0.2f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glVertexAttribPointer(0, 2, GL_FLOAT, 0, 5 * sizeof(float), corners);
	glVertexAttribPointer(1, 3, GL_FLOAT, 0, 5 * sizeof(float), corners + 2);
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glFinish();

	drawn = malloc((size_t)width * (size_t)height * 4);
	memset(drawn, 0x55, (size_t)width * (size_t)height * 4);
	glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, drawn);
	for (size_t i = 0; i < (size_t)width * (size_t)height; i++)
		coloured += drawn[4 * i] > 60 || drawn[4 * i + 1] > 60 || drawn[4 * i + 2] > 60;
#define PIXEL(x, y) drawn[((size_t)(y) * (size_t)width + (size_t)(x)) * 4], drawn[((size_t)(y) * (size_t)width + (size_t)(x)) * 4 + 1], \
	    drawn[((size_t)(y) * (size_t)width + (size_t)(x)) * 4 + 2], drawn[((size_t)(y) * (size_t)width + (size_t)(x)) * 4 + 3]
	printf("gl_drmshim: %d x %d; error %#x; red green blue alpha: a corner %u %u %u %u, "
	    "the middle %u %u %u %u, near the red corner %u %u %u %u, near the green %u %u %u %u, near the blue %u %u %u %u; "
	    "%u of %u pixels inside the triangle (%u%%; 26%% by geometry)\n", width, height,
	    glGetError(), PIXEL(2, 2), PIXEL(width / 2, height / 2), PIXEL(width * 15 / 100, height * 22 / 100),
	    PIXEL(width * 85 / 100, height * 22 / 100), PIXEL(width / 2, height * 80 / 100), coloured,
	    (unsigned)(width * height), (unsigned)((uint64_t)coloured * 100 / (uint64_t)(width * height)));
	out = fopen(argv[3], "wb");
	if (out == NULL || fwrite(drawn, 4, (size_t)width * (size_t)height, out) != (size_t)width * (size_t)height) {
		printf("gl_drmshim: cannot write %s\n", argv[3]);
		return 1;
	}
	fclose(out);
	if (argc > 4 && strcmp(argv[4], "fill") == 0)
		fill(width, height);
	OSMesaDestroyContext(context);
	return 0;
}
