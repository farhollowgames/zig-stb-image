/* The tests' interface to the original stb_image, built twice: once with
   its SIMD paths (prefix simd_) and once with STBI_NO_SIMD and
   STBI_FAILURE_USERMSG (prefix scalar_), so the two builds also give the
   two forms of each failure reason. Every call sets the original's global
   and thread-local settings from `oracle_settings` first and clears its
   failure reason. Test-only code. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The original's allocations. While `malloc_fill` is 0 to 255, each new
   block (and each block's growth) is filled with it first, so a test can
   tell a result that depends on memory the original never wrote: it
   changes with the fill. */
static int malloc_fill = -1;

static void *oracle_malloc(size_t size)
{
   void *p = malloc(size);
   if (p && malloc_fill >= 0) memset(p, malloc_fill, size);
   return p;
}

static void *oracle_realloc(void *p, size_t old_size, size_t new_size)
{
   unsigned char *q = (unsigned char *) realloc(p, new_size);
   if (q && malloc_fill >= 0 && new_size > old_size)
      memset(q + old_size, malloc_fill, new_size - old_size);
   return q;
}

#define STBI_MALLOC(size) oracle_malloc(size)
#define STBI_REALLOC(p, size) realloc(p, size)
#define STBI_REALLOC_SIZED(p, old_size, new_size) oracle_realloc(p, old_size, new_size)
#define STBI_FREE(p) free(p)

#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define ORACLE_CAT2(a, b) a##_##b
#define ORACLE_CAT(a, b) ORACLE_CAT2(a, b)
#define F(name) ORACLE_CAT(ORACLE_PREFIX, name)

enum { VIA_MEMORY = 0, VIA_CALLBACKS = 1, VIA_FILE = 2 };

typedef struct {
   int via;
   int fd; /* VIA_FILE: read from its current offset */
   int req_comp;
   int flip, flip_thread; /* thread: -1 leaves the thread-local unset */
   int unpremultiply, unpremultiply_thread;
   int iphone, iphone_thread;
   float l2h_gamma, l2h_scale, h2l_gamma, h2l_scale;
} oracle_settings;

typedef struct {
   void *pixels;
   int x, y, comp;
   int z;       /* GIF frames */
   int *delays; /* GIF delays */
   const char *reason;
   long pos_after; /* VIA_FILE: ftell after the call */
} oracle_result;

/* A memory stream behind the callbacks, with feof's semantics: a short read
   sets the end flag, and a skip sets it anew, as stb_image's own stdio
   callbacks do with fseek and fgetc. */
typedef struct {
   const unsigned char *data;
   size_t len, pos;
   int eof;
} mem_stream;

static int ms_read(void *user, char *out, int size)
{
   mem_stream *ms = (mem_stream *) user;
   size_t left = ms->pos < ms->len ? ms->len - ms->pos : 0;
   size_t n = (size_t) size < left ? (size_t) size : left;
   memcpy(out, ms->data + ms->pos, n);
   ms->pos += n;
   if (n < (size_t) size) ms->eof = 1;
   return (int) n;
}

static void ms_skip(void *user, int n)
{
   mem_stream *ms = (mem_stream *) user;
   ms->pos += (size_t) n;
   ms->eof = ms->pos >= ms->len;
}

static int ms_eof(void *user)
{
   return ((mem_stream *) user)->eof;
}

static stbi_io_callbacks ms_callbacks = { ms_read, ms_skip, ms_eof };

static void apply(const oracle_settings *s)
{
   stbi_set_flip_vertically_on_load(s->flip);
   stbi__vertically_flip_on_load_set = 0;
   if (s->flip_thread >= 0) stbi_set_flip_vertically_on_load_thread(s->flip_thread);
   stbi_set_unpremultiply_on_load(s->unpremultiply);
   stbi__unpremultiply_on_load_set = 0;
   if (s->unpremultiply_thread >= 0) stbi_set_unpremultiply_on_load_thread(s->unpremultiply_thread);
   stbi_convert_iphone_png_to_rgb(s->iphone);
   stbi__de_iphone_flag_set = 0;
   if (s->iphone_thread >= 0) stbi_convert_iphone_png_to_rgb_thread(s->iphone_thread);
   stbi_ldr_to_hdr_gamma(s->l2h_gamma);
   stbi_ldr_to_hdr_scale(s->l2h_scale);
   stbi_hdr_to_ldr_gamma(s->h2l_gamma);
   stbi_hdr_to_ldr_scale(s->h2l_scale);
   stbi__g_failure_reason = NULL;
}

static FILE *open_fd(int fd)
{
   int copy = dup(fd);
   FILE *f;
   if (copy < 0) return NULL;
   f = fdopen(copy, "rb");
   if (!f) close(copy);
   return f;
}

/* bits: 8, 16, or 32 for floats. */
void F(load)(const unsigned char *bytes, size_t len, int bits, const oracle_settings *s,
             oracle_result *out)
{
   memset(out, 0, sizeof(*out));
   apply(s);
   if (s->via == VIA_MEMORY) {
      if (bits == 8) out->pixels = stbi_load_from_memory(bytes, (int) len, &out->x, &out->y, &out->comp, s->req_comp);
      if (bits == 16) out->pixels = stbi_load_16_from_memory(bytes, (int) len, &out->x, &out->y, &out->comp, s->req_comp);
      if (bits == 32) out->pixels = stbi_loadf_from_memory(bytes, (int) len, &out->x, &out->y, &out->comp, s->req_comp);
   } else if (s->via == VIA_CALLBACKS) {
      mem_stream ms = { bytes, len, 0, 0 };
      if (bits == 8) out->pixels = stbi_load_from_callbacks(&ms_callbacks, &ms, &out->x, &out->y, &out->comp, s->req_comp);
      if (bits == 16) out->pixels = stbi_load_16_from_callbacks(&ms_callbacks, &ms, &out->x, &out->y, &out->comp, s->req_comp);
      if (bits == 32) out->pixels = stbi_loadf_from_callbacks(&ms_callbacks, &ms, &out->x, &out->y, &out->comp, s->req_comp);
   } else {
      FILE *f = open_fd(s->fd);
      if (!f) { out->reason = "oracle: fdopen"; return; }
      if (bits == 8) out->pixels = stbi_load_from_file(f, &out->x, &out->y, &out->comp, s->req_comp);
      if (bits == 16) out->pixels = stbi_load_from_file_16(f, &out->x, &out->y, &out->comp, s->req_comp);
      if (bits == 32) out->pixels = stbi_loadf_from_file(f, &out->x, &out->y, &out->comp, s->req_comp);
      out->pos_after = ftell(f);
      fclose(f);
   }
   out->reason = stbi_failure_reason();
}

