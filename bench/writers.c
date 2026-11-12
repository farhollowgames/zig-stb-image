/* The benchmark's inputs in the formats stb_image_write writes: PNG, JPEG,
   BMP, TGA and HDR, from the stb dependency at the pinned commit. Each
   returns a malloc'd file and its length. */

#include <stdlib.h>
#include <string.h>

#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

typedef struct {
   unsigned char *data;
   size_t len, cap;
} grow;

static void append(void *context, void *data, int size)
{
   grow *g = (grow *) context;
   if (g->len + (size_t) size > g->cap) {
      size_t cap = g->cap ? g->cap * 2 : 65536;
      while (cap < g->len + (size_t) size) cap *= 2;
      g->data = (unsigned char *) realloc(g->data, cap);
      g->cap = cap;
   }
   memcpy(g->data + g->len, data, (size_t) size);
   g->len += (size_t) size;
}

/* format: 0 PNG, 1 JPEG (quality), 2 BMP, 3 TGA raw, 4 TGA RLE, 5 HDR (floats). */
unsigned char *bench_write(int format, int w, int h, int comp, const void *pixels, int quality,
                           size_t *len)
{
   grow g = { 0, 0, 0 };
   int ok = 0;
   switch (format) {
      case 0: ok = stbi_write_png_to_func(append, &g, w, h, comp, pixels, w * comp); break;
      case 1: ok = stbi_write_jpg_to_func(append, &g, w, h, comp, pixels, quality); break;
      case 2: ok = stbi_write_bmp_to_func(append, &g, w, h, comp, pixels); break;
      case 3: stbi_write_tga_with_rle = 0; ok = stbi_write_tga_to_func(append, &g, w, h, comp, pixels); break;
      case 4: stbi_write_tga_with_rle = 1; ok = stbi_write_tga_to_func(append, &g, w, h, comp, pixels); break;
      case 5: ok = stbi_write_hdr_to_func(append, &g, w, h, comp, (const float *) pixels); break;
   }
   if (!ok) { free(g.data); return NULL; }
   *len = g.len;
   return g.data;
}

void bench_free(void *p)
{
   free(p);
}
