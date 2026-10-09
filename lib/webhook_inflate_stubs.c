#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <zlib.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

struct inflater { z_stream stream; int initialized, finished; };

static int next_member(struct inflater *i) {
  Bytef *next = i->stream.next_in;
  uInt remaining = i->stream.avail_in;
  if (inflateReset2(&i->stream, 15 + 32) != Z_OK) return 0;
  i->stream.next_in = next;
  i->stream.avail_in = remaining;
  i->finished = 0;
  return 1;
}

static void finalize_inflater(value state) {
  struct inflater *i = Data_custom_val(state);
  if (i->initialized) inflateEnd(&i->stream);
  i->initialized = 0;
}

static struct custom_operations inflater_ops = {
  "campfire.webhook_inflater", finalize_inflater,
  custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

CAMLprim value caml_campfire_webhook_inflater(value gzip) {
  CAMLparam1(gzip);
  value state = caml_alloc_custom(&inflater_ops, sizeof(struct inflater), 0, 1);
  struct inflater *i = Data_custom_val(state);
  memset(i, 0, sizeof(*i));
  (void)gzip;
  /* Net::HTTP's inflater accepts either gzip or zlib framing for all three
     advertised compressed content encodings. */
  i->initialized = inflateInit2(&i->stream, 15 + 32) == Z_OK;
  CAMLreturn(state);
}

static value error_result(const char *message) {
  CAMLparam0();
  CAMLlocal2(result, text);
  text = caml_copy_string(message);
  result = caml_alloc(1, 1);
  Store_field(result, 0, text);
  CAMLreturn(result);
}

CAMLprim value caml_campfire_webhook_inflate(value state, value input,
                                             value max_output, value final) {
  CAMLparam4(state, input, max_output, final);
  CAMLlocal3(result, text, wrapped);
  struct inflater *i = Data_custom_val(state);
  if (!i->initialized) CAMLreturn(error_result("inflate initialization failed"));
  if (i->finished && caml_string_length(input) == 0) {
    text = caml_copy_string("");
    result = caml_alloc(1, 0); Store_field(result, 0, text);
    CAMLreturn(result);
  }
  size_t limit = (size_t)Long_val(max_output);
  size_t length = 0, capacity = 0;
  char *output = NULL;
  i->stream.next_in = (Bytef *)String_val(input);
  i->stream.avail_in = (uInt)caml_string_length(input);
  if (i->finished && !next_member(i))
    CAMLreturn(error_result("inflate reset failed"));
  int code = Z_OK;
  do {
    char block[16384];
    uInt available = sizeof(block);
    if (limit - length < available) available = (uInt)(limit - length + 1);
    i->stream.next_out = (Bytef *)block;
    i->stream.avail_out = available;
    uInt before_in = i->stream.avail_in;
    code = inflate(&i->stream, Bool_val(final) ? Z_FINISH : Z_NO_FLUSH);
    size_t produced = available - i->stream.avail_out;
    if (produced > limit - length) {
      free(output);
      CAMLreturn(error_result("body too large"));
    }
    if (produced) {
      if (length + produced > capacity) {
        size_t next = capacity ? capacity * 2 : 16384;
        if (next < length + produced) next = length + produced;
        if (next > limit) next = limit;
        char *new_output = realloc(output, next);
        if (!new_output) { free(output); CAMLreturn(error_result("inflate allocation failed")); }
        output = new_output; capacity = next;
      }
      memcpy(output + length, block, produced);
      length += produced;
    }
    if (code == Z_STREAM_END) {
      i->finished = 1;
      if (i->stream.avail_in > 0) {
        if (!next_member(i)) {
          free(output); CAMLreturn(error_result("inflate reset failed"));
        }
        code = Z_OK;
        continue;
      }
      break;
    }
    if (code != Z_OK && code != Z_BUF_ERROR) {
      free(output); CAMLreturn(error_result("inflate failed"));
    }
    if (before_in == i->stream.avail_in && produced == 0) break;
  } while (i->stream.avail_in > 0 || (Bool_val(final) && code == Z_OK));
  if (Bool_val(final) && !i->finished) {
    free(output); CAMLreturn(error_result("incomplete compressed response"));
  }
  text = caml_alloc_initialized_string(length, output ? output : "");
  free(output);
  result = caml_alloc(1, 0); Store_field(result, 0, text);
  CAMLreturn(result);
}
