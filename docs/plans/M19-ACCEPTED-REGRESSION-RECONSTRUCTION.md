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


---

## 9. Addendum — exact test entry points recovered — 2026-11-16

This addendum supersedes the `UNKNOWN` command-discovery notes in Sections 3 and 6 where the exact entry point is now established. It does **not** claim that these tests formed the historical accepted sequence or that they have been executed in this reconstruction.

### 9.1 Shared post-follower microtests

Authoritative file: `scripts/Test-GeordiPostFollowerReadiness.ps1`.

The script exposes five explicit cases. Run each case separately so a failure is attributable:

```powershell
$cases = @('CallbackAbsent','Ordering','WrongFollower','ReadinessFailure','CleanupFailure')
foreach ($case in $cases) {
    pwsh -NoProfile -File scripts/Test-GeordiPostFollowerReadiness.ps1 -Case $case
    if ($LASTEXITCODE -ne 0) { throw "PostFollowerReadiness/$case failed: $LASTEXITCODE" }
}
```

What it actually proves:
- callback omission preserves legacy behavior;
- replacement → identity resolution → follower start → persisted binding validation → callback → handoff completion order;
- wrong follower does not reach readiness, cleanup is attempted, and the handoff remains incomplete;
- readiness failure remains primary, cleanup is attempted, and old sealed evidence remains immutable;
- cleanup failure does not mask the readiness failure and only its exception type is retained as secondary metadata.

This is the direct shared-seam test. It is not an end-to-end M19 test.

### 9.2 Caller-level focused regressions

The exact test entry points and supported aggregate invocations are:

| Order | File | Invocation | What the aggregate actually covers |
|---|---|---|---|
| 2.1 | `scripts/Test-GeordiM11BackendGenerations.ps1` | `pwsh -NoProfile -File scripts/Test-GeordiM11BackendGenerations.ps1 -SelfTest` | Three synthetic M11 backend boundaries, failure matrix, dedicated-volume removal safety, and production wiring |
| 2.2 | `scripts/Test-GeordiM12BackendGenerations.ps1` | `pwsh -NoProfile -File scripts/Test-GeordiM12BackendGenerations.ps1 -Case SelfTest` | M12 reset evidence publication/reuse/integrity/races, backend positive chain and failure cases, volume/command scope, metric phases, recovery ordering, and transferred-path wiring |
| 2.3 | `scripts/Test-GeordiM12OverlapBackendVmGenerations.ps1` | `pwsh -NoProfile -File scripts/Test-GeordiM12OverlapBackendVmGenerations.ps1 -Case SelfTest` | Command scope, entry state, volume ownership, persisted VM evidence, backend positive handoff and 12 fault cases at each of two boundaries, full overlap sequence, and cross-service failure |
| 2.4 | `scripts/Test-GeordiM12OverlapCollector.ps1` | `pwsh -NoProfile -File scripts/Test-GeordiM12OverlapCollector.ps1 -SelfTest` | CI nonactivation/source map, Compose propagation isolation, command scope, sequential Collector handoffs, wrapper failures, wrong-follower checks at both boundaries, and second-handoff failure matrix |

For every invocation, the caller must check `$LASTEXITCODE` immediately and stop on nonzero. These are synthetic/config-only test harnesses according to their plans; their code should still be inspected before execution to verify that the current version remains free of runtime lifecycle actions.

**Important scope observation:** the M11 and especially M12 `SelfTest` aggregations prove more than the post-follower callback alone. They include adjacent evidence, volume, recovery, and transfer-wiring invariants. That breadth is not automatically scope drift: those checks protect the caller workflows that now depend on the shared seam. But they must be reported as caller-compatibility regression coverage, not mislabeled as pure callback unit tests.

### 9.3 Boundary/authentication checks — exact commands retained

The exact invocations in Phase 3 remain:

```powershell
pwsh -NoProfile -File scripts/Test-GeordiCaptureGenerations.ps1 -Case AuthContract
if ($LASTEXITCODE -ne 0) { throw "AuthContract failed: $LASTEXITCODE" }

pwsh -NoProfile -File scripts/Test-GeordiCaptureGenerations.ps1 -Case Boundaries
if ($LASTEXITCODE -ne 0) { throw "Boundaries failed: $LASTEXITCODE" }
```

