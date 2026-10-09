#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/threads.h>
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <stdint.h>

struct buffer { char *data; size_t len, cap, max; int too_large; };
struct transfer {
  struct buffer body, headers;
  double read_timeout, last_progress;
  int timed_out;
};

static double monotonic_seconds(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1000000000.0;
}

static size_t append(struct buffer *b, char *data, size_t size, size_t count) {
  if (size && count > SIZE_MAX / size) { b->too_large = 1; return 0; }
  size_t n = size * count;
  if (n > b->max - b->len) { b->too_large = 1; return 0; }
  if (b->len + n > b->cap) {
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + n) cap = cap > SIZE_MAX / 2 ? b->len + n : cap * 2;
    char *next = realloc(b->data, cap);
    if (!next) return 0;
    b->data = next; b->cap = cap;
  }
  memcpy(b->data + b->len, data, n);
  b->len += n;
  return n;
}

static size_t body_cb(char *data, size_t size, size_t count, void *context) {
  struct transfer *t = context;
  t->last_progress = monotonic_seconds();
  return append(&t->body, data, size, count);
}

static size_t header_cb(char *data, size_t size, size_t count, void *context) {
  struct transfer *t = context;
  t->last_progress = monotonic_seconds();
  return append(&t->headers, data, size, count);
}

static int progress_cb(void *context, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
  (void)a; (void)b; (void)c; (void)d;
  struct transfer *t = context;
  if (monotonic_seconds() - t->last_progress > t->read_timeout) {
    t->timed_out = 1; return 1;
  }
  return 0;
}

/* One synchronous exchange. The OCaml caller runs this in a worker thread;
   the runtime lock is released during the entire libcurl operation. */
CAMLprim value caml_campfire_curl_perform(value request) {
  CAMLparam1(request);
  CAMLlocal5(result, triple, headers, body, error);
  const char *url = String_val(Field(request, 0));
  const char *method = String_val(Field(request, 1));
  const char *pinned = String_val(Field(request, 2));
  value hdrs = Field(request, 3);
  value mlbody = Field(request, 4);
  long connect_ms = Long_val(Field(request, 5));
  long read_ms = Long_val(Field(request, 6));
  long deadline_ms = Long_val(Field(request, 7));
  size_t max_body = (size_t)Long_val(Field(request, 8));
  const char *ca_bundle = String_val(Field(request, 9));
  struct transfer t = {0};
  t.body.max = max_body;
  t.headers.max = 1024 * 1024;
  t.read_timeout = (double)read_ms / 1000.0;
  t.last_progress = monotonic_seconds();
  CURL *curl = curl_easy_init();
  struct curl_slist *out_headers = NULL, *resolve = NULL;
  char errbuf[CURL_ERROR_SIZE] = {0};
  CURLcode code = CURLE_FAILED_INIT;
  long status = 0;
  if (curl) {
    for (value node = hdrs; node != Val_emptylist; node = Field(node, 1)) {
      value pair = Field(node, 0);
      const char *key = String_val(Field(pair, 0));
      const char *val = String_val(Field(pair, 1));
      size_t n = strlen(key) + strlen(val) + 3;
      char *line = malloc(n);
      if (!line) continue;
      snprintf(line, n, "%s: %s", key, val);
      out_headers = curl_slist_append(out_headers, line);
      free(line);
    }
    out_headers = curl_slist_append(out_headers, "Expect:");
    if (*pinned) {
      CURLU *parsed = curl_url();
      char *host = NULL, *port = NULL;
      if (parsed && curl_url_set(parsed, CURLUPART_URL, url, 0) == CURLUE_OK &&
          curl_url_get(parsed, CURLUPART_HOST, &host, 0) == CURLUE_OK) {
        if (curl_url_get(parsed, CURLUPART_PORT, &port, CURLU_DEFAULT_PORT) == CURLUE_OK) {
          int v6 = strchr(pinned, ':') != NULL;
          size_t n = strlen(host) + strlen(port) + strlen(pinned) + 6;
          char *entry = malloc(n);
          if (entry) {
            snprintf(entry, n, v6 ? "%s:%s:[%s]" : "%s:%s:%s", host, port, pinned);
            resolve = curl_slist_append(resolve, entry);
            free(entry);
          }
        }
      }
      if (host) curl_free(host);
      if (port) curl_free(port);
      if (parsed) curl_url_cleanup(parsed);
    }
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 0L);
    curl_easy_setopt(curl, CURLOPT_PROXY, "");
    curl_easy_setopt(curl, CURLOPT_NOPROXY, "*");
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    if (*ca_bundle) curl_easy_setopt(curl, CURLOPT_CAINFO, ca_bundle);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, connect_ms);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, deadline_ms);
    /* libcurl calls XFERINFO at roughly second granularity while idle. Its
       low-speed watchdog supplies an independent read-idle bound. */
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, (long)((read_ms + 999) / 1000));
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, out_headers);
    curl_easy_setopt(curl, CURLOPT_RESOLVE, resolve);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "gzip,deflate");
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Ruby");
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, errbuf);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, body_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &t);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, header_cb);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &t);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, progress_cb);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &t);
    if (!strcmp(method, "HEAD")) curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
    if (!strcmp(method, "POST")) {
      curl_easy_setopt(curl, CURLOPT_POST, 1L);
      curl_easy_setopt(curl, CURLOPT_POSTFIELDS, String_val(mlbody));
      curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)caml_string_length(mlbody));
    }
    if (!*pinned || resolve) {
      caml_release_runtime_system();
      code = curl_easy_perform(curl);
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
      caml_acquire_runtime_system();
    } else {
      code = CURLE_URL_MALFORMAT;
    }
  }
  if (code == CURLE_OK) {
    headers = caml_alloc_initialized_string(t.headers.len, t.headers.data ? t.headers.data : "");
    body = caml_alloc_initialized_string(t.body.len, t.body.data ? t.body.data : "");
    triple = caml_alloc_tuple(3);
    Store_field(triple, 0, Val_long(status));
    Store_field(triple, 1, headers);
    Store_field(triple, 2, body);
    result = caml_alloc(1, 0); Store_field(result, 0, triple);
  } else {
    const char *message = t.body.too_large ? "body too large" :
      t.headers.too_large ? "headers too large" :
      t.timed_out ? "read timeout" :
      code == CURLE_OPERATION_TIMEDOUT ? "timeout" :
      *errbuf ? errbuf : curl_easy_strerror(code);
    error = caml_copy_string(message);
    result = caml_alloc(1, 1); Store_field(result, 0, error);
  }
  if (curl) curl_easy_cleanup(curl);
  curl_slist_free_all(out_headers);
  curl_slist_free_all(resolve);
  free(t.body.data); free(t.headers.data);
  CAMLreturn(result);
}
