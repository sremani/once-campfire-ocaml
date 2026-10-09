#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <zlib.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <stdint.h>

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

/* A PageParts piece is a separate raw deflate stream, sync-flushed at a byte
   boundary. Its dictionary is the preceding part's text or fragment (without
   the fragment's glue), just as in the pinned front's splice compressor. */
CAMLprim value campfire_deflate_piece(value dictionary, value input) {
  CAMLparam2(dictionary, input);
  CAMLlocal3(piece, checksum, result);
  size_t input_len = caml_string_length(input);
  size_t dictionary_len = caml_string_length(dictionary);
  if (input_len > UINT_MAX) caml_invalid_argument("deflate piece too large");
  const Bytef *dictionary_bytes = (const Bytef *)String_val(dictionary);
  if (dictionary_len > 32768) {
    dictionary_bytes += dictionary_len - 32768;
    dictionary_len = 32768;
  }
  uLong bound = compressBound((uLong)input_len);
  if (bound > SIZE_MAX - 64) caml_invalid_argument("deflate piece too large");
  size_t capacity = (size_t)bound + 64;
  if (capacity > UINT_MAX) caml_invalid_argument("deflate piece too large");
  Bytef *output = malloc(capacity);
  if (!output) caml_failwith("deflate piece allocation failed");
  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  int code = deflateInit2(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY);
  if (code != Z_OK) {
    free(output);
    caml_failwith("deflate piece init failed");
  }
  if (dictionary_len != 0 &&
      deflateSetDictionary(&stream, dictionary_bytes, (uInt)dictionary_len) != Z_OK) {
    deflateEnd(&stream);
    free(output);
    caml_failwith("deflate piece dictionary failed");
  }
  stream.next_in = (Bytef *)String_val(input);
  stream.avail_in = (uInt)input_len;
  stream.next_out = output;
  stream.avail_out = (uInt)capacity;
  code = deflate(&stream, Z_SYNC_FLUSH);
  size_t output_len = stream.total_out;
  deflateEnd(&stream);
  if (code != Z_OK || stream.avail_in != 0 || stream.avail_out == 0) {
    free(output);
    caml_failwith("deflate piece compression failed");
  }
  uLong crc = crc32(0L, Z_NULL, 0);
  crc = crc32(crc, (const Bytef *)String_val(input), (uInt)input_len);
  piece = caml_alloc_initialized_string(output_len, (const char *)output);
  free(output);
  checksum = caml_copy_int32((int32_t)crc);
  result = caml_alloc_tuple(2);
  Store_field(result, 0, piece);
  Store_field(result, 1, checksum);
  CAMLreturn(result);
}

CAMLprim value campfire_crc32_combine(value first, value second, value length) {
  CAMLparam3(first, second, length);
  uLong crc = crc32_combine((uLong)(uint32_t)Int32_val(first),
                            (uLong)(uint32_t)Int32_val(second),
                            (z_off_t)Int64_val(length));
  CAMLreturn(caml_copy_int32((int32_t)crc));
}