### 9.4 Narrowed classification — what belongs in the integrated offline proof

For the specific question "does the shared post-follower readiness change work, and did its authorized callers preserve their contracts?", the proposed integrated proof is:

1. **Direct seam:** five `Test-GeordiPostFollowerReadiness.ps1` cases.
2. **Caller compatibility:** M11 backend, M12 backend, M12 overlap backend, and M12 overlap Collector aggregate self-tests listed above.
3. **Capture-generation contract:** parser, `AuthContract`, and `Boundaries`.
4. **Static scope and independent review.**

Keep these outside that integrated proof unless a separate acceptance criterion explicitly requires them:
- M10's seven-case replacement suite: M10 was expressly not migrated to this callback seam; its suite remains a separate compatibility guard if a reviewer identifies a concrete shared-helper regression risk.
- M11→M12 fixture-transfer 18-gate / A–S validation: a separate capability proof.
- M11→M12 remediation 19-gate sequence: a separate formal remediation proof.
- Formal M12 overlap 26-gate sequence: conditional later validation, not a prerequisite to understanding the focused callback behavior.

### 9.5 Recommendation on the concern that these tests caused scope drift

Do **not** run every discovered test merely to infer what Codex intended. The test code makes the intent legible without execution:
- the five-case post-follower script defines the shared contract;
- the four caller self-tests verify that each authorized integration still respects its own lifecycle and failure invariants;
- AuthContract and Boundaries validate separate capture-generation/authentication boundaries.

The aggregate caller tests are broader than the seam, but they are bounded, named, and mapped to the four authorized callers in the ExecPlan. Their inclusion is defensible as regression coverage. Tests for M10, fixture-transfer gate sets, the 19-gate remediation, and 26-gate overlap sequence should remain separate.

**Execution status:** no tests were run while recovering these entry points. Owner approval for the reconstructed execution sequence is still required.


---

## 10. Addendum — test architecture, execution boundaries, and revised sequence — 2026-11-16

This addendum supersedes the description of the integrated set as wholly offline/config-only in Addenda 9.2 and 9.4. It does not change historical PASS records, establish historical accepted-set membership, or authorize execution.

### 10.1 Reconstructed intent of the implementation

The shared change moves readiness from the StartFollower callback to the shared AfterFollowerValidated seam. The intended invariant is:

1. replacement completes and the new container identity is resolved;
2. the follower starts;
3. the returned process identity and persisted process record are checked against the exact container/service/project;
4. the validated follower binding is published in the generation manifest;
5. readiness runs;
6. only then is the handoff completed.

A readiness failure leaves the new generation/handoff incomplete, attempts follower cleanup, preserves the primary failure, and does not rewrite sealed historical evidence. Omitting the optional callback preserves legacy behavior.

The tests therefore form a layered regression strategy, not one homogeneous test suite.

### 10.2 Test layers and incremental evidence

| Layer | Authoritative entry point | Purpose | Incremental evidence |
|---|---|---|---|
| A — shared contract | Test-GeordiPostFollowerReadiness.ps1, five cases | Prove callback ordering, exact binding, failure semantics, cleanup precedence, callback-absent compatibility | Establishes the shared seam itself |
| B1 — M11 consumer | Test-GeordiM11BackendGenerations.ps1 -SelfTest | Three synthetic M11 boundaries, failure matrix, dedicated fixture-volume removal safety, production wiring | Proves M11 wrapper integration and M11-specific invariants |
| B2 — M12 backend consumer | Test-GeordiM12BackendGenerations.ps1 -Case SelfTest | Backend handoffs plus reset-evidence publication/reuse/integrity/races, metric phases, recovery, volume/command scope, transferred-path wiring | Proves M12 integration and its adjacent evidence contracts; broader than callback coverage |
| B3 — M12 overlap backend consumer | Test-GeordiM12OverlapBackendVmGenerations.ps1 -Case SelfTest | Entry state, VM evidence, volume ownership, backend handoffs, 12 fault cases at each of two boundaries, full sequence and cross-service failure | Proves overlap backend workflow integration |
| B4 — M12 overlap Collector consumer | Test-GeordiM12OverlapCollector.ps1 -SelfTest | Source map, CI nonactivation, Compose restart-propagation isolation, command scope, sequential handoffs, failure and wrong-follower matrices | Proves Collector workflow integration, but has a real Docker CLI config-render dependency |
| C — capture-generation contract | Test-GeordiCaptureGenerations.ps1 -Case AuthContract and -Case Boundaries, plus parser | Authentication contract and synthetic M9–M14 generation-boundary model | Proves adjacent capture-generation/authentication boundaries, not the callback alone |
| D — static scope/review | Read-only diff, source review, independent review | Ensure no prohibited implementation, CI, Compose, TLS, runtime or protected-volume changes | Establishes change scope and review quality |

