"""Structural Campfire view comparison against the pinned Rails golden.

The reference's canonical tokens include whitespace-only text and Rails CSRF
inputs. This test compares every element, attribute and nonempty text node in
the message stream, while allowing the documented relative Copy-link URL.
"""

import html.parser
import json
import re
import sys
from urllib.parse import urlsplit


class Tokens(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.items = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        # HTML boolean attributes have the same DOM value whether serialized
        # bare (Askama) or with an empty value (Tyxml).
        for name in ("readonly", "disabled", "required", "checked", "multiple", "hidden"):
            if name in values:
                values[name] = None
        if "contents" in values and values["contents"] is None:
            values["contents"] = ""
        if tag == "input" and values.get("name") == "authenticity_token":
            return
        if tag == "meta" and values.get("name") in ("csrf-token", "csrf-param"):
            return
        if "data-copy-to-clipboard-content-value" in values:
            value = values.pop("data-copy-to-clipboard-content-value")
            values["data-copy-to-clipboard-url-value"] = urlsplit(value).path
        self.items.append(("start", tag, tuple(sorted(values.items()))))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        self.items.append(("end", tag))

    def handle_data(self, data):
        value = re.sub(r"\s+", " ", data).strip()
        if value:
            self.items.append(("text", value))


def without_lexxy_mount_shim(items):
    """The OCaml editor readiness shim is an intentional runtime addition."""
    result = []
    index = 0
    while index < len(items):
        if (items[index][:2] == ("start", "script") and
                index + 2 < len(items) and
                items[index + 1][0] == "text" and
                'lexxy:initialize' in items[index + 1][1] and
                'data-wait-for-mount' in items[index + 1][1] and
                items[index + 2][:2] == ("end", "script")):
            index += 3
            continue
        token = items[index]
        if token[:2] == ("start", "lexxy-editor"):
            attrs = dict(token[2])
            if (attrs.get("data-wait-for-mount") == "" and
                    attrs.get("style") == "visibility: hidden"):
                attrs.pop("data-wait-for-mount")
                attrs.pop("style")
                token = ("start", "lexxy-editor", tuple(sorted(attrs.items())))
        result.append(token)
        index += 1
    return result


def main():
    expected_tokens = None
    if sys.argv[1].endswith(".html"):
        expected_html = open(sys.argv[1], encoding="utf-8").read()
    else:
        expected_tokens = json.load(open(sys.argv[1], encoding="utf-8"))["expected"]
    actual_html = open(sys.argv[2], encoding="utf-8").read()
    a, b = Tokens(), Tokens()
    if expected_tokens is None:
        a.feed(expected_html)
    else:
        # Golden text tokens can contain literal markup such as "<script>".
        # Feed those as text, preserving the pinned token boundary.
        for token in expected_tokens:
            if token.startswith("#"):
                a.handle_data(token[1:])
            else:
                a.feed(token)
    b.feed(actual_html)
    b.items = without_lexxy_mount_shim(b.items)
    if len(sys.argv) > 3 and sys.argv[3] == "--legacy-transfer":
        # The pinned Rails fixture omits the closing form tag. Rust's parity
        # test first checks the renderer has a complete form, then removes its
        # closing tag solely for the historical golden comparison.
        start = next(i for i, x in enumerate(b.items)
                     if x[:2] == ("start", "form") and
                     ("data-controller", "auto-submit") in x[2])
        end = next((i for i in range(start + 1, len(b.items))
                    if b.items[i] == ("end", "form")), None)
        if end is None or ("name", "_method") not in b.items[start + 1][2]:
            raise AssertionError("transfer renderer must contain a complete PUT form")
        b.items.pop(end)
    if len(sys.argv) > 3 and sys.argv[3] == "--sidebar-frame":
        def sidebar(items):
            start = next(i for i, token in enumerate(items)
                         if token[0] == "start" and ("id", "user_sidebar") in token[2])
            depth = 0
            for end in range(start, len(items)):
                token = items[end]
                if token[:2] == ("start", "turbo-frame"):
                    depth += 1
                elif token[:2] == ("end", "turbo-frame"):
                    depth -= 1
                    if depth == 0:
                        return items[start:end + 1]
            raise ValueError("unclosed sidebar")

        a.items = sidebar(a.items)
        b.items = sidebar(b.items)
    if len(sys.argv) > 3 and sys.argv[3] == "--room-regions":
        def message_template(items):
            start = next(i for i, token in enumerate(items)
                         if token[0:2] == ("start", "script") and
                         ("type", "text/template") in token[2])
            return items[start + 1][1]

        if message_template(a.items) != message_template(b.items):
            print("Optimistic message template text differs from Rails golden")
            return 1

        def region(items, identifier):
            start = next(i for i, token in enumerate(items)
                         if token[0] == "start" and ("id", identifier) in token[2])
            tag = items[start][1]
            depth = 0
            for end in range(start, len(items)):
                token = items[end]
                if token[:2] == ("start", tag):
                    depth += 1
                elif token[:2] == ("end", tag):
                    depth -= 1
                    if depth == 0:
                        return items[start:end + 1]
            raise ValueError(f"unclosed {identifier}")

        def expand_template(items):
            expanded = []
            for index, token in enumerate(items):
                if (index and token[0] == "text" and
                    items[index - 1][0:2] == ("start", "script") and
                    ("type", "text/template") in items[index - 1][2]):
                    nested = Tokens()
                    nested.feed(token[1])
                    expanded.extend(nested.items)
                else:
                    expanded.append(token)
            return expanded

        a.items = [item for key in ("nav", "message-area", "footer")
                   for item in expand_template(region(a.items, key))]
        b.items = [item for key in ("nav", "message-area", "footer")
                   for item in expand_template(region(b.items, key))]
    if len(sys.argv) > 3 and sys.argv[3] in ("--html-main", "--content-fragment", "--actual-main"):
        def main_content(items):
            start = next(i for i, token in enumerate(items) if token[0] == "start"
                         and token[1] == "main" and ("id", "main-content") in token[2]) + 1
            end = next(i for i in range(start, len(items)) if items[i][0] == "start"
                       and items[i][1] == "footer" and ("id", "footer") in items[i][2])
            return items[start:end]
        if sys.argv[3] != "--actual-main":
            a.items = main_content(a.items)
        if sys.argv[3] in ("--html-main", "--actual-main"):
            b.items = main_content(b.items)
    if len(sys.argv) > 3 and sys.argv[3] == "--body-fragment":
        start = next(i for i, item in enumerate(a.items)
                     if item[:2] == ("start", "body")) + 1
        end = next(i for i in range(start, len(a.items))
                   if a.items[i][:2] == ("end", "body"))
        a.items = a.items[start:end]
    if a.items != b.items:
        index = next((i for i, (x, y) in enumerate(zip(a.items, b.items)) if x != y),
                     min(len(a.items), len(b.items)))
        print(f"DOM mismatch at token {index}; expected {len(a.items)}, got {len(b.items)}")
        print("expected:", a.items[index:index + 2])
        print("actual:  ", b.items[index:index + 2])
        return 1
    print(f"Rails golden: {len(a.items)} structural DOM tokens match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
