# Project-cache seed reuse: task 425

Reviewed code: `1f8d0528a0e22d44221852b653e255771e021aa0`,
`e1af00c451a7acdf796fe33bd756b13aaff95248`,
`fac94e3616648d5a3aa0d02b7cc6de360b935552`.

Recovered from failed run `run-1789117597368-0b4f4ff8` (memory guard).
The operator authorized inline completion and independent review. Origin task
424 is the separate roadmap-checkout synchronization task; this delivery is 425.

## Independent evaluator

Cursor `cursor-grok-4.6-high`, session
`e60527d8-0b47-4c3a-a0f4-fba48554454b`, approved the code series subject to the
final live acceptance passing. Report: `/tmp/cache-inline-landing-independent-review.md`.
The evaluator independently ran 42 cache tests (all passed), `mix check.dispatch`,
normal Tapakly compilation, and normal full Dialyzer (all exit 0). Its separate
negative control compiled but Dialyzer exited 2 with `invalid_contract` on
`Tapakly.CacheAcceptanceProbe.value/0`.

Independent live logs:
- `/tmp/cache-inline-independent-warm-compile.X14YOk.log`
- `/tmp/cache-inline-independent-warm-dialyzer.VdIVOG.log`
- `/tmp/cache-inline-independent-invalid-compile.zMhKhO.log`
- `/tmp/cache-inline-independent-invalid-dialyzer.U6j1dK.log`

## Real-project observations

The original seed successfully built dependencies and the PLT. The first outer
restore then failed because plain `mix dialyzer --plt` had skipped checking
changed BEAMs. Dialyxir's dependency hash covers lockfile/app identities;
`--plt --force-check` invokes the actual incremental check. Strict PLT relocation
correctly detected the stale digest and remains unchanged.

Published generation manifests under `/tmp/cache-inline-tapakly-live/cache`:

| Generation | Key | Preparation time inside builder |
| --- | --- | ---: |
| Original seed | `45901bc34896538058cc19ecf3e6f380833f4cc19db465879d7c5f93b3ccc6ed` | 930,215 ms |
| Corrected app revision 41 | `cc7ed785a6c55fba999508e2ef04faced5154d4f22d19674342b2d55c63472e3` | 428,306 ms |
| Corrected app revision 42 | `540f76e6da4de55ce85ba9052fc0a6c00f2b23b14b8b7309e845f3adfb99eddb` | 458,525 ms |

Both corrected app generations reused the same seed and checked 8,544 PLT
modules without creating/copying a new Dialyxir PLT. These are segmented results:
a successful seed build, an outer failure, and corrected resumed builds. They
are not an uninterrupted cold acceptance run. Later outer cache hits are not
build-time measurements. The immutable manifests retain the build timings.

A test assertion comparing copy timestamps was also corrected: ordinary cache
copies do not preserve mtimes. The test now compares all dependency BEAM names
and SHA256 bytes against the seed, and checks outer compilation logs for any
dependency rebuild. A separate reader checked 15,176 dependency BEAMs across
the original seed and both restored revisions with no differences.

## Repository checks

Focused tests: 46 passed. Independent cache tests: 42 passed; ProjectCache
coverage 98.88%, Recipe 100%. Final `mix check.dispatch` passed.
The full gate reported 2,228 passed, three failures in untouched Config and
Dashboard tests, and 73 excluded; coverage was 84.85%. A single isolated rerun
of those test files passed all 55 tests. Separate clone detection, reach checks,
and Harness Dialyzer passed. The original full-suite result was not clean.

## Deployment boundary

This lands repository code and task metadata. The running Harness node and
Tapakly production cache recipe are not reloaded or activated by this delivery.

## Evidence integrity

SHA256 of retained evaluator artifacts:

- `692be7a6c9478f5b55a92bc093cd800b25a5b156418a991a5a7bcbe11a49d18c` — `/tmp/cache-inline-landing-independent-review.md`
- `ea79bdf5dd14c78a70a3758134a57cab163e2bcfa5156f1fd2b13afc8c602a29` — `/tmp/cache-inline-independent-test.cxMgFi.json`
- `9e5d93eaf67c1a24f10c78d29912a4fa07ca84c2eba6411a1b6e5b94f985754d` — `/tmp/cache-inline-independent-invalid-dialyzer.U6j1dK.log`

## Final acceptance: passed

The final `--no-retry` live run passed both tests in 865.63 seconds.
It reused the published generations in fresh worktrees, passed normal dev/test
compilation and full Dialyzer for both valid revisions, compared all dependency
BEAM bytes to the seed, and prepared the invalid revision from the same seed.
Normal full Dialyzer then exited 2 with the exact probe `invalid_contract`.
This satisfies the independent evaluator’s remaining landing condition.

- Final cold source SHA: `5ec6181fd8228604115953ecb49b28cbbc5fbc91`; outer state `hit`.
- Final warm source SHA: `2870bf189a2eb09f789ad3015844ee2e148079d3`; outer state `hit`.
- `e396bd64c311435a5574db548f6f40a21097cf58361e442c7d59ef3235e99535` — `/tmp/cache-inline-tapakly-final.json`
- `cc34390e6b1afe35dc651182c52997956c7fcb83e8ad8e3a4d35ace8e7219c80` — `/tmp/cache-inline-tapakly-live/complete.json`
- `dcd84db96bd86af24f2ff61e4e3d2ed5b49b5b89a807d4d31a24ce21388ca62c` — `/tmp/cache-inline-tapakly-live/invalid-dialyzer.log`