Do not describe layers B1–B4 as pure callback unit tests. They are caller/workflow regression suites. Their broader checks are defensible only as protection of the four authorized consumers and must be reported separately from Layer A.

### 10.3 Execution-side-effect classification

The static review found the following:

- Layer A creates synthetic capture roots and uses injected follower/process/cleanup callbacks. Its cleanup removes only its generated temporary root.
- Layer B1 uses synthetic identities and injected process/volume inspection/removal adapters. Its volume-removal assertions exercise the allowlist and fail-closed logic without invoking a real Docker volume removal.
- Layer B2 writes synthetic manifests, snapshots and ledgers under unique temporary roots. Its replacement, readiness, process and volume behavior is injected; command-scope tests inspect argument arrays rather than invoking Compose lifecycle commands.
- Layer B3 uses synthetic identities, metric exporters and injected volume adapters. Its command-scope tests inspect generated argument arrays. The reviewed self-test does not execute Docker lifecycle operations.
- Layer B4 is not wholly offline. Get-GeordiM12OverlapComposeConfiguration invokes the real Docker CLI as: docker compose ... config --format json. This renders effective configuration; it does not start, stop, recreate, remove containers, delete volumes, or activate CI. The remainder of the lifecycle harness injects synthetic replacement, identity, follower, readiness and cleanup callbacks.
- Layer C uses parser/AST/source checks and synthetic generation fixtures; no runtime lifecycle operation was identified in the reviewed cases.
- Temporary Remove-Item calls in these test harnesses target generated temporary roots or files within those roots. No reviewed test path targets protected M19 volumes or real capture roots.

**Important boundary:** Docker Compose config is a real external CLI invocation even though it is not a runtime lifecycle operation. Layer B4 therefore requires Docker CLI/Compose availability and should not be labelled fully offline. No test execution is authorized by this finding.

### 10.4 Revised proposed execution sequence

This is a new proposed order, not a recovered historical order.

**Gate 0 — read-only preconditions**
- Confirm branch and worktree state; preserve all existing changes.
- Confirm the exact scripts and libraries match the reviewed D2 revision.
- Inspect the diff and prohibit production, CI, Compose, TLS, runtime, capture and protected-volume changes.
- No tests yet.

**Gate 1 — parser and direct shared contract**
- Parse the affected test and library scripts.
- Run the five Layer A cases individually, fail-fast.
- This is the narrowest and most diagnostic proof of the change.

**Gate 2 — strictly synthetic caller regressions**
- Run B1 M11.
- Run B2 M12 backend.
- Run B3 M12 overlap backend.
- Report each as caller/workflow regression, not as callback unit testing.
- Stop on the first nonzero exit code.

**Gate 3 — capture-generation/authentication boundaries**
- Run AuthContract, then Boundaries, with immediate exit-code checks.
- Preserve the known prior PASS evidence as historical; any rerun must be reported separately.

