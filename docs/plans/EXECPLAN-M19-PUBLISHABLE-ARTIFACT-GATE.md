# EXECPLAN — M19 Publishable Artifact Gate Decoupling

**Date:** 2026-11-17 (America/Buenos_Aires)  
**Branch:** `fix/m19-log-follower-json-dates`  
**Baseline:** `50cff4143ab315509abfcb55707a96b8dd71411d`  
**Scope:** approved implementation and verification of the publishable-artifact gate refactor.  
**Status:** **IMPLEMENTATION IN PROGRESS — VERIFICATION PENDING**.

The owner authorized implementation on 2026-11-17. Code changes are confined to the artifact-inspection module and its public/self-test wrappers. No M19 runtime, Docker, TLS, cleanup, or private-evidence operation is included.

## 1. Decision and current status

PLAN-T01 (current-contract analysis) is complete. PLAN-T02 (interface specification) was approved by the project owner with option A.

Approved constraints:

1. Preserve the public contracts of the three existing scripts.
2. Extract existing artifact-inspection logic without weakening or dropping checks.
3. Reject reparse points under both real and synthetic roots.
4. Retain current inspection limits unless evidence demonstrates they are insufficient.
5. Build synthetic fixtures that satisfy the complete production validation contract.
6. Do not add SelfTest-only exceptions to production security validation.
7. Target the repository's documented PowerShell 7 CI environment; confirm the local host edition/version before local execution.

The repository's documented CI runner uses PowerShell 7, and existing scripts already depend on PowerShell 7 JSON features such as `ConvertFrom-Json -AsHashtable`. PowerShell 7 is therefore the implementation compatibility target. The user's local edition/version output remains outstanding and is required before claiming local execution compatibility, but does not block authoring against the repository's declared CI target.

## 2. Baseline and evidence

Repository: `marcelo1damian2prieto/geordi`  
Branch: `fix/m19-log-follower-json-dates`  
Baseline commit: `50cff4143ab315509abfcb55707a96b8dd71411d`

The owner-provided local verification recorded:

- `git rev-parse HEAD` returned the baseline commit above.
- `git status --short` returned no entries (clean worktree).
- `Test-Path .\scripts\lib\GeordiPublishableArtifacts.psm1` returned `False`.

The remote branch ref was independently confirmed at the same baseline commit when this plan was documented.

### 2.1 Inspected scripts

| File | SHA-1 at baseline | Existing responsibility |
|---|---|---|
| `scripts/Test-GeordiCredentialGate.ps1` | `500e6b49373033527a78066ae66453e483cc374f` | Bounded SelfTest/orchestrator; creates synthetic private-evidence captures and invokes gate cases, but currently enumerates real repository build outputs. |
| `scripts/Test-GeordiCredentialGateRequired.ps1` | `2e36ae4361574688dfebd3f824fbd849a7f351e4` | Required M19 private-evidence gate: manifest, Finalize attempt, capture/channel metadata, credential scan, persisted Loki/VM evidence and summary publication. |
| `scripts/Test-GeordiPublishableArtifacts.ps1` | `dccb7a951eeb3c6ae06c9351a28fccbc14099d60` | Publishable-artifact inventory, archive inspection, forbidden-content checks and hash consistency validation. |

### 2.2 Current coupling and observed SelfTest failure

`Test-GeordiCredentialGate.ps1 -SelfTest` currently requires built publishable artifacts. Its artifact inventory is derived from physical repository paths, including backend target reports/JARs, optional CI staging artifacts, verification metadata and frontend distribution output. The observed failure is:

```text
Gate self-test requires built publishable artifacts.
```

This demonstrates that the SelfTest has a build-output precondition; it does not by itself establish a defect in the production gate.

A second fixture-contract defect was identified. The current synthetic manifest omits the accepted Finalize attempt contract (`acceptedAttemptId` and `attempts`) required by the Required Gate. Its Tempo fixture is a plain text file, while the credential scanner requires Tempo segment metadata. Consequently, the nominal positive `valid_manifest` case cannot satisfy the existing production validators even after artifact-root decoupling.

