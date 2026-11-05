/*
 * Galaxy A04s, stage 7c-4c: offline Bifrost shaders for the Mali-G52 (GPU ID 0x7212, Panfrost
 * arch 7), built with Mesa's own compiler. The shaders are built in NIR the way Panfrost builds its
 * framebuffer preload shader (src/gallium/drivers/panfrost/pan_fb_preload.c, Mesa 25.0.7), then
 * pan_shader_preprocess() and pan_shader_compile() run on them exactly as there. Nothing here comes
 * from Apple or Samsung.
 *
 * It is compiled inside Mesa's tree, next to src/panfrost/lib (gpu/a04s/shaderc/build.sh), and
 * writes for each shader:
 *   <name>.bin  the machine code, to load at a 128-byte aligned GPU address;
 *   <name>.txt  Mesa's disassembly of it;
 *   <name>.h    a C array with the code and the fields a renderer state needs (registers, preload,
 *               the blend return offset and type, texture, sampler and varying counts).
 *
 * Shaders:
 *   gradient  colour = (x / 720, y / 1600, 0.5, 1) from the fragment coordinate: no inputs, no
 *             texture. The first test that a shader runs, as a pre-frame shader over the panel.
 *   blit      Panfrost's single-sample 2D preload: texel = texture 0 / sampler 0 at the coordinate in
 *             varying VAR0 (txl, LOD 0), written to render target 0. The template for 7c-4d's scaler.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "compiler/nir/nir.h"
#include "compiler/nir/nir_builder.h"
#include "compiler/glsl_types.h"
#include "panfrost/lib/pan_shader.h"
#include "util/u_dynarray.h"

#define A04S_GPU_ID 0x7212u
#define PANEL_W     720.0f
#define PANEL_H     1600.0f

static nir_builder
begin(const char *name)
{
   return nir_builder_init_simple_shader(MESA_SHADER_FRAGMENT,
                                         GENX(pan_shader_get_compiler_options)(),
                                         "a04s_%s", name);
}

static void
store_rt0(nir_builder *b, nir_def *color)
{
   nir_store_output(b, color, nir_imm_int(b, 0), .base = 0,
                    .src_type = nir_type_float32,
                    .io_semantics.location = FRAG_RESULT_DATA0,
                    .io_semantics.num_slots = 1,
                    .write_mask = nir_component_mask(color->num_components));
}

static nir_shader *
build_gradient(void)
{
   nir_builder b = begin("gradient");
   nir_def *pos = nir_load_frag_coord(&b);
   nir_def *r = nir_fmul_imm(&b, nir_channel(&b, pos, 0), 1.0 / PANEL_W);
   nir_def *g = nir_fmul_imm(&b, nir_channel(&b, pos, 1), 1.0 / PANEL_H);
   store_rt0(&b, nir_vec4(&b, r, g, nir_imm_float(&b, 0.5f), nir_imm_float(&b, 1.0f)));
   return b.shader;
}

static nir_shader *
build_blit(void)
{
   nir_builder b = begin("blit");
   nir_def *barycentric = nir_load_barycentric(
      &b, nir_intrinsic_load_barycentric_pixel, INTERP_MODE_SMOOTH);
   nir_def *coord = nir_load_interpolated_input(
      &b, 2, 32, barycentric, nir_imm_int(&b, 0), .base = 0,
      .dest_type = nir_type_float32, .io_semantics.location = VARYING_SLOT_VAR0,
      .io_semantics.num_slots = 1);

   nir_tex_instr *tex = nir_tex_instr_create(b.shader, 1);
   tex->dest_type = nir_type_float32;
   tex->texture_index = 0;
   tex->sampler_index = 0;
   tex->is_array = false;
   tex->sampler_dim = GLSL_SAMPLER_DIM_2D;
   tex->op = nir_texop_txl;
   tex->src[0] = nir_tex_src_for_ssa(nir_tex_src_coord, coord);
   tex->coord_components = 2;
   nir_def_init(&tex->instr, &tex->def, 4, 32);
   nir_builder_instr_insert(&b, &tex->instr);

   store_rt0(&b, &tex->def);
   BITSET_SET(b.shader->info.textures_used, 0);
   return b.shader;
}

static int
write_file(const char *dir, const char *name, const char *ext, const void *data, size_t size)
{
   char path[512];
   snprintf(path, sizeof(path), "%s/%s.%s", dir, name, ext);
   FILE *f = fopen(path, "wb");
   if (!f || fwrite(data, 1, size, f) != size) {
      fprintf(stderr, "a04s_shaderc: can't write %s\n", path);
      return 1;
   }
   fclose(f);
   return 0;
}

static int
compile_one(const char *dir, const char *name, nir_shader *s)
{
   struct panfrost_compile_inputs inputs = {
      .gpu_id = A04S_GPU_ID,
      .is_blit = true,
      .no_idvs = true,
   };
   struct pan_shader_info info;
   struct util_dynarray binary;

   memset(&info, 0, sizeof(info));
   util_dynarray_init(&binary, NULL);
   nir_shader_gather_info(s, nir_shader_get_entrypoint(s));
   pan_shader_preprocess(s, inputs.gpu_id);
   GENX(pan_shader_compile)(s, &inputs, &binary, &info);
   if (binary.size == 0) {
      fprintf(stderr, "a04s_shaderc: %s compiled to nothing\n", name);
      return 1;
   }

   int err = write_file(dir, name, "bin", binary.data, binary.size);

   char path[512];
   snprintf(path, sizeof(path), "%s/%s.txt", dir, name);
   FILE *txt = fopen(path, "w");
   if (!txt) {
      fprintf(stderr, "a04s_shaderc: can't write %s\n", path);
      return 1;
   }
   fprintf(txt, "a04s_%s for GPU 0x%x: %u bytes, %u work registers, preload 0x%llx\n", name,
           inputs.gpu_id, binary.size, info.work_reg_count, (unsigned long long)info.preload);
   pan_shader_disassemble(txt, binary.data, binary.size, inputs.gpu_id, false);
   fclose(txt);

   snprintf(path, sizeof(path), "%s/%s.h", dir, name);
   FILE *h = fopen(path, "w");
   if (!h) {
      fprintf(stderr, "a04s_shaderc: can't write %s\n", path);
      return 1;
   }
   fprintf(h, "/* a04s_%s: Bifrost code for GPU 0x%x from Mesa 25.0.7 (gpu/a04s/shaderc). */\n",
           name, inputs.gpu_id);
   fprintf(h, "#define A04S_SH_%s_SIZE %u\n", name, binary.size);
   fprintf(h, "#define A04S_SH_%s_WORK_REGS %u\n", name, info.work_reg_count);
   fprintf(h, "#define A04S_SH_%s_PRELOAD 0x%llxull\n", name, (unsigned long long)info.preload);
   fprintf(h, "#define A04S_SH_%s_BLEND0_RETURN 0x%x\n", name, info.bifrost.blend[0].return_offset);
   fprintf(h, "#define A04S_SH_%s_BLEND0_TYPE 0x%x\n", name, (unsigned)info.bifrost.blend[0].type);
   fprintf(h, "#define A04S_SH_%s_BLEND0_FORMAT 0x%x\n", name, info.bifrost.blend[0].format);
   fprintf(h, "#define A04S_SH_%s_TEXTURES %u\n", name, info.texture_count);
   fprintf(h, "#define A04S_SH_%s_SAMPLERS %u\n", name, info.sampler_count);
   fprintf(h, "#define A04S_SH_%s_VARYINGS_IN %u\n", name, info.varyings.input_count);
   fprintf(h, "#define A04S_SH_%s_UBOS %u\n", name, info.ubo_count);
   fprintf(h, "#define A04S_SH_%s_PUSH_WORDS %u\n", name, info.push.count);
   fprintf(h, "#define A04S_SH_%s_TLS %u\n", name, info.tls_size);
   fprintf(h, "#define A04S_SH_%s_READS_FRAG_COORD %u\n", name, info.fs.reads_frag_coord ? 1u : 0u);
   fprintf(h, "#define A04S_SH_%s_CAN_DISCARD %u\n", name, info.fs.can_discard ? 1u : 0u);
   fprintf(h, "#define A04S_SH_%s_SIDEFX %u\n", name, info.fs.sidefx ? 1u : 0u);
   fprintf(h, "#define A04S_SH_%s_CAN_FPK %u\n", name, info.fs.can_fpk ? 1u : 0u);
   fprintf(h, "#define A04S_SH_%s_HELPERS %u\n", name, info.contains_barrier ? 1u : 0u);
   fprintf(h, "#define A04S_SH_%s_MSG0 %u %u %u %u %u\n", name,
           info.bifrost.messages[0].enabled ? 1u : 0u, info.bifrost.messages[0].varying_index,
           info.bifrost.messages[0].texture ? 1u : 0u, info.bifrost.messages[0].zero_lod ? 1u : 0u,
           info.bifrost.messages[0].num_components);
   fprintf(h, "#define A04S_SH_%s_WAIT_6 %u\n", name, info.bifrost.wait_6 ? 1u : 0u);
   fprintf(h, "#define A04S_SH_%s_WAIT_7 %u\n", name, info.bifrost.wait_7 ? 1u : 0u);
   for (unsigned m = 0; m < 2; m++) {
      const struct bifrost_message_preload *msg = &info.bifrost.messages[m];
      fprintf(h, "/* message %u: enabled %u varying %u fp16 %u components %u texture %u skip %u zero_lod %u "
              "texture_index %u */\n", m, msg->enabled ? 1u : 0u, msg->varying_index, msg->fp16 ? 1u : 0u,
              msg->num_components, msg->texture ? 1u : 0u, msg->skip ? 1u : 0u, msg->zero_lod ? 1u : 0u,
              msg->texture_index);
   }
   fprintf(h, "/* varyings in %u:", info.varyings.input_count);
   for (unsigned v = 0; v < info.varyings.input_count; v++) {
      fprintf(h, " slot %u format %u", (unsigned)info.varyings.input[v].location,
              (unsigned)info.varyings.input[v].format);
   }
   fprintf(h, " */\n");
   fprintf(h, "static const unsigned char a04s_sh_%s[%u] __attribute__((aligned(128))) = {", name,
           binary.size);
   const unsigned char *p = binary.data;
   for (unsigned i = 0; i < binary.size; i++) {
      fprintf(h, "%s0x%02x,", (i % 12) ? " " : "\n\t", p[i]);
   }
   fprintf(h, "\n};\n");
   fclose(h);

   printf("%s: %u bytes, %u work registers, preload 0x%llx, blend0 return 0x%x type 0x%x, "
          "%u textures, %u samplers, %u varyings in, %u ubos, %u push words, tls %u\n",
          name, binary.size, info.work_reg_count, (unsigned long long)info.preload,
          info.bifrost.blend[0].return_offset, (unsigned)info.bifrost.blend[0].type,
          info.texture_count, info.sampler_count, info.varyings.input_count, info.ubo_count,
          info.push.count, info.tls_size);
   util_dynarray_fini(&binary);
   ralloc_free(s);
   return err;
}

int
main(int argc, char **argv)
{
   if (argc != 2) {
      fprintf(stderr, "usage: a04s_shaderc OUTDIR\n");
      return 2;
   }
   glsl_type_singleton_init_or_ref();
   int err = compile_one(argv[1], "gradient", build_gradient());
   err |= compile_one(argv[1], "blit", build_blit());
   glsl_type_singleton_decref();
   return err;
}
