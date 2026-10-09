/* Converts the pinned Nokogiri Gumbo fragment tree into immutable OCaml nodes.
 * Parsing is bounded by the library's depth and attribute limits and a
 * per-call 64 MiB native allocation scope. */
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <string.h>
#include "../vendor/gumbo/nokogiri_gumbo.h"
#include "../vendor/gumbo/richtext_gumbo_alloc.h"

static value convert_node(const GumboNode *node);

static value convert_children(const GumboVector *nodes) {
  CAMLparam0();
  CAMLlocal3(list, cell, item);
  list = Val_emptylist;
  for (size_t i = nodes->length; i > 0; --i) {
    const GumboNode *node = (const GumboNode *)nodes->data[i - 1];
    item = convert_node(node);
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, item);
    Store_field(cell, 1, list);
    list = cell;
  }
  CAMLreturn(list);
}

static value convert_attrs(const GumboVector *attrs) {
  CAMLparam0();
  CAMLlocal4(list, cell, pair, name);
  list = Val_emptylist;
  for (size_t i = attrs->length; i > 0; --i) {
    const GumboAttribute *attr = (const GumboAttribute *)attrs->data[i - 1];
    pair = caml_alloc_tuple(2);
    const char *raw_name = attr->name ? attr->name : "";
    const char *prefix = attr->attr_namespace == GUMBO_ATTR_NAMESPACE_XLINK ? "xlink:" :
      attr->attr_namespace == GUMBO_ATTR_NAMESPACE_XML ? "xml:" :
      attr->attr_namespace == GUMBO_ATTR_NAMESPACE_XMLNS ? "xmlns:" : "";
    char qualified_name[512];
    if (strlen(prefix) + strlen(raw_name) < sizeof qualified_name) {
      strcpy(qualified_name, prefix);
      strcat(qualified_name, raw_name);
      name = caml_copy_string(qualified_name);
    } else {
      name = caml_copy_string(raw_name);
    }
    Store_field(pair, 0, name);
    Store_field(pair, 1, caml_copy_string(attr->value ? attr->value : ""));
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, pair);
    Store_field(cell, 1, list);
    list = cell;
  }
  CAMLreturn(list);
}

static value convert_node(const GumboNode *node) {
  CAMLparam0();
  CAMLlocal4(out, children, text_node, cell);
  if (node->type == GUMBO_NODE_COMMENT) {
    text_node = caml_alloc(1, 0);
    Store_field(text_node, 0, caml_copy_string(node->v.text.text ? node->v.text.text : ""));
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, text_node);
    Store_field(cell, 1, Val_emptylist);
    out = caml_alloc(4, 1);
    Store_field(out, 0, caml_copy_string("#comment"));
    Store_field(out, 1, Val_emptylist);
    Store_field(out, 2, cell);
    Store_field(out, 3, Val_bool(1));
    CAMLreturn(out);
  }
  if (node->type == GUMBO_NODE_TEXT || node->type == GUMBO_NODE_WHITESPACE ||
      node->type == GUMBO_NODE_CDATA) {
    out = caml_alloc(1, 0); /* Text */
    Store_field(out, 0, caml_copy_string(node->v.text.text ? node->v.text.text : ""));
    CAMLreturn(out);
  }
  if (node->type == GUMBO_NODE_ELEMENT || node->type == GUMBO_NODE_TEMPLATE) {
    out = caml_alloc(4, 1); /* Element(name, attrs, children, html_ns) */
    Store_field(out, 0, caml_copy_string(node->v.element.name ? node->v.element.name : ""));
    Store_field(out, 1, convert_attrs(&node->v.element.attributes));
    children = convert_children(&node->v.element.children);
    Store_field(out, 2, children);
    Store_field(out, 3, Val_bool(node->v.element.tag_namespace == GUMBO_NAMESPACE_HTML));
    CAMLreturn(out);
  }
  out = caml_alloc(1, 0);
  Store_field(out, 0, caml_copy_string(""));
  CAMLreturn(out);
}

CAMLprim value caml_campfire_gumbo_parse(value input) {
  CAMLparam1(input);
  CAMLlocal2(result, children);
  RTGumboScope scope;
  size_t used = 0;
  rt_gumbo_scope_begin(&scope, &used, 64u * 1024u * 1024u);
  if (setjmp(scope.escape)) {
    const char *error = scope.error ? scope.error : "rich-text parser allocation failed";
    rt_gumbo_scope_end(&scope);
    result = caml_alloc(1, 1);
    Store_field(result, 0, caml_copy_string(error));
    CAMLreturn(result);
  }
  GumboOptions options = kGumboDefaultOptions;
  /* Nokogiri's fragment parser counts the implicit HTML fragment root. */
  options.fragment_context = "body";
  options.max_tree_depth = 401;
  options.max_attributes = 400;
  options.max_errors = 0;
  GumboOutput *output = gumbo_parse_with_options(&options, String_val(input), caml_string_length(input));
  if (!output || output->status != GUMBO_STATUS_OK) {
    const char *error = !output ? "rich-text parser failed" :
      output->status == GUMBO_STATUS_TREE_TOO_DEEP ? "html: tree depth exceeds 400" :
      output->status == GUMBO_STATUS_TOO_MANY_ATTRIBUTES ? "html: more than 400 attributes" :
      "rich-text parser failed";
    if (output) gumbo_destroy_output(output);
    rt_gumbo_scope_end(&scope);
    result = caml_alloc(1, 1);
    Store_field(result, 0, caml_copy_string(error));
    CAMLreturn(result);
  }
  children = convert_children(&output->root->v.element.children);
  gumbo_destroy_output(output);
  rt_gumbo_scope_end(&scope);
  result = caml_alloc(1, 0);
  Store_field(result, 0, children);
  CAMLreturn(result);
}