The correction is to build complete synthetic fixtures. Production validation must not be weakened to make the test pass.

### 2.3 Responsibility boundaries to preserve

- `Test-GeordiCredentialGateRequired.ps1` remains responsible for M19 manifest/Finalize/private-evidence validation and orchestration of the credential and persisted-evidence scanners.
- `Test-GeordiCredentialLeaks.ps1` remains the private-capture credential scanner; its decoding, recursive archive scan, positive controls and bounded expansion contract are out of scope.
- `Test-GeordiPersistedCredentialEvidence.ps1` and `GeordiPersistedMetricEvidence.ps1` remain responsible for persisted Loki/VictoriaMetrics evidence.
- `GeordiPrivateEvidence.ps1` remains the private-capture scanning boundary.
- `GeordiCredentialGateOrchestration.ps1` remains the independent gate orchestration seam.
- The new module owns publishable-artifact enumeration and inspection only. It must not absorb M19 manifest, runtime credential-capture, Tempo/Loki/VM evidence or persisted-metric responsibilities.

## 3. Target architecture

The new module is implemented at:

```text
scripts/lib/GeordiPublishableArtifacts.psm1
```

The module receives an explicit inspection root. Production supplies the repository root; SelfTest supplies a bounded synthetic workspace containing the same relative artifact layout. The module must not infer the root from a hardcoded physical checkout path.

The same inventory and content-validation rules apply to both roots. The mode/root distinction selects the authorized input root; it must not weaken validation.

### 3.1 Responsibilities

The module will own:

- Enumerating the publishable-artifact set from a supplied root.
- Applying the existing required/optional artifact policy.
- Producing a normalized inventory and SHA-256 snapshot.
- Validating an expected inventory against the current filesystem.
- Inspecting JAR/ZIP archives and their entries.
- Rejecting forbidden paths/material and malformed archives.
- Enforcing the archive-entry traversal bound. Archives are inspected through their central-directory entries and are not extracted; private-capture file/expansion bounds remain owned by the credential scanner.
- Detecting path escape, reparse points and unsafe root resolution.
- Returning bounded results and sanitized error categories to the calling script.

The module will not own:

- M19 manifest parsing or schema validation.
- Finalize-attempt identity or phase validation.
- Private runtime capture scanning.
- Persisted Loki/VictoriaMetrics evidence.
- Docker/Compose lifecycle or cleanup.
- Creation/deletion of capture roots or private evidence.

## 4. Approved interface direction

The following functions are implemented and exported by the module. `Mode` is constrained to `Production` or `SelfTest`; both modes apply the same artifact policy and validation rules.

### 4.1 `Get-GeordiPublishableArtifactInventory`

Implemented signature:

```powershell
Get-GeordiPublishableArtifactInventory `
    -RootPath <string> `
    -Mode <Production|SelfTest>
```

Responsibility: enumerate the artifact set under the supplied root and return an inventory snapshot.

The result must carry the existing inventory information:

- `artifactInventory`: the existing completion marker, exactly `complete`.
- `fileCount`.
- `archiveCount`.
- `archiveEntryCount`.
- `files[]`, each containing a normalized root-relative `path` and lowercase SHA-256 digest.

Paths are relative to the supplied root, unique, normalized and incapable of escaping that root. Required and optional artifact membership must preserve the current script's behavior unless a separately approved decision changes it.

### 4.2 `Test-GeordiPublishableArtifactInventory`

Conceptual signature:

```powershell
Test-GeordiPublishableArtifactInventory `
    -RootPath <string> `
    -ExpectedInventory <object> `
    -Mode <Production|SelfTest>