**Gate 4 — Docker-CLI config-dependent Collector regression**
- B4 SelfTest is a separate approval item because it invokes Docker Compose config rendering.
- It does not perform Docker lifecycle operations, but it is not a strictly offline test.
- The current script has no selector that runs only Compose isolation/rendering independently of the whole SelfTest. Its focused Case selectors cover subsets of the failure harness, and some invoke the same render callback. Do not claim a focused case is Docker-free without tracing that exact path.
- Before approval, decide whether to run the aggregate SelfTest with Docker CLI config rendering permitted, or defer B4 and record the resulting coverage gap. Do not edit the test harness merely to split it without a separately approved design change.

**Gate 5 — static scope and independent review**
- Run read-only diff/scope checks.
- Obtain a fresh independent review of the corrected D2 state.
- Only after the preceding approved gates pass and the review is clean may the owner consider the separate formal overlap 26-gate sequence.

### 10.5 Explicit exclusions

Do not add these to the post-follower regression sequence:

- M10 seven-case replacement suite: M10 was not migrated to the callback seam. Keep it as a separate compatibility guard if a concrete shared-helper risk is identified.
- M11→M12 fixture-transfer 18 focused gates / A–S matrix: separate capability validation.
- M11→M12 remediation 19-gate sequence: separate formal remediation.
- Formal M12 overlap 26-gate sequence: later conditional validation, not part of the focused callback proof.
- Runtime/Docker lifecycle, TLS/certificates, real capture mutation, cleanup, protected-volume operations, CI activation, M13, Gate 5 promotion, candidate promotion and M19 acceptance: excluded and unauthorized.

### 10.6 Prior evidence versus new execution

The checkpointed PASS results for Layers A, B1–B4 and C remain prior focused evidence. This static review did not rerun them. The complete reconstructed sequence has not been executed end-to-end after the D2 correction. No result in this addendum changes that status.

### 10.7 Recommendation

Retain the test logic and reorganize its interpretation and execution. Do not run every suite to discover intent: the code and this layered map already establish the intended purpose. The only unresolved execution-design decision is whether the owner wants to permit the real Docker CLI config-render dependency in B4 or defer that one caller regression. Owner approval remains required before any test is run.

---

## 11. Finalized reconstruction — proposed accepted regression set — 2026-11-16

> **RECONSTRUCTED — NOT HISTORICAL.**
>
> This addendum completes the proposed inventory, exact entry points, execution order, status ledger, and exclusions using the currently available repository plans, test files, D2 audit, and owner-supplied B+C execution output. It does not recover or claim the original accepted set or its original order. It is submitted for owner review; it is not execution authorization.

### 11.1 Decision on scope

For this reconstruction, the accepted regression set means the focused proof of the shared `AfterFollowerValidated` change and the four owner-authorized callers, plus the adjacent capture-generation/authentication contracts and read-only scope review.

The reconstructed set has these layers:

- **A — direct shared seam:** five explicit microtest cases.
- **B1–B4 — caller/workflow compatibility:** one aggregate SelfTest for each authorized consumer.
- **C — capture-generation/authentication boundary:** parser, `AuthContract`, and `Boundaries`.
- **D — scope/review:** read-only diff checks and a fresh independent read-only review.

The D2-09 refactor split B4 into two complementary validations. B4a (`-SelfTest`) uses an injected Compose executor and synthetic configuration fixtures; B4b (`-ComposeIntegration`) renders the actual Compose configuration with the Docker CLI and runs the same isolation assertions. Both are retained because together they preserve the old B4 coverage without making the synthetic suite depend on Docker. B4b is a real external CLI invocation but config-render-only; it is not Docker lifecycle.

This is the narrowest complete reconstruction supported by the post-follower ExecPlan and its four authorized callers. It does not sweep every M10/M11/M12 test or every formal gate into one oversized suite.

### 11.2 Final proposed order and exact commands

All commands are from the repository root, in PowerShell 7. Each script invocation must be followed immediately by an exit-code check. Stop on the first parser error, nonzero exit, unexpected side effect, or scope mismatch. Do not continue to later phases after a failure.

#### P0 — Read-only preconditions

Confirm:
- current branch is `d2/audit-boundaries-fix`, not `m19`;
- the worktree state is understood and preserved;
- all listed paths exist at the reviewed branch revision;
- no runtime, Docker lifecycle, TLS/certificate, capture mutation, cleanup, protected-volume, CI activation, M13, Gate 5 promotion, candidate promotion, or M19 acceptance action is planned.

