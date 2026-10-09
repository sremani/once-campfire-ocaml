/* Thin ABI binding for the installed libqrencode 4 runtime. The development
 * header is unavailable in the deployment image, so keep the declarations
 * limited to the stable public ABI used here. */
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <string.h>

typedef struct {
  int version;
  int width;
  unsigned char *data;
} QRcode;
extern QRcode *QRcode_encodeData(int size, const unsigned char *data,
                                  int version, int level);
extern QRcode *QRcode_encodeString(const char *text, int version, int level,
                                    int hint, int casesensitive);
extern void QRcode_free(QRcode *code);

CAMLprim value campfire_qr_matrix(value input, value requested_version) {
  CAMLparam2(input, requested_version);
  CAMLlocal3(result, matrix, some);
  mlsize_t length = caml_string_length(input);
  if (length > 32767) CAMLreturn(Val_int(0));
  int version = (int)Long_val(requested_version);
  if (version < 1 || version > 40) CAMLreturn(Val_int(0));
  const char *bytes = String_val(input);
  int numeric = length > 0;
  int alphanumeric = length > 0;
  const char *alpha = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";
  for (mlsize_t i = 0; i < length; ++i) {
    if (bytes[i] < '0' || bytes[i] > '9') numeric = 0;
    if (bytes[i] == 0 || strchr(alpha, (unsigned char)bytes[i]) == NULL)
      alphanumeric = 0;
  }
  /* RQRCode encodes the entire value in one numeric, alphanumeric, or byte
   * segment. encodeString selects the former modes for pure-mode input;
   * encodeData forces one byte segment for everything else. */
  QRcode *code = (numeric || alphanumeric)
      ? QRcode_encodeString(bytes, version, 3 /* QR_ECLEVEL_H */,
                            2 /* QR_MODE_8 hint */, 1 /* preserve case */)
      : QRcode_encodeData((int)length,
                          (const unsigned char *)bytes, version, 3);
  if (code == NULL) CAMLreturn(Val_int(0));
  int width = code->width;
  if (width <= 0 || width > 177) {
    QRcode_free(code);
    CAMLreturn(Val_int(0));
  }
  matrix = caml_alloc_string((mlsize_t)width * (mlsize_t)width);
  for (int i = 0; i < width * width; ++i)
    Bytes_val(matrix)[i] = (code->data[i] & 1) ? '1' : '0';
  QRcode_free(code);
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(width));
  Store_field(result, 1, matrix);
  some = caml_alloc(1, 0);
  Store_field(some, 0, result);
  CAMLreturn(some);
}