```

Responsibility: validate the current artifact set against an independently supplied expected inventory.

Required checks:

1. Inventory structure and supported shape.
2. Required artifact existence.
3. Unique normalized relative paths.
4. Exact artifact-set membership where the existing contract requires it.
5. File count, archive count and archive-entry count.
6. SHA-256 equality for each expected file.
7. Rejection of missing, unexpected, replaced or changed files.
8. Root containment and reparse-point rejection.

The expected inventory must not be generated from the same final scan and then treated as an independent reference.

### 4.3 `Test-GeordiPublishableArtifactContent`

Conceptual signature:

```powershell
Test-GeordiPublishableArtifactContent `
    -RootPath <string> `
    -Inventory <object> `
    -Mode <Production|SelfTest>
```

Responsibility: inspect the content represented by the validated inventory.

Required checks:

- JAR/ZIP readability and structural validity.
- Archive-entry path validation.
- Existing forbidden path/material patterns, extracted without broadening or weakening them.
- Bounded archive-entry traversal without extracting or expanding archive contents.
- Fail-closed behavior for malformed archives, traversal attempts and exceeded limits.

## 5. Inventory and filesystem contract

### 5.1 Root selection

- Production root: explicit repository root derived by the public script and passed to the module.
- SelfTest root: one unique temporary workspace created by the SelfTest and passed explicitly.
- The SelfTest workspace must reproduce the relative directory structure required by the artifact policy.
- No SelfTest operation may fall back to the real checkout's `backend/target`, `backend/.ci-artifact` or `frontend/dist`.
- Root selection is explicit; no ambient current-directory dependency is allowed.

### 5.2 Path safety

- Resolve and normalize the root once at the boundary.
- Reject rooted/absolute inventory entries, traversal segments and paths that resolve outside the root.
- Reject reparse points in the inspected path chain and artifact set.
- Do not follow symlinks/junctions as an implicit convenience.
- Verify file identity/path containment before reading and recheck the file snapshot after scanning to reduce time-of-check/time-of-use exposure.
- Do not delete or modify inspected artifacts.

### 5.3 Inventory consistency and independent mode

Manifest-backed mode compares the current artifact set and hashes with the inventory captured by the upstream credential evidence workflow.

Independent mode remains independent of a runtime manifest, but it must still apply the same artifact policy and content checks. It takes an initial inventory/hash snapshot and verifies that files did not change during inspection. It does not claim comparison against a prior credential-scan manifest when none was supplied.

### 5.4 Archive limits

Retain the existing inspection limits and archive safety rules from the current implementation. Do not silently increase bounds or change recursion semantics during extraction. Any limit change requires evidence and a separate owner decision.

### 5.5 Test-runner diagnostic exclusion

The recursive `surefire-reports` and `failsafe-reports` roots exclude files whose names end in `.dump` or `.dumpstream` (case-insensitive). These are test-runner diagnostic artifacts, not publishable test reports. The exclusion is deliberately scoped to those two report roots; it does not apply to `frontend/dist`, standalone artifacts, or other inventory roots. XML and TXT test reports remain included. Reparse-point rejection still applies to every entry encountered while traversing either report root, including entries that would otherwise match an exclusion.

## 6. Public script contracts

| Script | Planned change | Contract to preserve |
|---|---|---|
| `Test-GeordiCredentialGate.ps1` | Build synthetic publishable artifacts under the SelfTest workspace and call the shared module through the existing gate path. | `-SelfTest`, bounded temporary workspace, negative/positive gate cases and safe cleanup. |
| `Test-GeordiCredentialGateRequired.ps1` | Retain the private-evidence/Finalize boundary; it does not invoke the artifact validator, preserving independent gate execution. Its accepted attempt must still record the successful `artifact-scan` phase. | `-ManifestPath`, `-SummaryPath`, `-DiagnosticFailure`, manifest/Finalize/private-evidence behavior and sanitized failures. |
| `Test-GeordiPublishableArtifacts.ps1` | Thin public wrapper over the module; adds optional `-RootPath` for synthetic roots. | Existing `-ManifestPath`, `-Independent`, output contract and fail-closed semantics are preserved. |

