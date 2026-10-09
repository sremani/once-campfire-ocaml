/* The ruby-vips/image_processing calls used by Campfire.  Load libvips at
 * runtime because the development host need not have libvips installed; the
 * production and vector-test image supplies the pinned 8.16.1 library. */
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void VipsImage;
typedef int (*init_fn)(const char *);
typedef const char *(*version_fn)(void);
typedef void (*block_fn)(int);
typedef void (*operation_block_fn)(const char *, int);
typedef char *(*error_fn)(void);
typedef void (*clear_fn)(void);
typedef VipsImage *(*load_fn)(const char *, ...);
typedef int (*autorot_fn)(VipsImage *, VipsImage **, ...);
typedef int (*thumbnail_fn)(VipsImage *, VipsImage **, int, ...);
typedef int (*conv_fn)(VipsImage *, VipsImage **, VipsImage *, ...);
typedef int (*save_fn)(VipsImage *, const char *, ...);
typedef VipsImage *(*matrix_fn)(int, int, const double *, int);
typedef void (*set_double_fn)(VipsImage *, const char *, double);
typedef int (*get_int_fn)(const VipsImage *);
typedef size_t (*get_typeof_fn)(const VipsImage *, const char *);
typedef int (*get_as_string_fn)(const VipsImage *, const char *, char **);
typedef const char *(*find_load_fn)(const char *);
typedef void *(*operation_new_fn)(const char *);
typedef int (*object_args_fn)(void *, const char ***, const int **, int *);
typedef void (*free_fn)(void *);

static struct {
  init_fn init;
  version_fn version;
  block_fn block_untrusted;
  operation_block_fn block_operation;
  error_fn error;
  clear_fn clear;
  load_fn load;
  autorot_fn autorot;
  thumbnail_fn thumbnail;
  conv_fn conv;
  save_fn save;
  matrix_fn matrix;
  set_double_fn set_double;
  get_int_fn width, height;
  get_typeof_fn get_typeof;
  get_as_string_fn get_as_string;
  find_load_fn find_load;
  operation_new_fn operation_new;
  object_args_fn object_args;
  free_fn unref, gfree;
} v;

static pthread_once_t once = PTHREAD_ONCE_INIT;
static char init_error[256];

static void *symbol(void *handle, const char *name) {
  void *result = dlsym(handle, name);
  if (!result && !init_error[0])
    snprintf(init_error, sizeof init_error, "missing libvips symbol %s", name);
  return result;
}

#define LOAD(field, handle, name) v.field = (void *)symbol(handle, name)

