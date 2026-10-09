#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <crypt.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static void wipe(char *p, size_t n) {
  volatile char *v = (volatile char *)p;
  while (n-- > 0) *v++ = 0;
}

/* crypt_r is reentrant. Copy OCaml strings before releasing the runtime lock,
   and wipe the password and crypt_data as soon as the calculation finishes. */
CAMLprim value campfire_crypt_bcrypt(value password, value setting) {
  size_t password_len = caml_string_length(password);
  size_t setting_len = caml_string_length(setting);
  if (memchr(String_val(password), 0, password_len) != NULL ||
      memchr(String_val(setting), 0, setting_len) != NULL)
    caml_invalid_argument("bcrypt input contains NUL");

  char *password_copy = malloc(password_len + 1);
  char *setting_copy = malloc(setting_len + 1);
  struct crypt_data *data = calloc(1, sizeof(struct crypt_data));
  if (password_copy == NULL || setting_copy == NULL || data == NULL) {
    free(password_copy);
    free(setting_copy);
    free(data);
    caml_raise_out_of_memory();
  }
  memcpy(password_copy, String_val(password), password_len);
  password_copy[password_len] = 0;
  memcpy(setting_copy, String_val(setting), setting_len);
  setting_copy[setting_len] = 0;

  char hash[128] = {0};
  caml_enter_blocking_section();
  char *result = crypt_r(password_copy, setting_copy, data);
  int saved_errno = errno;
  if (result != NULL && strlen(result) < sizeof(hash))
    strcpy(hash, result);
  wipe(password_copy, password_len + 1);
  wipe((char *)data, sizeof(struct crypt_data));
  free(password_copy);
  free(setting_copy);
  free(data);
  caml_leave_blocking_section();

  if (hash[0] == 0 || hash[0] == '*') {
    (void)saved_errno;
    caml_failwith("bcrypt calculation failed");
  }
  value out = caml_copy_string(hash);
  wipe(hash, sizeof(hash));
  return out;
}