Use read-only Git inspection only. Do not reset, stash, clean, checkout, commit, or push as part of this phase.

**Status:** branch isolation and the seven-path D2 scope were previously recorded. Reconfirm locally immediately before any future run.

#### P1 — PowerShell parser

Parse the exact scripts and libraries that define the reconstructed tests and changed D2 harness:

```powershell
$files = @(
    "scripts/lib/GeordiCaptureGenerations.ps1",
    "scripts/lib/GeordiM12OverlapCollector.ps1",
    "scripts/Test-GeordiPostFollowerReadiness.ps1",
    "scripts/Test-GeordiM11BackendGenerations.ps1",
    "scripts/Test-GeordiM12BackendGenerations.ps1",
    "scripts/Test-GeordiM12OverlapBackendVmGenerations.ps1",
    "scripts/Test-GeordiM12OverlapCollector.ps1",
    "scripts/Test-GeordiCaptureGenerations.ps1"
)

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $file),
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    if ($errors.Count -gt 0) {
        $errors | Format-List
        throw "Parser FAILED: $file"
    }

    Write-Host "Parser PASS: $file"
}
```

This parser inventory is a reproducible reconstruction of the directly involved test/helper surface. It is not claimed as the historical parser command list.

#### P2 — A: direct shared-seam microtests

Authoritative entry point: `scripts/Test-GeordiPostFollowerReadiness.ps1`.

```powershell
$cases = @(
    'CallbackAbsent',
    'Ordering',
    'WrongFollower',
    'ReadinessFailure',
    'CleanupFailure'
)

foreach ($case in $cases) {
    pwsh -NoProfile -File scripts/Test-GeordiPostFollowerReadiness.ps1 -Case $case
    if ($LASTEXITCODE -ne 0) {
        throw "PostFollowerReadiness/$case failed: $LASTEXITCODE"
    }
}
```

Coverage: callback-absent compatibility; validated identity/publication before callback and handoff completion; wrong-follower rejection before readiness; truthful incomplete state; cleanup attempt and primary-failure precedence; sealed historical evidence immutability.

#### P3 — B1–B3: synthetic caller/workflow regressions

Run separately in this order:

**B1 — M11 backend**
```powershell
pwsh -NoProfile -File scripts/Test-GeordiM11BackendGenerations.ps1 -SelfTest
if ($LASTEXITCODE -ne 0) { throw "M11 backend SelfTest failed: $LASTEXITCODE" }
```

Coverage: three synthetic M11 backend boundaries, failure matrix, dedicated fixture-volume removal safety, and production wiring.

**B2 — M12 main backend**
```powershell
pwsh -NoProfile -File scripts/Test-GeordiM12BackendGenerations.ps1 -Case SelfTest
if ($LASTEXITCODE -ne 0) { throw "M12 backend SelfTest failed: $LASTEXITCODE" }
```

Coverage: reset-evidence publication/reuse/integrity/races, backend positive chain and failure cases, volume/command scope, metric phases, recovery ordering, and transferred-path wiring.

**B3 — M12 overlap backend**
```powershell
pwsh -NoProfile -File scripts/Test-GeordiM12OverlapBackendVmGenerations.ps1 -Case SelfTest
if ($LASTEXITCODE -ne 0) { throw "M12 overlap backend SelfTest failed: $LASTEXITCODE" }
```

Coverage: command scope, entry state, volume ownership, persisted VM evidence, backend positive handoffs, 12 fault cases at each of two boundaries, full overlap sequence, and cross-service failure.

These are caller/workflow compatibility regressions, not pure callback unit tests. Their wider evidence/volume/recovery checks are retained because they protect the four authorized integrations.

#### P4 — C: capture-generation/authentication boundary

Run in this order, with immediate exit-code checks:

```powershell
pwsh -NoProfile -File scripts/Test-GeordiCaptureGenerations.ps1 -Case AuthContract
if ($LASTEXITCODE -ne 0) { throw "AuthContract failed: $LASTEXITCODE" }

pwsh -NoProfile -File scripts/Test-GeordiCaptureGenerations.ps1 -Case Boundaries
if ($LASTEXITCODE -ne 0) { throw "Boundaries failed: $LASTEXITCODE" }
```

