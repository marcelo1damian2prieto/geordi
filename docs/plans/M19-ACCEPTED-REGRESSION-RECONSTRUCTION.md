# M19 accepted regression reconstruction

> **RECONSTRUCTED — NOT HISTORICAL**
>
> Created 2026-11-16 from the currently available D2 branch documentation and test harness. This document is a proposed recovery plan, not a recovered transcript, not proof of the historical accepted set, and not authorization to execute it.

## 1. Purpose and limits

The historical accepted-regression inventory and exact order could not be recovered from the checked-in documents or the available D2 branch history. This reconstruction records the strongest supportable offline sequence for the post-follower readiness work, distinguishes prior evidence from required reruns, and identifies unresolved command discovery.

This sequence is deliberately limited to offline, synthetic, parser, static, and config-only checks. It does not authorize Docker lifecycle operations, runtime validation, TLS/certificate work, capture mutation, cleanup, protected-volume access, CI activation, M13, Gate 5 promotion, candidate promotion, or M19 acceptance.

**Owner approval is required before any test execution.** Stop at the first failure. Do not run the formal overlap 26-gate sequence or the separate M11→M12 19-gate sequence as part of this reconstructed set.

## 2. Evidence sources

The reconstruction is based on:

- `docs/plans/EXECPLAN-M19-POST-FOLLOWER-READINESS.md`: required phase order and post-follower callback acceptance conditions.
- `docs/plans/M19-WORKTREE-RESUME-CHECKPOINT.md`: prior focused PASS results, the failed pre-D2 Boundaries attempt, and the later D2 Boundaries correction.
- `docs/plans/EXECPLAN-M19-M11-BACKEND-GENERATIONS.md`: M11 synthetic generation and propagation-isolation proof.
- `docs/plans/EXECPLAN-M19-M12-BACKEND-GENERATIONS.md`: M12 backend, transfer, Collector compatibility, and focused validation.
- `docs/plans/EXECPLAN-M19-M12-OVERLAP-COLLECTOR-ISOLATION.md`: overlap Collector self-test, manifest regression, parser, config-only checks.
- `docs/plans/EXECPLAN-M19-M11-M12-FIXTURE-TRANSFER.md`: separate transfer capability and its own 18 focused gates / A–S matrix.
- `docs/plans/EXECPLAN-M19-M10-BACKEND-GENERATION.md`: M10 focused replacement/config/propagation/volume checks.
- `scripts/Test-GeordiCaptureGenerations.ps1`: exact `AuthContract` and `Boundaries` cases. Its `ValidateSet` is not treated as the accepted regression inventory.

## 3. Reconstructed execution order

The order below is a **proposed safe order**, not a claim about the historical order. Exact commands are included only where the source records support them.

### Phase 0 — Preconditions (read-only)

1. Confirm current branch is `d2/audit-boundaries-fix`, not `m19`.
2. Confirm worktree state and preserve all existing changes. Do not reset, stash, clean, or rewrite history.
3. Confirm no Docker/runtime operation is planned and that protected M19 volumes will remain untouched.

**Prior evidence:** branch isolation and scope are documented in the D2 audit/checkpoint.  
**Rerun:** required immediately before execution because branch/worktree state is local and may have changed.  
**Command:** not prescribed here; use read-only Git inspection only.

### Phase 1 — Parser and shared post-follower microtests

1. Parse the affected PowerShell scripts and helpers.
2. Run the shared `AfterFollowerValidated` microtests:
   - callback omitted / compatibility;
   - correct event order (identity validation/publication → callback → handoff completion);
   - wrong follower rejected before callback;
   - callback failure leaves incomplete state;
   - cleanup attempted while primary failure remains authoritative;
   - sealed historical evidence remains immutable.

**Prior evidence:** shared post-follower microtests are recorded PASS in the checkpoint and post-follower ExecPlan.  
**Rerun:** required as the beginning of the reconstructed fail-fast sequence.  
**Exact command:** **UNKNOWN** — the available records describe the assertions but do not preserve the test file path or invocation. Identify the authoritative test entry point before approval/execution; do not invent one.

