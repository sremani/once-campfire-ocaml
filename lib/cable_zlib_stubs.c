#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

/* RFC 7692 uses raw DEFLATE and omits the 00 00 ff ff sync-flush tail. */
CAMLprim value campfire_cable_deflate(value input) {
  CAMLparam1(input);
  CAMLlocal1(result);
  mlsize_t len = caml_string_length(input);
  if (len > UINT_MAX) caml_failwith("cable deflate input too large");
  z_stream stream = {0};
  if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                   -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK)
    caml_failwith("cable deflate init failed");
  uLong bound = deflateBound(&stream, (uLong)len) + 16;
  unsigned char *out = malloc(bound);
  if (!out) { deflateEnd(&stream); caml_raise_out_of_memory(); }
  stream.next_in = (Bytef *)String_val(input);
  stream.avail_in = (uInt)len;
  stream.next_out = out;
  stream.avail_out = (uInt)bound;
  int status = deflate(&stream, Z_SYNC_FLUSH);
  size_t written = stream.total_out;
  deflateEnd(&stream);
  if (status != Z_OK || written < 4 || memcmp(out + written - 4, "\0\0\xff\xff", 4)) {
    free(out); caml_failwith("cable deflate failed");
  }
  result = caml_alloc_string(written - 4);
  memcpy((void *)String_val(result), out, written - 4);
  free(out);
  CAMLreturn(result);
}

/* Return at most limit bytes; fail before an inflation bomb can grow memory. */
CAMLprim value campfire_cable_inflate(value input, value max_output) {
  CAMLparam2(input, max_output);
  CAMLlocal1(result);
  mlsize_t len = caml_string_length(input);
  int limit = Int_val(max_output);
  if (limit < 0 || len > UINT_MAX - 4) caml_invalid_argument("cable inflate limit");
  unsigned char *payload = malloc(len + 4);
  unsigned char *out = malloc((size_t)limit + 1);
  if (!payload || !out) { free(payload); free(out); caml_raise_out_of_memory(); }
  memcpy(payload, String_val(input), len);
  memcpy(payload + len, "\0\0\xff\xff", 4);
  z_stream stream = {0};
  if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
    free(payload); free(out); caml_failwith("cable inflate init failed");
  }
  stream.next_in = payload;
  stream.avail_in = (uInt)(len + 4);
  stream.next_out = out;
  stream.avail_out = (uInt)limit + 1;
  int status = inflate(&stream, Z_SYNC_FLUSH);
  size_t written = stream.total_out;
  inflateEnd(&stream);
  free(payload);
  if (written > (size_t)limit) { free(out); caml_failwith("cable inflated message too large"); }
  if (status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR) {
    free(out); caml_failwith("cable invalid deflate data");
  }
  result = caml_alloc_string(written);
  memcpy((void *)String_val(result), out, written);
  free(out);
  CAMLreturn(result);
}