Coverage:
- `AuthContract`: authentication initialization/import path, trusted authenticated request helper, Bearer construction, protected lifecycle request, and six negative controls.
- `Boundaries`: synthetic M9–M14 generation-boundary model, including the corrected M12 Collector generation and fail-closed cases.

The prior failed Boundaries attempt is retained as historical. The post-D2 corrected Boundaries result is the current focused result; the complete reconstructed sequence still requires a fresh run from P0.

#### P5 — B4a: M12 overlap Collector synthetic caller regression

```powershell
pwsh -NoProfile -File scripts/Test-GeordiM12OverlapCollector.ps1 -SelfTest
if ($LASTEXITCODE -ne 0) { throw "M12 overlap Collector SelfTest failed: $LASTEXITCODE" }
```

Coverage: injected Compose executor contract; synthetic normal/isolated configuration fixtures; seven restart edges versus zero; normalized configuration equivalence; protected M19 mount configuration; eight negative propagation mutations; command scope; sequential Collector handoffs; startup ordering; wrapper failures; wrong-follower boundaries; and second-handoff failure matrix.

**Execution classification:** after D2-09, this selector uses the injected executor and synthetic configuration fixtures. It is Docker-independent in the reviewed implementation and does not invoke the real Compose renderer.

#### P6 — B4b: real Compose configuration-render integration

```powershell
pwsh -NoProfile -File scripts/Test-GeordiM12OverlapCollector.ps1 -ComposeIntegration
if ($LASTEXITCODE -ne 0) { throw "M12 overlap ComposeIntegration failed: $LASTEXITCODE" }
```

Coverage: real normal and combined replacement/isolation Compose renders, seven-to-zero restart propagation, normalized configuration equivalence, protected M19 mount configuration, and the eight negative propagation mutations.

**Narrow permission boundary:** this invokes the Docker CLI only for `docker compose ... config --format json`. It must not invoke `up`, `down`, `restart`, `rm`, `prune`, build, volume mutation, or any runtime lifecycle action. The owner separately authorized and executed this config-render-only operation on 2026-11-16. Any future rerun as part of the full reconstructed sequence requires its own explicit approval; the previous authorization is not blanket permission for later executions.

#### P7 — D: read-only scope and diff validation

Run and inspect:

```powershell
git status --short --branch
git diff --check
git diff --check m19...HEAD
git diff --name-only m19...HEAD
```

The expected committed branch-diff paths at the last verified D2 scope review are exactly:

1. `docs/plans/EXECPLAN-M19-POST-FOLLOWER-READINESS.md`
2. `docs/plans/M19-ACCEPTED-REGRESSION-RECONSTRUCTION.md`
3. `docs/plans/M19-D2-TEST-INFRASTRUCTURE-AUDIT.md`
4. `docs/plans/M19-WORKTREE-RESUME-CHECKPOINT.md`
5. `scripts/Test-GeordiCaptureGenerations.ps1`
6. `scripts/Test-GeordiM12OverlapCollector.ps1`
7. `scripts/lib/GeordiM12OverlapCollector.ps1`

Reconfirm the current list rather than assuming it remains unchanged. No application source, CI configuration, Compose YAML, TLS/certificates, runtime captures, or protected-volume definitions may appear. The worktree status must be reviewed separately from the committed branch comparison.

#### P8 — Fresh independent read-only review

Only after P1–P7 pass, obtain a fresh independent review of the exact resulting D2 state. It must cover:
- shared callback ordering and exact follower binding;
- failure-state truthfulness, cleanup attempt, and primary-error precedence;
- immutability of previously sealed generation/handoff history;
- M11, M12 backend, overlap backend and overlap Collector caller compatibility;
- normal/isolated Compose equivalence and protected M19 mount configuration;
- CI nonactivation and branch/file scope;
- the complete reconstructed execution log and any deviations.