Default SummaryPath behavior must remain explicit because it writes under `backend/target`. SelfTest must always pass a SummaryPath under its own temporary workspace; it must not write to the default path.

## 7. Synthetic fixture contract

SelfTest must create all inputs required by the production validators, not just enough files to reach the next line.

At minimum, the valid fixture must include:

- A manifest with the required version, root, timestamps, sentinels, controls, captures, capture metadata and additional-source fields.
- Exactly one completed accepted Finalize attempt and a valid `acceptedAttemptId`.
- The required six successful Finalize phases: `tempo-search`, `tempo-detail`, `loki`, `victoriametrics`, `artifact-scan` and `manifest`.
- Attempt channel data consistent with the published manifest.
- Required private capture files and their metadata.
- A Tempo fixture with valid segment metadata, not an unstructured text substitute.
- Persisted Loki and VictoriaMetrics fixture evidence accepted by the existing persisted-evidence validator.
- A synthetic publishable-artifact tree that exercises the same artifact policy as production.

Negative fixtures must independently demonstrate fail-closed rejection for malformed or missing manifest/attempt data, invalid phase state, missing channel/control, malformed Tempo metadata, persisted-evidence failures, invalid inventory, digest mismatch, forbidden archive entry/material, path traversal, reparse point and archive-bound violations.

No fixture shortcut may disable a production validator.

## 8. Error and diagnostic contract

Internal errors are classified conceptually as:

| Category | Meaning |
|---|---|
| `artifact_missing` | Required artifact absent |
| `inventory_invalid` | Inventory shape, path or membership invalid |
| `artifact_digest_mismatch` | Current digest differs from expected digest |
| `archive_invalid` | Archive unreadable or structurally invalid |
| `forbidden_material_detected` | Forbidden path or content found |
| `root_path_rejected` | Root/path containment or reparse-point violation |
| `scan_limit_exceeded` | A bounded inspection limit was exceeded |
| `artifact_validation_failed` | Unexpected internal validation failure |

The public scripts remain responsible for translating internal failures to their existing sanitized messages/output. Do not expose matching bytes, sentinel values, private paths, archive content, parser exceptions or raw provider/file exceptions in CI output.

## 9. Validation strategy

Use selective, contract-focused tests. Do not introduce a broad TDD rewrite.

### Positive cases

- Real-root inventory with the existing expected artifact layout.
- Synthetic-root inventory with equivalent relative layout and policy.
- Surefire/Failsafe XML and TXT reports remain included while `.dump` and `.dumpstream` diagnostics are excluded only within those report roots.
- Matching inventory and hashes.
- Valid JAR/ZIP with allowed entries.
- Independent scan without runtime manifest.
- Complete synthetic Required Gate manifest, Finalize attempt, Tempo metadata and persisted evidence.

### Negative and boundary cases

- Missing required artifact.
- Surefire/Failsafe `.dump` and `.dumpstream` files are excluded; report XML/TXT inclusion and exclusion scope are asserted.
- Unexpected or duplicate inventory path.
- Absolute path, traversal and root escape.
- Reparse point at root/intermediate/artifact location.
- Missing, changed or replaced file.
- Digest mismatch and mutation during scan.
- Invalid/truncated archive and invalid entry path.
- Forbidden path/material in archive.
- Archive-entry count at and beyond its configured bound; private-capture file/expansion limits remain covered by the existing credential-scanner self-tests.
- Missing accepted attempt, wrong attempt identity or phase, invalid Tempo metadata.
- Missing positive control or persisted-source evidence.
- Sanitized failure output that never contains sentinel values.

### Verification sequence