void F(load_gif)(const unsigned char *bytes, size_t len, const oracle_settings *s, oracle_result *out)
{
   memset(out, 0, sizeof(*out));
   apply(s);
   out->pixels = stbi_load_gif_from_memory(bytes, (int) len, &out->delays, &out->x, &out->y, &out->z,
                                           &out->comp, s->req_comp);
   out->reason = stbi_failure_reason();
}

void F(free)(void *p)
{
   STBI_FREE(p);
}

/* fill: 0 to 255 fills every allocation of the original with it; -1 leaves
   allocations as malloc gives them. */
void F(set_malloc_fill)(int fill)
{
   malloc_fill = fill;
}

/* What: 0 info, 1 is_16_bit, 2 is_hdr. Returns the call's result. */
int F(query)(const unsigned char *bytes, size_t len, int what, const oracle_settings *s,
             oracle_result *out)
{
   int r = 0;
   memset(out, 0, sizeof(*out));
   apply(s);
   if (s->via == VIA_MEMORY) {
      if (what == 0) r = stbi_info_from_memory(bytes, (int) len, &out->x, &out->y, &out->comp);
      if (what == 1) r = stbi_is_16_bit_from_memory(bytes, (int) len);
      if (what == 2) r = stbi_is_hdr_from_memory(bytes, (int) len);
   } else if (s->via == VIA_CALLBACKS) {
      mem_stream ms = { bytes, len, 0, 0 };
      if (what == 0) r = stbi_info_from_callbacks(&ms_callbacks, &ms, &out->x, &out->y, &out->comp);
      if (what == 1) r = stbi_is_16_bit_from_callbacks(&ms_callbacks, &ms);
      if (what == 2) r = stbi_is_hdr_from_callbacks(&ms_callbacks, &ms);
   } else {
      FILE *f = open_fd(s->fd);
      if (!f) { out->reason = "oracle: fdopen"; return 0; }
      if (what == 0) r = stbi_info_from_file(f, &out->x, &out->y, &out->comp);
      if (what == 1) r = stbi_is_16_bit_from_file(f);
      if (what == 2) r = stbi_is_hdr_from_file(f);
      out->pos_after = ftell(f);
      fclose(f);
   }
   out->reason = stbi_failure_reason();
   return r;
}

/* The six stbi_zlib_* functions. which: 0 decode_malloc_guesssize,
   1 decode_malloc, 2 decode_malloc_guesssize_headerflag, 3 decode_buffer,
   4 decode_noheader_malloc, 5 decode_noheader_buffer. The malloc forms
   return the buffer and set *outlen; the buffer forms write `obuffer` and
   return the length or -1. */
char *F(zlib)(int which, const char *buffer, int len, int initial_size, int parse_header,
              char *obuffer, int olen, int *outlen, const char **reason)
{
   char *r = NULL;
   stbi__g_failure_reason = NULL;
   *outlen = 0;
   switch (which) {
      case 0: r = stbi_zlib_decode_malloc_guesssize(buffer, len, initial_size, outlen); break;
      case 1: r = stbi_zlib_decode_malloc(buffer, len, outlen); break;
      case 2: r = stbi_zlib_decode_malloc_guesssize_headerflag(buffer, len, initial_size, outlen, parse_header); break;
      case 3: *outlen = stbi_zlib_decode_buffer(obuffer, olen, buffer, len); break;
      case 4: r = stbi_zlib_decode_noheader_malloc(buffer, len, outlen); break;
      case 5: *outlen = stbi_zlib_decode_noheader_buffer(obuffer, olen, buffer, len); break;
   }
   *reason = stbi_failure_reason();
   return r;
}

/* The C library's pow, as stb_image calls it. */
double F(pow)(double x, double y)
{
   return pow(x, y);
}

/* The original's flags, for the tests of its setters. which: 0 flip,
   1 unpremultiply, 2 iPhone conversion; thread: the calling thread's
   setter rather than the process-wide one. */
void F(set_flag)(int which, int thread, int value)
{
   switch (which) {
      case 0:
         if (thread) stbi_set_flip_vertically_on_load_thread(value);
         else stbi_set_flip_vertically_on_load(value);
         break;
      case 1:
         if (thread) stbi_set_unpremultiply_on_load_thread(value);
         else stbi_set_unpremultiply_on_load(value);
         break;
      case 2:
         if (thread) stbi_convert_iphone_png_to_rgb_thread(value);
         else stbi_convert_iphone_png_to_rgb(value);
         break;
   }
}

/* The flags a load on the calling thread would use. */
void F(get_flags)(int *flip, int *unpremultiply, int *iphone)
{
   *flip = stbi__vertically_flip_on_load;
   *unpremultiply = stbi__unpremultiply_on_load;
   *iphone = stbi__de_iphone_flag;
}
