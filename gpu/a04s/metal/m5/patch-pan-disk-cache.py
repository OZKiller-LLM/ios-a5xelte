#!/usr/bin/env python3
"""Galaxy A04s, Metal track M6: Panfrost's shader cache on Darwin.

  patch-pan-disk-cache.py MESA_DIR

Mesa 25.0.7's panfrost_disk_cache_init names the cache after the driver's ELF build-id
(build_id_find_nhdr_for_addr), which Mach-O has none of. On Apple it uses Mesa's own portable
identifier instead (disk_cache_get_function_identifier: the library's path and modification time
through dladdr), so a new library on the phone starts a new cache. The edit asserts that the text
it replaces is found exactly once.
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
   if (!disk_cache_get_function_identifier((void *)panfrost_disk_cache_init, &id_ctx))
      return;
   _mesa_sha1_final(&id_ctx, id_sha1);
#else
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
p.write_text(s)
print('patched', p)