1. Confirm PowerShell edition/version and set the supported compatibility target.
2. Parse the new module and three affected scripts.
3. Run focused module inventory/content contract tests on synthetic fixtures.
4. Run SelfTest with no real build artifacts present.
5. Run Required Gate negative and positive fixture cases.
6. Run independent artifact scan.
7. Run manifest-backed artifact scan and hash-stability checks.
8. Run the focused regression set and quality checks.
9. Obtain independent review before reporting implementation completion.

No build or runtime M19 operation is part of this plan.

## 10. Implementation task breakdown

| ID | Task | Acceptance |
|---|---|---|
| IMP-T01 | Create `GeordiPublishableArtifacts.psm1` and extract artifact policy/inspection. | **IMPLEMENTED** — explicit root, required/optional roots, SHA-256 inventory, reparse checks, ZIP/JAR entry validation, archive entry bound and post-scan hash revalidation. |
| IMP-T02 | Integrate `Test-GeordiPublishableArtifacts.ps1`. | **IMPLEMENTED** — manifest-backed and independent modes delegate to the module; optional `-RootPath`; existing output line and error sanitization retained. |
| IMP-T03 | Build synthetic artifact tree in Credential Gate SelfTest. | **IMPLEMENTED** — SelfTest creates reports, properties, valid synthetic JARs and frontend output under its own temporary root. |
| IMP-T04 | Repair complete Required Gate fixtures. | **IMPLEMENTED IN SOURCE** — one completed accepted attempt, all six PASS phases, channel binding and valid segmented Tempo fixture are generated. Runtime proof remains pending. |
| IMP-T05 | Integrate the three scripts and bounded cleanup. | **PARTIAL** — artifact validator is shared by production wrapper and SelfTest; Required Gate intentionally remains the private-evidence gate so artifact and credential scans stay independent. |
| IMP-T06 | Exclude test-runner diagnostic files from report roots. | **IMPLEMENTED IN SOURCE** — `.dump` and `.dumpstream` are excluded case-insensitively from Surefire/Failsafe report roots only; SelfTest asserts report inclusion, diagnostic exclusion and scope boundary. |
| VERIFY-T01 | Focused positive/negative/boundary verification. | **PENDING EXECUTION** — SelfTest now covers required artifact absence, malformed ZIP, forbidden archive path, traversal, reparse point (when host permits symlink creation), digest mutation and inventory mismatch. |
| VERIFY-T02 | Compatibility and regression verification. | **PENDING** — PowerShell 7 parser and local SelfTest execution required. |
| VERIFY-T03 | Independent review and diff verification. | **PENDING** — no independent review or runtime verification claimed yet. |

Implementation task IDs and current status are tracked in the table below.

## 11. Preconditions and explicit exclusions

### Compatibility confirmation

The repository's documented integration runner is PowerShell 7. The affected scripts already use PowerShell 7-specific `ConvertFrom-Json -AsHashtable`, so the module is authored against that existing baseline. Before local verification, record the local host with:

```powershell
$PSVersionTable.PSVersion.ToString()
$PSVersionTable.PSEdition
```

A local PowerShell 5.1 host is not a supported execution target for these scripts.

### Explicit exclusions

Throughout implementation and verification:

- Do not build backend/frontend artifacts or populate repository `target`/CI staging directories; the SelfTest must use only its temporary synthetic tree.
- Do not execute M19 Begin or Finalize.
- Do not run `New-GeordiCredentialEvidence.ps1` in any action mode.
- Do not inspect, modify or clean `.runtime/m19`, its pointer, private captures or TLS material.
- Do not touch protected volumes or perform Docker/Compose lifecycle operations.
- Do not weaken credential, persisted-evidence, manifest or artifact validation.
- Do not claim M19 acceptance from SelfTest or historical evidence.

## 12. Approval record

