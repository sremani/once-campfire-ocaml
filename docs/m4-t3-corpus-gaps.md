# M4-T3 pinned Action Text corpus audit

The pinned Rails fixture has 658 cases: 258 curated and 400 malformed/fuzz. Its SHA-256 is `00f9a13ce4b0a817df2ec41a4af17aa5a0aa0ac284a7656980517273b3f290d1` in both `test/fixtures/rich_text_expected.json` and `../once-campfire-rust/crates/richtext/tests/corpus/expected.json`. `python3 test/m4_t3_compare.py --direct-rust` checks the hash, builds the pinned Rust converter through `test/m4_t3_rust_oracle`, then compares every OCaml presentation (with message rescue), plain-text value, and editor value to Rust. The oracle uses the pinned corpus resolver and does not edit the Rust repository. If the Cargo cache is empty, run `RUSTC_WRAPPER= cargo fetch --locked` once from the Rust repository before using the offline comparator.

| Oracle | Scope | Presentation | Plain text | Editable |
| --- | --- | ---: | ---: | ---: |
| Raw Rails | All 658 | 615 | 658 | 588 |
| Raw Rails | Curated 258 | 253 | 258 | 248 |
| Raw Rails | Fuzz 400 | 362 | 400 | 340 |
| Rust-normalized Rails | All 658 | 658 | 658 | 658 |
| Direct pinned Rust | All 658 | 658 | 658 | 658 |

The normalized Rails comparison applies only the deliberate differences in `../once-campfire-rust/crates/richtext/tests/corpus.rs:133-168,294-336`: attribute bracket escaping, removal of `name`, autolinks that Rails injected inside attributes, missing-attachable rendering, and editable error handling. The raw Rails curated presentation differences are `lexxy mention html name`, `sgid deleted user`, `xss attribute with gt and url`, `xss name attribute`, and `og href with quotes and spaces`. The attribute cases follow the pinned Rust stored-XSS fix in `crates/richtext/src/autolink.rs:1-11`.

The final ten malformed presentation cases were fuzz 45, 97, 125, 144, 177, 210, 216, 230, 274, and 294. Rails and Rust rescue each to blank HTML. The cause was `node_with_full_attributes` rejecting an attachment whose sanitized attributes have none of the twelve Action Text attachment keys (`crates/richtext/src/content.rs:187-206`); the OCaml renderer now checks the same set. The final two editor cases were fuzz 43 and 331. The Gumbo fragment tree retained a nested HTML form and a nested heading that html5ever reparented; the OCaml editor tree normalization now follows the pinned Rust bytes while leaving foreign-namespace forms intact.

`dune exec ./test/m4_t3_test.exe` passes nine suites, including focused regressions for those twelve cases. `dune exec ./test/m4_integration_test.exe` passes five seeded HTTP suites, including rich message create/show/search, stale-SGID GID fallback into FTS, and request-Host Open Graph behavior. The comparator audited all 658 browser-facing presentation outputs for unsafe elements, attributes, and URI schemes and found zero violations. The pinned Rust `cargo test -p campfire_richtext --test corpus corpus_matches_rails --locked --offline -- --nocapture` passed its 658-case and security gates.
