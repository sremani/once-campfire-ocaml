"""Byte assertion for the pinned Rails rejected sign-in fixture.

The Rust Askama port omits Rails CSRF fields and four whitespace-only content
block lines. Every remaining byte, including attribute order and entity
spelling, is compared literally with the OCaml serializer.
"""

import re
import subprocess
import sys
from pathlib import Path


def replace_once(source, old, new):
    count = source.count(old)
    if count != 1:
        raise AssertionError(f"expected one template marker, found {count}: {old[:30]!r}")
    return source.replace(old, new, 1)


def expected_rust_style(rails):
    rails, count = re.subn(r'<meta name="csrf-(?:param|token)"[^>]*>', '', rails)
    if count != 2:
        raise AssertionError(f"expected two CSRF meta tags, found {count}")
    rails, count = re.subn(r'<input type="hidden" name="authenticity_token"[^>]*>', '', rails)
    if count != 1:
        raise AssertionError(f"expected one CSRF form field, found {count}")
    rails = replace_once(rails,
        '    \n\n    \n    \n    <meta name="action-cable-url"',
        '    \n    <meta name="action-cable-url"')
    rails = replace_once(rails,
        '    <meta name="turbo-visit-control" content="reload">\n  </head>',
        '<meta name="turbo-visit-control" content="reload">  </head>')
    for before, after in (
        ('    <nav id="nav">\n      \n    </nav>',
         '    <nav id="nav">\n    </nav>'),
        ('    <main id="main-content">\n      \n',
         '    <main id="main-content">\n'),
        ('      <footer id="footer">\n        \n      </footer>',
         '      <footer id="footer">\n      </footer>'),
        ('    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">\n      \n    </aside>',
         '    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">\n    </aside>'),
        ('</section>\n\n\n      <footer', '</section>\n\n      <footer'),
    ):
        rails = replace_once(rails, before, after)
    return rails


def main():
    executable = str(Path(sys.argv[1]).resolve())
    rails = (Path(__file__).parent / 'fixtures/views_sessions_new_rejected.html').read_bytes().decode()
    actual = subprocess.run([executable, '--dump-a', 'sessions_new_rejected'],
                            check=True, capture_output=True).stdout
    expected = expected_rust_style(rails).encode()
    if actual != expected:
        first = next((i for i, pair in enumerate(zip(actual, expected))
                      if pair[0] != pair[1]), min(len(actual), len(expected)))
        raise AssertionError(f"session bytes differ at offset {first}; "
                             f"expected {len(expected)}, got {len(actual)}")
    print(f"Rails sign-in fixture: {len(actual)} Rust-style bytes match")


if __name__ == '__main__':
    main()