static void initialize_vips(void) {
  const char *path = getenv("CAMPFIRE_LIBVIPS_PATH");
  void *lib = dlopen(path && path[0] ? path : "libvips.so.42", RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    snprintf(init_error, sizeof init_error, "libvips unavailable: %s", dlerror());
    return;
  }
  void *gobject = dlopen("libgobject-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
  void *glib = dlopen("libglib-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!gobject || !glib) {
    snprintf(init_error, sizeof init_error, "libvips GLib dependencies unavailable");
    return;
  }
  LOAD(init, lib, "vips_init");
  LOAD(version, lib, "vips_version_string");
  LOAD(block_untrusted, lib, "vips_block_untrusted_set");
  LOAD(block_operation, lib, "vips_operation_block_set");
  LOAD(error, lib, "vips_error_buffer_copy");
  LOAD(clear, lib, "vips_error_clear");
  LOAD(load, lib, "vips_image_new_from_file");
  LOAD(autorot, lib, "vips_autorot");
  LOAD(thumbnail, lib, "vips_thumbnail_image");
  LOAD(conv, lib, "vips_conv");
  LOAD(save, lib, "vips_image_write_to_file");
  LOAD(matrix, lib, "vips_image_new_matrix_from_array");
  LOAD(set_double, lib, "vips_image_set_double");
  LOAD(width, lib, "vips_image_get_width");
  LOAD(height, lib, "vips_image_get_height");
  LOAD(get_typeof, lib, "vips_image_get_typeof");
  LOAD(get_as_string, lib, "vips_image_get_as_string");
  LOAD(find_load, lib, "vips_foreign_find_load");
  LOAD(operation_new, lib, "vips_operation_new");
  LOAD(object_args, lib, "vips_object_get_args");
  LOAD(unref, gobject, "g_object_unref");
  LOAD(gfree, glib, "g_free");
  if (init_error[0]) return;
  if (v.init("campfire") != 0) {
    snprintf(init_error, sizeof init_error, "vips_init failed");
    return;
  }
  v.block_untrusted(1);
  v.block_operation("VipsForeignLoadOpenslide", 1);
}

static void check_init(void) {
  pthread_once(&once, initialize_vips);
  if (init_error[0]) caml_failwith(init_error);
}

static void take_error(char *out, size_t size) {
  char *error = v.error();
  snprintf(out, size, "%s", error ? error : "libvips operation failed");
  if (error) v.gfree(error);
}

/* ruby-vips Introspect passes page:0 only to loaders that declare an optional
 * construct-time page input.  Checking the full argument table avoids writing
 * harmless but accumulating libvips errors on JPEG and PNG. */
static int loader_accepts_page(const char *path) {
  const char *loader = v.find_load(path);
  if (!loader) { v.clear(); return 0; }
  void *operation = v.operation_new(loader);
  if (!operation) { v.clear(); return 0; }
  const char **names = NULL;
  const int *flags = NULL;
  int count = 0, accepts = 0;
  if (v.object_args(operation, &names, &flags, &count) == 0) {
    for (int i = 0; i < count; ++i) {
      int required = (flags[i] & 1) && !(flags[i] & 64);
      if (strcmp(names[i], "page") == 0 &&
          (flags[i] & 2) && (flags[i] & 16) && !required) {
        accepts = 1;
        break;
      }
    }
  }
  v.unref(operation);
  return accepts;
}

CAMLprim value caml_storage_vips_version(value unit) {
  CAMLparam1(unit);
  check_init();
  CAMLreturn(caml_copy_string(v.version()));
}

/* Returns (width, height, EXIF orientation) or None for a corrupt image. */
CAMLprim value caml_storage_vips_analyze(value path) {
  CAMLparam1(path);
  CAMLlocal3(result, tuple, orientation);
  check_init();
  char *name = strdup(String_val(path));
  if (!name) caml_raise_out_of_memory();
  int width = 0, height = 0;
  char *description = NULL;
  caml_enter_blocking_section();
  VipsImage *image = v.load(name, "access", 1, NULL);
  if (image) {
    width = v.width(image);
    height = v.height(image);
    if (v.get_typeof(image, "exif-ifd0-Orientation") != 0)
      if (v.get_as_string(image, "exif-ifd0-Orientation", &description) != 0)
        v.clear();
    v.unref(image);
  } else v.clear();
  caml_leave_blocking_section();
  free(name);
  if (!image) CAMLreturn(Val_int(0));
  orientation = description ? caml_alloc(1, 0) : Val_int(0);
  if (description) {
    Store_field(orientation, 0, caml_copy_string(description));
    v.gfree(description);
  }
  tuple = caml_alloc_tuple(3);
  Store_field(tuple, 0, Val_int(width));
  Store_field(tuple, 1, Val_int(height));
  Store_field(tuple, 2, orientation);
  result = caml_alloc(1, 0);
  Store_field(result, 0, tuple);
  CAMLreturn(result);
}

/* Each dimension pair is (width option, height option), checked in OCaml.
 * The output filename's extension selects the libvips saver and its defaults. */
CAMLprim value caml_storage_vips_transform(value source, value target,
                                           value dimensions) {
  CAMLparam3(source, target, dimensions);
  check_init();
  char *input = strdup(String_val(source));
  char *output = strdup(String_val(target));
  if (!input || !output) { free(input); free(output); caml_raise_out_of_memory(); }
  size_t count = 0;
  for (value list = dimensions; list != Val_int(0); list = Field(list, 1)) ++count;
  int *widths = malloc((count ? count : 1) * sizeof(int));
  int *heights = malloc((count ? count : 1) * sizeof(int));
  if (!widths || !heights) {
    free(input); free(output); free(widths); free(heights);
    caml_raise_out_of_memory();
  }
  size_t at = 0;
  for (value list = dimensions; list != Val_int(0); list = Field(list, 1)) {
    value pair = Field(list, 0);
    value w = Field(pair, 0), h = Field(pair, 1);
    widths[at] = Is_block(w) ? Int_val(Field(w, 0)) : 10000000;
    heights[at] = Is_block(h) ? Int_val(Field(h, 0)) : 10000000;
    ++at;
  }
  char error[10240] = {0};
  caml_enter_blocking_section();
  VipsImage *image = NULL;
  if (loader_accepts_page(input)) image = v.load(input, "page", 0, NULL);
  else image = v.load(input, NULL);
  if (!image) goto fail;
  VipsImage *rotated = NULL;
  if (v.autorot(image, &rotated, NULL) != 0 || !rotated) goto fail;
  v.unref(image);
  image = rotated;
  for (size_t i = 0; i < count; ++i) {
    VipsImage *thumbnail = NULL, *sharpened = NULL;
    if (v.thumbnail(image, &thumbnail, widths[i], "height", heights[i],
                    "size", 2, "no_rotate", 1, NULL) != 0 || !thumbnail)
      goto fail;
    static const double sharpen[] = {-1,-1,-1,-1,32,-1,-1,-1,-1};
    VipsImage *mask = v.matrix(3, 3, sharpen, 9);
    if (!mask) { v.unref(thumbnail); goto fail; }
    v.set_double(mask, "scale", 24.0);
    v.set_double(mask, "offset", 0.0);
    int status = v.conv(thumbnail, &sharpened, mask, "precision", 0, NULL);
    v.unref(mask);
    v.unref(thumbnail);
    if (status != 0 || !sharpened) goto fail;
    v.unref(image);
    image = sharpened;
  }
  if (v.save(image, output, NULL) != 0) goto fail;
  v.unref(image);
  caml_leave_blocking_section();
  free(input); free(output); free(widths); free(heights);
  CAMLreturn(Val_unit);
fail:
  take_error(error, sizeof error);
  if (image) v.unref(image);
  caml_leave_blocking_section();
  free(input); free(output); free(widths); free(heights);
  caml_failwith(error);
}
