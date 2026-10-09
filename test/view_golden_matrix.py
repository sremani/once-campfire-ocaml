"""Run every pinned view golden through an OCaml renderer or name its missing seam.

Unsupported entries remain visible in the JSON result and cause a nonzero exit
when --require-all is passed. The two input JSON files get semantic linkage checks.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
PINNED = REPO.parent / "once-campfire-rust/crates/views/tests/golden"
INVENTORY = REPO / "test/fixtures/view_golden_inventory.json"
RENDERER = REPO / "_build/default/test/m4_t2_test.exe"
COMPARE = REPO / "test/view_dom_compare.py"

ONBOARDING = {
    "first_run", "push_subscriptions", "sessions_new", "sessions_new_email",
    "sessions_new_rejected", "sessions_new_with_logo", "sessions_transfer",
    "incompatible_browser", "incompatible_browser_apple_messages",
    "custom_styles_edit", "custom_styles_layout",
    "ban_button_banned",
}
ROOM_FORMS = {
    "rooms_opens_new", "rooms_opens_edit", "rooms_opens_edit_member",
    "rooms_closeds_new", "rooms_closeds_edit", "rooms_closeds_edit_member",
}


def command_for(name):
    stem = Path(name).stem
    if name.startswith("a/") and stem.startswith((
            "browser_settings_", "system_settings_", "install_instructions_")):
        return [str(RENDERER), "--dump-a", stem], "--html-full"
    if stem in ONBOARDING and name.startswith("a/"):
        return [str(RENDERER), "--dump-a", stem], (
            "--legacy-transfer" if stem == "sessions_transfer" else "--html-full")
    if name == "a/users_new.html":
        return [str(RENDERER), "--dump-join"], "--html-full"
    if name.startswith("a/") and stem in ("bots_new", "bots_edit", "bots_edit_with_avatar"):
        return [str(RENDERER), "--dump-bot-form", stem], "--html-full"
    if name == "a/bots_index.html":
        return [str(RENDERER), "--dump-bots-index"], "--html-full"
    if name.startswith("a/account_edit_") and name.endswith(".html"):
        return [str(RENDERER), "--dump-account", stem], "--html-full"
    if name == "a/account_users_page_2.turbo_stream.html":
        return [str(RENDERER), "--dump-account", "account_users_page_2"], "--html-full"
    if name.startswith("a/users_show_") and name.endswith(".html"):
        return [str(RENDERER), "--dump-user-show", stem], "--html-full"
    if name.startswith("a/profile_") and name.endswith(".html"):
        return [str(RENDERER), "--dump-profile", stem], "--html-full"
    if name.startswith("a/") and stem in (
            "mention", "action_text_content", "mailer_layout",
            "og_embed", "og_embed_twitter", "og_embed_long_no_href",
            "service_worker", "manifest"):
        return [str(RENDERER), "--dump-aux", stem], (
            "exact-manifest" if stem == "manifest" else
            "exact" if stem in ("mailer_layout", "service_worker")
            else "--html-full")
    if name.startswith("b/") and stem in ROOM_FORMS:
        return [str(RENDERER), "--dump-room-form", stem], "structural-json"
    return {
        "a/avatar_david.svg": ([str(RENDERER), "--dump-svg", stem], "exact"),
        "a/avatar_three_initials.svg": ([str(RENDERER), "--dump-svg", stem], "exact"),
        "a/user_json.json": ([str(RENDERER), "--dump-user-json"], "exact"),
        "a/welcome.html": ([str(RENDERER), "--dump-welcome"], "--html-main"),
        "a/sidebar_frame.html": ([str(RENDERER), "--dump-sidebar"], "--sidebar-frame"),
        "a/sidebar_david.html": ([str(RENDERER), "--dump-sidebar-full", stem], "--html-full"),
        "a/sidebar_kevin.html": ([str(RENDERER), "--dump-sidebar-full", stem], "--html-full"),
        "a/shared_room.html": ([str(RENDERER), "--dump-shared-room", stem], "--html-full"),
        "a/shared_room_unread.html": ([str(RENDERER), "--dump-shared-room", stem], "--html-full"),
        "a/autocompletable_users.html": ([str(RENDERER), "--dump-autocomplete"], "--html-full"),
        "a/autocompletable_users_json.json": ([str(RENDERER), "--dump-autocomplete-json"], "exact"),
        "a/autocompletables_template.html": ([str(RENDERER), "--dump-autocomplete-template"], "--html-full"),
        "b/messages_by_bots_show.json": ([str(RENDERER), "--dump-message-json"], "exact-wrapped-json"),
        "b/messages_by_bots_index.json": ([str(RENDERER), "--dump-messages-json"], "exact-wrapped-json"),
        "b/messages_boosts_by_bots_show.json": ([str(RENDERER), "--dump-boost-json"], "exact-wrapped-json"),
        "b/messages_show_text.json": ([str(RENDERER), "--dump-b-messages", stem], "--content-fragment"),
        "b/messages_show_image.json": ([str(RENDERER), "--dump-b-messages", stem], "--content-fragment"),
        "b/messages_index.json": ([str(RENDERER), "--dump-b-messages", stem], "structural-json"),
        "b/messages_edit_text.json": ([str(RENDERER), "--dump-b-messages", stem], "--html-main"),
        "b/messages_edit_attachment.json": ([str(RENDERER), "--dump-b-messages", stem], "--html-main"),
        "b/messages_boosts_index.json": ([str(RENDERER), "--dump-b-messages", stem], "--body-fragment"),
        "b/messages_boosts_new.json": ([str(RENDERER), "--dump-b-messages", stem], "--content-fragment"),
        "b/messages_room_not_found.json": ([str(RENDERER), "--dump-b-messages", stem], "--content-fragment"),
        "b/messages_create.json": ([str(RENDERER), "--dump-message"], "structural-json"),
        "b/messages_destroy.json": ([str(RENDERER), "--dump-destroy"], "exact-wrapped-stream"),
        "b/rooms_show_member.json": ([str(RENDERER), "--dump-room"], "structural-json"),
        "b/rooms_show_original.json": ([str(RENDERER), "--dump-room-case", stem], "structural-json"),
        "b/rooms_show_direct.json": ([str(RENDERER), "--dump-room-case", stem], "structural-json"),
        "b/rooms_show_closed.json": ([str(RENDERER), "--dump-room-case", stem], "structural-json"),
        "b/rooms_show_at_message.json": ([str(RENDERER), "--dump-room-case", stem], "structural-json"),
        "b/searches_index.json": ([str(RENDERER), "--dump-search-case", stem], "structural-json"),
        "b/searches_index_empty.json": ([str(RENDERER), "--dump-search-case", stem], "structural-json"),
        "b/rooms_directs_new.json": ([str(RENDERER), "--dump-direct-new"], "structural-json"),
        "b/rooms_directs_edit.json": ([str(RENDERER), "--dump-direct-edit"], "structural-json"),
        "b/rooms_involvements_show.json": ([str(RENDERER), "--dump-involvement", stem], "--content-fragment"),
        "b/rooms_involvements_show_direct.json": ([str(RENDERER), "--dump-involvement", stem], "--content-fragment"),
        "b/rooms_refreshes_show.json": ([str(RENDERER), "--dump-refresh"], "structural-json"),
    }.get(name, (None, None))


def missing_seam(name):
    stem = Path(name).stem
    if name == "a/facts.json":
        return "pinned input metadata; no view renderer"
    if stem.startswith(("browser_settings", "system_settings", "install_instructions")):
        return "platform-specific PWA partial renderer and case context"
    if stem.startswith(("profile", "users_show", "sidebar", "shared_room")):
        return "full user/sidebar presenter fixture and renderer"
    if stem.startswith(("account", "bots", "custom_styles")):
        return "full account/bot presenter fixture and renderer"
    if stem.startswith(("messages", "rooms", "searches")):
        return "golden/b request-state presenter and full renderer"
    if stem.startswith(("action_text", "mention", "og_embed")):
        return "fragment-specific presenter and renderer"
    return "golden case input and renderer not yet connected"


def compare(name, actual, mode):
    expected_path = PINNED / name
    expected = expected_path.read_text()
    if mode == "exact":
        return actual == expected, "byte-exact" if actual == expected else "bytes differ"
    if mode == "exact-manifest":
        # Rust's manifest parity explicitly decodes Rails' HTML entity in a
        # query string before comparing JSON output.
        expected = expected.replace("&amp;", "&")
        return actual == expected, "byte-exact after Rails entity decoding" if actual == expected else "manifest bytes differ"
    if mode == "exact-wrapped-json":
        expected = json.loads(expected)["raw"]
        return actual == expected, "byte-exact" if actual == expected else "JSON bytes differ"
    if mode == "exact-wrapped-stream":
        tokens = json.loads(expected)["expected"]
        expected = "".join(token for token in tokens if token.startswith("<"))
        return actual == expected, "byte-exact" if actual == expected else "stream bytes differ"
    with tempfile.TemporaryDirectory(prefix="campfire-golden-") as temp:
        rendered = Path(temp) / "actual.html"
        rendered.write_text(actual)
        argv = [sys.executable, str(COMPARE), str(expected_path), str(rendered)]
        if mode != "structural-json":
            argv.append(mode)
        result = subprocess.run(argv, text=True, capture_output=True, cwd=REPO)
        detail = (result.stdout + result.stderr).strip()
        return result.returncode == 0, detail


def comparison_level(mode):
    return "exact_bytes" if mode.startswith("exact") else "structural_dom"


def validate_input_metadata(results):
    """Link the two source-data files to render assertions, without calling them views."""
    passed = {row["case"] for row in results if row["status"] == "pass"}
    facts = json.loads((PINNED / "a/facts.json").read_text())
    account_cases = json.loads((REPO / "test/fixtures/views_a_account_pages.json").read_text())
    common = json.loads((REPO / "test/fixtures/views_a_onboarding.json").read_text())
    case = facts["cases"]["account_edit_admin"]
    fixture = account_cases["account_edit_admin"]
    if not {"a/account_edit_admin.html", "a/manifest.json"} <= passed:
        raise AssertionError("linked account and manifest render assertions did not pass")
    for key in ("id", "name", "join_code", "logo_path"):
        if case["account"][key] != fixture["account"][key]:
            raise AssertionError(f"facts account.{key} differs from rendered fixture")
    if facts["assets"] != common["assets"]:
        raise AssertionError("facts assets differ from rendered page asset map")
    manifest = facts["cases"]["manifest"]["account"]
    if any(manifest[key] != account_cases["manifest"][key]
           for key in ("name", "logo_path", "logo_path_small")):
        raise AssertionError("facts manifest differs from rendered fixture")
    embedded = json.loads((PINNED / "a/og_embeds.json").read_text())
    selected = json.loads((REPO / "test/fixtures/views_a_og_embeds.json").read_text())
    if embedded != selected:
        raise AssertionError("OG input fixture differs from pinned vectors")
    if {f"a/{name}.html" for name in embedded} - passed:
        raise AssertionError("OG input vector lacks a passing rendered assertion")
    return {
        "a/facts.json": "Account, manifest, and asset inputs match fixtures whose pages pass",
        "a/og_embeds.json": "All three pinned OG inputs feed passing fragment assertions",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--require-all", action="store_true")
    args = parser.parse_args()
    inventory = json.loads(INVENTORY.read_text())
    pinned = {str(path.relative_to(PINNED)) for path in PINNED.glob("*/*") if path.is_file()}
    listed = {item["case"] for item in inventory["cases"]}
    if pinned != listed:
        print(f"inventory mismatch: pinned-only={sorted(pinned-listed)}, inventory-only={sorted(listed-pinned)}", file=sys.stderr)
        return 2
    results = []
    for item in inventory["cases"]:
        name = item["case"]
        if name in ("a/facts.json", "a/og_embeds.json"):
            results.append({"case": name, "status": "input_metadata",
                            "detail": "pending semantic linkage"})
            continue
        argv, mode = command_for(name)
        if argv is None:
            results.append({"case": name, "status": "unsupported", "reason": missing_seam(name)})
            continue
        render = subprocess.run(argv, text=True, capture_output=True, cwd=REPO)
        if render.returncode:
            results.append({"case": name, "status": "fail", "level": comparison_level(mode),
                            "comparator": mode,
                            "reason": (render.stderr or render.stdout).strip()})
            continue
        passed, detail = compare(name, render.stdout, mode)
        results.append({"case": name, "status": "pass" if passed else "fail",
                        "level": comparison_level(mode), "comparator": mode,
                        "detail": detail})
    try:
        metadata = validate_input_metadata(results)
        for row in results:
            if row["status"] == "input_metadata":
                row["detail"] = metadata[row["case"]]
    except (AssertionError, KeyError, ValueError) as error:
        for row in results:
            if row["status"] == "input_metadata":
                row["status"] = "fail"
                row["detail"] = str(error)
    counts = {status: sum(item["status"] == status for item in results)
              for status in ("pass", "fail", "unsupported", "input_metadata")}
    report = {"pinned_root": str(PINNED), "total": len(results),
              "counts": counts, "cases": results}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"total": len(results), "counts": counts}))
    for item in results:
        if item["status"] == "fail":
            print(f"FAIL {item['case']}: {item['reason'] if 'reason' in item else item['detail']}")
    return int(counts["fail"] > 0 or (args.require_all and counts["unsupported"] > 0))


if __name__ == "__main__":
    raise SystemExit(main())