- **PLAN-T01:** analysis completed from baseline source inspection and owner-provided checkout evidence.
- **PLAN-T02:** approved by owner, option A, 2026-11-17.
- **Approved design constraints:** preserve public contracts; extract without weakening; reject reparse points; retain current bounds; complete synthetic fixtures; no SelfTest security exceptions; target PowerShell 7 per CI and confirm the local host before local verification.
- **Implementation authorization:** **GRANTED** by owner on 2026-11-17.
- **Implementation source changes:** module, artifact wrapper and Credential Gate SelfTest updated; no local PowerShell execution has been recorded.
- **Implementation source HEAD at this checkpoint:** `47e8277c06e8a87a455ce20243e8a2a942806988`; subsequent commits in this branch update only documentation.
- **M19 milestone status:** unchanged — **M19 NOT READY — REMEDIATION REQUIRED**.


## 13. Implementation checkpoint — 2026-11-17

The following implementation changes have been published to the branch:

- Added `scripts/lib/GeordiPublishableArtifacts.psm1` with the three approved exported functions.
- Refactored `scripts/Test-GeordiPublishableArtifacts.ps1` to use the module for manifest-backed and independent scans. The optional `-RootPath` supports a synthetic root without changing existing invocations.
- Updated `scripts/Test-GeordiCredentialGate.ps1` to create a synthetic artifact layout and a valid segmented Tempo fixture, and to construct the accepted Finalize-attempt contract required by the Required Gate.
- Added SelfTest cases for artifact inventory mismatch, digest mutation, forbidden archive paths, traversal, missing required artifacts, malformed ZIPs and reparse-point rejection when symbolic-link creation is supported by the host.

The private-evidence gate remains independent from the publishable-artifact gate. The Required Gate validates the accepted attempt and private evidence; the artifact wrapper performs the artifact scan. The orchestration layer continues to run these gates independently.

**Verification limitation:** changes were written through the connected GitHub repository integration. No PowerShell parser, SelfTest, build, or CI job has been executed in this session. All implementation items above are source-level completion only until the user runs the prescribed verification and results are reviewed. Do not interpret this checkpoint as PASS evidence.

The synthetic artifact fixture uses only the SelfTest's unique temporary directory and is removed by its existing guarded `finally` block. It does not create repository build outputs or access `.runtime/m19`, the runtime pointer, private captures or TLS material. The existing `Write-GeordiSafeDiagnostics.ps1` call may query Docker container status, as it did before this refactor; no Docker lifecycle or protected-volume operation is part of this change.


## 14. Test-report diagnostic filtering checkpoint — 2026-11-17

The owner authorized a narrowly scoped inventory-policy correction after local enumeration showed two Surefire `.dumpstream` files in the recursive report root. The module now excludes filenames ending in `.dump` or `.dumpstream` (case-insensitive) only beneath `backend/target/surefire-reports` and `backend/target/failsafe-reports`. XML/TXT test reports remain part of the inventory. Other roots are unchanged.

The synthetic Credential Gate SelfTest now creates Surefire and Failsafe XML/TXT reports plus `.dump`/`.dumpstream` fixtures. It asserts that reports are retained, diagnostics are omitted, and a `.dumpstream` fixture under `frontend/dist` remains included to prove the exclusion is not global.

This checkpoint records source changes only. PowerShell parser, SelfTest, independent scan, CI and independent review have not yet been executed for this correction. M19 remains **NOT READY — REMEDIATION REQUIRED**.


## 15. StrictMode optional-policy lookup correction — 2026-11-17

The first local SelfTest execution after the report-filtering change returned the sanitized `artifact_validation_failed` error. Source inspection identified an optional-property lookup against artifact-definition Hashtables while `Set-StrictMode -Version Latest` is active. Only Surefire/Failsafe definitions carry `excludeDiagnosticFiles`; accessing that key unconditionally fails for other definitions. The inventory loop now checks `ContainsKey` and defaults the switch to false when the property is absent. The report-root exclusion policy is unchanged.

The correction is source-level only. Parser and SelfTest must be rerun against this commit; no PASS is claimed. M19 remains **NOT READY — REMEDIATION REQUIRED**.
