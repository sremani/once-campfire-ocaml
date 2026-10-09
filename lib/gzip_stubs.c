#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <zlib.h>
#include <string.h>

/* zlib is the distribution's gzip implementation. The per-call stream has no
   shared state, so compression is safe across Cohttp request workers. */
CAMLprim value campfire_gzip(value input) {
  CAMLparam1(input);
  CAMLlocal1(result);
  mlsize_t input_len = caml_string_length(input);
  if (input_len > UINT_MAX) caml_invalid_argument("gzip input too large");
  uLong bound = compressBound((uLong)input_len) + 32;
  result = caml_alloc_string((mlsize_t)bound);

  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  stream.next_in = (Bytef *)String_val(input);
  stream.avail_in = (uInt)input_len;
  stream.next_out = (Bytef *)Bytes_val(result);
  stream.avail_out = (uInt)bound;
  if (deflateInit2(&stream, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK)
    caml_failwith("gzip init failed");
  int code = deflate(&stream, Z_FINISH);
  deflateEnd(&stream);
  if (code != Z_STREAM_END) caml_failwith("gzip compression failed");
  value exact = caml_alloc_string((mlsize_t)stream.total_out);
  memcpy(Bytes_val(exact), Bytes_val(result), (size_t)stream.total_out);
  CAMLreturn(exact);
}
