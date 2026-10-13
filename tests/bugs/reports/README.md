# Raw audit reports

These are the unedited reports produced during the audit that led to `BUGS.md`:

- `hunters/` — one report per hunting angle (hypotheses, proofs of concept, negative results).
- `verifiers/` — independent re-verification of each claim (verdict, own reproducer, severity re-rating).

`<SCRATCH>` in these files refers to the temporary working directory used during the audit; the reproducers that
matter were ported to `tests/bugs/<slug>/`. Where a hunter's and a verifier's severity differ, the verifier's rating
(and `BUGS.md`) is authoritative.