### Phase 2 — Focused caller regressions

Run these as separate tests, preserving their distinct scopes:

| Proposed order | Regression | Prior recorded status | Rerun requirement | Command status |
|---|---|---|---|---|
| 2.1 | M11 backend synthetic generation regression | PASS | Rerun | Exact invocation not recoverable |
| 2.2 | M12 main backend synthetic regression | PASS | Rerun | Exact invocation not recoverable |
| 2.3 | M12 overlap backend positive sequence and 12-case failure matrix at each of two boundaries | PASS | Rerun | Exact invocation not recoverable |
| 2.4 | M12 overlap Collector ordering / second-handoff-history self-test | PASS | Rerun | Exact command not preserved in the post-follower checkpoint; dedicated ExecPlan records `scripts/Test-GeordiM12OverlapCollector.ps1 -SelfTest` for its scoped validation |

**Scope guard:** the M11→M12 fixture-transfer 18-gate / A–S matrix is a separate capability validation. It is not silently included in this caller-regression block. Likewise, M10's seven replacement cases and M11's propagation/volume/evidence tests are separately scoped validations; do not add them to this set without an explicit owner decision.

### Phase 3 — Capture-generation authentication and boundary checks

Run the two exact cases below in this order:

1. `AuthContract`
2. `Boundaries`

Commands (from repository root):

```powershell
pwsh -NoProfile -File scripts/Test-GeordiCaptureGenerations.ps1 -Case AuthContract
if ($LASTEXITCODE -ne 0) { throw "AuthContract failed: $LASTEXITCODE" }

pwsh -NoProfile -File scripts/Test-GeordiCaptureGenerations.ps1 -Case Boundaries
if ($LASTEXITCODE -ne 0) { throw "Boundaries failed: $LASTEXITCODE" }
```

