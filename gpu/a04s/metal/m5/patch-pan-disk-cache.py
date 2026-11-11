#!/usr/bin/env python3
"""Galaxy A04s, Metal track M6: Panfrost's shader cache on Darwin.

  patch-pan-disk-cache.py MESA_DIR [CACHE_ID]

Mesa 25.0.7's panfrost_disk_cache_init names the cache after the driver's ELF build-id
(build_id_find_nhdr_for_addr), which Mach-O has none of. On Apple it uses Mesa's own portable
identifier instead (disk_cache_get_function_identifier: the library's path and modification time
through dladdr), so a new library on the phone starts a new cache. The edit asserts that the text
it replaces is found exactly once.

M6b: with CACHE_ID the identity is that string instead (build-mesa-ios.sh: a hash of Mesa and of
every patch that changes what Panfrost compiles). Then a libhakiosair rebuilt only for its front end
or its runtime keeps the phone's cache: Panfrost's key is the NIR it is given, so a front end that
translates differently misses by itself.
"""
import sys
from pathlib import Path

p = Path(sys.argv[1]) / 'src/gallium/drivers/panfrost/pan_disk_cache.c'
s = p.read_text()
old = '''   const struct build_id_note *note =
      build_id_find_nhdr_for_addr(panfrost_disk_cache_init);
   assert(note && build_id_length(note) == 20); /* sha1 */

   const uint8_t *id_sha1 = build_id_data(note);
   assert(id_sha1);

   char timestamp[41];
   _mesa_sha1_format(timestamp, id_sha1);
'''
new = '''#ifdef __APPLE__
   /* A04s (Metal track M6): no ELF build-id on Darwin; the library's own identity instead */
   struct mesa_sha1 id_ctx;
   unsigned char id_sha1[20];
   _mesa_sha1_init(&id_ctx);
@@ID@@#endif
   const struct build_id_note *note =
      build_id_find_nhdr_for_addr(panfrost_disk_cache_init);
   assert(note && build_id_length(note) == 20); /* sha1 */

   const uint8_t *id_sha1 = build_id_data(note);
   assert(id_sha1);
#endif

   char timestamp[41];
   _mesa_sha1_format(timestamp, id_sha1);
'''
assert s.count(old) == 1, 'pan_disk_cache.c is not as Mesa 25.0.7 has it'
s = s.replace(old, new)
if '#include "util/disk_cache.h"' not in s:
    s = s.replace('#include "pan_disk_cache.h"', '#include "pan_disk_cache.h"\n#include "util/disk_cache.h"', 1)
if '#include "util/mesa-sha1.h"' not in s:
    s = s.replace('#include "pan_disk_cache.h"', '#include "pan_disk_cache.h"\n#include "util/mesa-sha1.h"', 1)
cache_id = sys.argv[2] if len(sys.argv) > 2 else ''
if cache_id:
    ident = ('   /* M6b: a fixed identity, from the build (Mesa and its compiler patches) */\n'
             '   _mesa_sha1_update(&id_ctx, "' + cache_id + '", ' + str(len(cache_id)) + ');\n')
else:
    ident = ('   if (!disk_cache_get_function_identifier((void *)panfrost_disk_cache_init, &id_ctx))\n'
             '      return;\n')
ident += '   _mesa_sha1_final(&id_ctx, id_sha1);\n#else'
s = s.replace('@@ID@@#endif', ident, 1)
p.write_text(s)
print('patched', p, 'cache id', cache_id or '(the library file)')
