"""Assert all 30 pinned PWA partials against the OCaml fragment renderer."""

import subprocess
import sys
from pathlib import Path

from view_dom_compare import Tokens


def main():
    executable = str(Path(sys.argv[1]).resolve())
    fixtures = Path("fixtures/views_pwa")
    cases = sorted(fixtures.glob("*.html"))
    if len(cases) != 30:
        raise AssertionError(f"expected 30 PWA cases, found {len(cases)}")
    for fixture in cases:
        rendered = subprocess.run(
            [executable, "--dump-a", fixture.stem],
            check=True, capture_output=True, text=True,
        ).stdout
        expected_tokens, actual_tokens = Tokens(), Tokens()
        expected_tokens.feed(fixture.read_text())
        actual_tokens.feed(rendered)
        if expected_tokens.items != actual_tokens.items:
            index = next((i for i, (a, b) in enumerate(zip(
                expected_tokens.items, actual_tokens.items)) if a != b),
                min(len(expected_tokens.items), len(actual_tokens.items)))
            raise AssertionError(f"{fixture.stem}: DOM token {index}: "
                f"{expected_tokens.items[index:index + 1]} != "
                f"{actual_tokens.items[index:index + 1]}")
    print(f"Rails golden: {len(cases)} PWA partial DOM cases match")


if __name__ == "__main__":
    main()