The review must report findings by severity and explicitly disposition BLOCKER/HIGH/MEDIUM/LOW. No previous review of a different branch state or gate sequence substitutes for this review.

### 11.3 Evidence ledger — previous focused results versus full-set status

| Item | Previous/current evidence | Status for a complete reconstructed run |
|---|---|---|
| P0 branch/worktree preconditions | Prior branch isolation/scope recorded | Reconfirm |
| P1 parser, all eight paths in one pass | D2 pair parsed PASS in the owner run; CaptureGenerations parser PASS is recorded historically; no evidence of all eight parsed together | Rerun complete list |
| P2 five shared-seam cases | Prior focused PASS recorded | Rerun individually |
| P3 B1 M11 caller | Prior focused PASS recorded | Rerun |
| P3 B2 M12 backend caller | Prior focused PASS recorded | Rerun |
| P3 B3 M12 overlap backend caller | Prior focused PASS recorded, including 12-case matrices at both boundaries | Rerun |
| P4 AuthContract | Prior PASS; six negative controls rejected | Rerun |
| P4 Boundaries | Corrected D2 run PASS; owner confirmed exit code 0 and both PASS markers | Rerun in the complete sequence |
| P5 B4a Collector SelfTest | Owner-supplied output on 2026-11-16: PASS; synthetic executor/fixtures; runtime NOT_RUN; CI unchanged | Rerun in the complete sequence |
| P6 B4b ComposeIntegration | Owner-supplied output on 2026-11-16: PASS; config render only; lifecycle NOT_INVOKED | Rerun only with fresh narrow approval |
| P7 diff/scope | Prior branch-scope reviews and earlier diff checks exist | Rerun against current branch/worktree |
| P8 independent review after complete sequence | No qualifying fresh review recorded | Pending |
| Entire reconstructed sequence P0–P8 | Never completed end-to-end | **NOT RUN** |

The B4a and B4b results are current focused execution evidence after D2-09, but they do not retroactively make the full set green. Likewise, individual earlier PASS results are not a substitute for a fail-fast run from P0.

### 11.4 Explicit exclusions and non-merging rules

Do not append the following to this focused reconstructed set:

- **M10 seven-case replacement suite:** M10 was not migrated to the shared callback seam. Keep its compatibility suite separate unless a concrete shared-helper regression risk is identified and the owner approves inclusion.
- **M11→M12 fixture-transfer 18 focused gates / A–S matrix:** separate capability proof.
- **M11→M12 remediation 19-gate sequence:** separate formal remediation proof.
- **Formal M12 overlap 26-gate sequence:** separate later validation, conditional on a green approved reconstructed set and clean P8 review.
- **M13, Gate 5 promotion/acceptance, runtime smoke, Docker lifecycle, TLS/certificate operations, real capture mutation, cleanup, protected-volume operations, CI activation, candidate promotion, and M19 acceptance:** excluded and not authorized.

Do not infer the accepted regression inventory from a PowerShell `ValidateSet`, merge independently scoped ExecPlans, or treat a prior PASS in one plan as proof that the item belonged to the historical accepted set.

### 11.5 Acceptance criteria for this reconstruction

The reconstructed set is considered green only when:
1. the owner approves this reconstructed scope and order;
2. P0–P7 pass in order, fail-fast, with immediate exit-code checks;
3. B4b is executed only under separate narrow approval and reports config-render-only/lifecycle-not-invoked;
4. the final diff/worktree scope matches the approved boundary;
5. P8 finds no unresolved BLOCKER or HIGH findings, with MEDIUM/LOW findings explicitly dispositioned;
6. no excluded operation occurs.

A green reconstructed set is a focused post-follower readiness result only. It is not M19 acceptance and does not itself authorize the formal overlap 26-gate sequence.

### 11.6 Owner-review disposition

The historical sequence remains unrecoverable from the currently inspected repository history and checked-in plans. The proposed membership and order above are now fully specified and evidence-mapped as **RECONSTRUCTED — NOT HISTORICAL**.

**Current decision requested:** approve or amend the reconstructed P0–P8 sequence before any full-sequence execution. This documentation update does not run tests or authorize the rerun of B4b.
