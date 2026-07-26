# D22 NON-COMPLIANT Acceptance Matrix

**Status (2026-07-23): A new decision has been made, but implementation is
still in progress.** These fixtures are executable statements of the D22
contract from specification §§3.4, 3.8, 9.7, 10, 13.3, 21.1, and 22.3. This
directory is deliberately outside every active test lane. A green build must
not claim these verdicts until the implementation work lands.

Do not weaken or rewrite a fixture to match the current compiler. During the
future implementation cycle, first run each fixture manually and record the
current mismatch. Move it into the appropriate active behavior or
compile-errors lane only when its stated verdict is genuinely true.

## Transparent-origin core matrix

| Fixture | Future verdict | Contract |
|---|---|---|
| `origin_unwrap_after_clear.w` | check-fail at `clear` | `unwrap` preserves the map-view origin |
| `origin_pattern_after_clear.w` | check-fail at `clear` | pattern projection preserves the origin and exact `&V` type |
| `origin_try_after_clear.w` | check-fail at `clear` | `?` preserves the origin |
| `origin_default_union.w` | check-fail at mutation | two borrowed `??` paths union their origins |
| `copy_snapshot_survives_clear.w` | compile and run | an annotated Copy snapshot is independent |
| `owned_remove_and_nll_controls.w` | compile and run | removal transfers ownership; mutation after a view's final use remains legal |

## Amendment pins

| Fixture | Future verdict | Contract |
|---|---|---|
| `mixed_five_arm_join.w` | compile and run | one owned arm anchors a five-arm join, arm order is irrelevant, and an annotation pins intent |
| `noncopy_default_diagnostic.w` | check-fail with §22.3 diagnostic | `Option[&Vec[T]] ?? Vec[T]` explains the ownership mismatch and only offers applicable remedies |

## Doctrine-land baseline

Manual `with check` on 2026-07-23 confirmed that all files parse, then exposed
the expected implementation split. `origin_unwrap_after_clear.w` incorrectly
passed, demonstrating the origin-loss hole. The pattern, `?`, and `??` origin
fixtures failed before their intended verdict because that compiler did not
present map lookup as the uniform Option carrier in those paths. The Copy,
remove/NLL, and mixed-join controls passed, but those passes are not compliance
proof while lookup typing and origin propagation remain incomplete. This
snapshot explains why the directory is excluded; future work must replace each
premature or wrong-layer verdict with the one stated in the tables above.