Parser check for this harness (the exact historical parser invocation is not recorded; this is a reproducible equivalent):

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path 'scripts/Test-GeordiCaptureGenerations.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count -gt 0) {
    $errors | Format-List
    throw 'PowerShell parser failed'
}
'capture_generation_parser=PASS'
```

**Prior evidence:**
- `AuthContract`: PASS; six negative controls rejected.
- Parser for `Test-GeordiCaptureGenerations.ps1`: PASS.
- `Boundaries`: an earlier attempt failed before executing lifecycle assertions because source markers were stale. D2 then corrected test-only markers/fixtures. The owner confirmed the corrected run returned `$LASTEXITCODE = 0` and emitted `pre_m14_generation_boundaries=PASS` and `pre_m14_generation_fail_closed=PASS`.

**Rerun:** both cases and parser are required in the reconstructed sequence. The earlier failed Boundaries attempt remains historical; the later D2 PASS is the current focused evidence. A full sequence has not been rerun after that correction.

### Phase 4 — Diff and static scope check

Run `git diff --check` and inspect the diff against `m19` to confirm this remains limited to the D2 harness and documentation. Verify that production scripts, `.gitlab-ci.yml`, Compose files, TLS/certificates, captures, and protected-volume definitions have not been changed by this workstream.

**Prior evidence:** D2 scope and changed-file inventory were recorded as harness plus documentation.  
**Rerun:** required.  
**Exact command:** `git diff --check` is known; the full comparison command should be selected from the current branch state and remain read-only.

### Phase 5 — Independent read-only review

Only after Phases 1–4 pass, obtain a fresh independent review of:
- callback ordering and exact follower binding;
- failure-state truthfulness and cleanup precedence;
- immutable prior generation/handoff history;
- M10 and base M12 Collector compatibility;
- the M12 overlap Collector chain `C0→HC1→C1→HC2→C2`;
- CI nonactivation and scope boundaries.

The review must report findings by severity and explicitly state whether the focused reconstructed set is clean. A previous review of a different gate sequence is not a substitute.

**Prior evidence:** earlier focused reviews exist for separate slices, but no fresh review of the corrected D2 state after the complete reconstructed set is recorded.  
**Rerun:** required after the sequence passes.  
**Command:** review procedure is not a repository test command.

## 4. Known prior evidence ledger

| Item | Recorded evidence | Current interpretation |
|---|---|---|
| Shared post-follower microtests | PASS | Prior focused PASS; rerun |
| M11 backend synthetic regression | PASS | Prior focused PASS; rerun |
| M12 main backend synthetic regression | PASS | Prior focused PASS; rerun |
| M12 overlap backend positive + two 12-case failure matrices | PASS | Prior focused PASS; rerun |
| M12 overlap Collector self-test | PASS | Prior focused PASS; rerun |
| `AuthContract` | PASS; six negative controls rejected | Prior focused PASS; rerun |
| Capture-generation parser | PASS | Prior focused PASS; rerun |
| `Boundaries` before D2 correction | FAILED attempt; assertions did not execute | Historical failure, superseded for current focused result only |
| `Boundaries` after D2 correction | PASS; exit code 0 and both PASS markers | Current focused PASS; rerun in reconstructed full sequence |
| Full accepted regression sequence | Not completed after D2 correction | NOT RUN / must run after approval |
| Fresh independent review after full reconstructed sequence | Not recorded | NOT RUN |

## 5. Explicitly separate validation sets — do not merge

### Formal M12 overlap sequence — 26 gates

This is a separate formal sequence. The post-follower ExecPlan makes it conditional on a fully green accepted regression set and a clean independent read-only review. It is **not** part of this reconstruction and is not authorized by this document.

### M11→M12 fixture-transfer remediation — 19 gates

This is a separate remediation sequence, with its own frozen test scope and independent review history. Its previous PASS does not establish that the accepted post-follower regression set passed. Do not append its 19 gates to this reconstructed set.

### M11→M12 fixture-transfer capability — 18 focused gates / A–S matrix

This is another separately scoped capability proof. It must not be conflated with the 19-gate remediation or the accepted post-follower regression set.

### M10 / M11 / M12 scoped ExecPlans

Their parser, config-only, propagation, volume, evidence, and self-tests belong to their respective plans. Some prior PASS results are useful supporting evidence, but they do not prove membership in the historical accepted regression set.

## 6. Unresolved items before execution approval

1. Identify the exact test file and invocation for the shared post-follower microtests.
2. Identify the exact test files and invocations for M11 backend synthetic regression, M12 main backend synthetic regression, and M12 overlap backend failure matrices.
3. Decide explicitly whether the owner-approved reconstructed set should include the separate M10 seven-case regression and/or the separate M11→M12 fixture-transfer validations. Default recommendation: **do not include them** in this narrow post-follower set; retain them as separate evidence.
4. Confirm current local branch/worktree state and availability of all referenced test scripts.
5. Confirm that only offline/synthetic/parser/config-only checks are in scope.

If any exact test entry point cannot be identified from the repository, record it as unresolved and stop before execution rather than substituting a guessed command.

## 7. Proposed acceptance criteria

The reconstructed offline set is considered green only if:
- every approved item in Phases 1–4 passes in the proposed fail-fast order;
- both `AuthContract` and corrected `Boundaries` pass with explicit exit code 0;
- the diff/scope review confirms no prohibited files or operations;
- the fresh independent read-only review has no unresolved BLOCKER or HIGH findings (MEDIUM/LOW findings are reported for owner disposition);
- no runtime, Docker lifecycle, TLS, capture mutation, cleanup, protected-volume, CI activation, M13, Gate 5, candidate promotion, or M19 acceptance action occurs.

A green reconstructed offline set is **not** M19 acceptance and does not authorize the formal overlap 26-gate run. That next step remains conditional on owner approval after a clean review.

## 8. Current conclusion

The available evidence supports a useful reconstruction of focused checks and their previous statuses, but not recovery of the historical accepted set's exact membership or order. This document preserves that distinction. It is ready for owner review as a **new proposed sequence**, not as recovered historical fact.
