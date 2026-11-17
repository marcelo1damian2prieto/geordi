# EXECPLAN — M19 Publishable Artifact Gate Decoupling

**Date:** 2026-11-17 (America/Buenos_Aires)  
**Branch:** `fix/m19-log-follower-json-dates`  
**Baseline:** `50cff4143ab315509abfcb55707a96b8dd71411d`  
**Scope:** documentation and approved design for the publishable-artifact gate refactor.  
**Status:** **PLAN CLOSED / IMPLEMENTATION NOT AUTHORIZED**.

This plan records the analysis and owner-approved interface direction for decoupling publishable-artifact inspection from physical build outputs. It does not authorize implementation, builds, runtime execution, Docker operations, M19 Begin/Finalize, cleanup, or access to private runtime evidence.

## 1. Decision and current status

PLAN-T01 (current-contract analysis) is complete. PLAN-T02 (interface specification) was approved by the project owner with option A.

Approved constraints:

1. Preserve the public contracts of the three existing scripts.
2. Extract existing artifact-inspection logic without weakening or dropping checks.
3. Reject reparse points under both real and synthetic roots.
4. Retain current inspection limits unless evidence demonstrates they are insufficient.
5. Build synthetic fixtures that satisfy the complete production validation contract.
6. Do not add SelfTest-only exceptions to production security validation.
7. Confirm the supported PowerShell edition/version before implementation.

The PowerShell compatibility prerequisite remains open because the exact output of the local version query has not yet been recorded. Therefore the planning phase is closed, but implementation remains blocked until that evidence is supplied and the implementation compatibility target is fixed.

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

The new module is planned at:

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
- Enforcing current file, archive, entry and expansion limits.
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

The following names and signatures are the approved design direction. They are not implemented PowerShell declarations yet; exact parameter attributes and return types must be finalized against the confirmed PowerShell compatibility target.

### 4.1 `Get-GeordiPublishableArtifactInventory`

Conceptual signature:

```powershell
Get-GeordiPublishableArtifactInventory `
    -RootPath <string> `
    -Mode <Production|SelfTest>
```

Responsibility: enumerate the artifact set under the supplied root and return an inventory snapshot.

The result must carry the existing inventory information:

- `artifactInventory`: normalized relative artifact paths.
- `fileCount`.
- `archiveCount`.
- `archiveEntryCount`.
- `files[]`, each containing a normalized relative `path` and lowercase SHA-256 digest.

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
- Current bounded archive traversal and expansion limits.
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

## 6. Public script contracts

| Script | Planned change | Contract to preserve |
|---|---|---|
| `Test-GeordiCredentialGate.ps1` | Build synthetic publishable artifacts under the SelfTest workspace and call the shared module through the existing gate path. | `-SelfTest`, bounded temporary workspace, negative/positive gate cases and safe cleanup. |
| `Test-GeordiCredentialGateRequired.ps1` | Integrate the shared artifact validator without bypassing the M19 evidence contract. | `-ManifestPath`, `-SummaryPath`, `-DiagnosticFailure`, manifest/Finalize/private-evidence behavior and sanitized failures. |
| `Test-GeordiPublishableArtifacts.ps1` | Become a thin public wrapper over the module. | `-ManifestPath`, `-Independent`, existing output contract and fail-closed semantics. |

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
- Matching inventory and hashes.
- Valid JAR/ZIP with allowed entries.
- Independent scan without runtime manifest.
- Complete synthetic Required Gate manifest, Finalize attempt, Tempo metadata and persisted evidence.

### Negative and boundary cases

- Missing required artifact.
- Unexpected or duplicate inventory path.
- Absolute path, traversal and root escape.
- Reparse point at root/intermediate/artifact location.
- Missing, changed or replaced file.
- Digest mismatch and mutation during scan.
- Invalid/truncated archive and invalid entry path.
- Forbidden path/material in archive.
- File/archive/entry/expansion bounds at limit and beyond limit.
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
| IMP-T01 | Create `GeordiPublishableArtifacts.psm1` and extract artifact policy/inspection. | Shared module owns enumeration, inventory, path safety, archive and content checks; no reduced controls. |
| IMP-T02 | Integrate `Test-GeordiPublishableArtifacts.ps1`. | Existing parameters/output remain compatible; manifest and independent modes work through the module. |
| IMP-T03 | Build synthetic artifact tree in Credential Gate SelfTest. | SelfTest no longer requires real backend/frontend build outputs. |
| IMP-T04 | Repair complete Required Gate fixtures. | Positive fixture satisfies accepted Finalize, all phases, Tempo segment metadata and persisted evidence. |
| IMP-T05 | Integrate the three scripts and bounded cleanup. | Same validator/policy used by production and SelfTest; no real runtime path touched by SelfTest. |
| VERIFY-T01 | Focused positive/negative/boundary verification. | All contract cases pass and failures remain sanitized/fail-closed. |
| VERIFY-T02 | Compatibility and regression verification. | Supported PowerShell target parses/runs all affected scripts; existing CLI contracts remain intact. |
| VERIFY-T03 | Independent review and diff verification. | No BLOCKER/HIGH; no unrelated code, runtime, CI or protected evidence changes. |

Implementation task IDs are prospective. They do not represent work already started.

## 11. Preconditions and explicit exclusions

### Open prerequisite

The owner must provide the output of:

```powershell
$PSVersionTable.PSVersion.ToString()
$PSVersionTable.PSEdition
```

Then the implementation target must be checked against the repository's supported execution environments and CI runners before choosing language/runtime features.

### Explicit exclusions

Until implementation is separately authorized:

- Do not create the module or modify any script.
- Do not build backend/frontend artifacts or populate `target`/CI staging directories.
- Do not execute M19 Begin or Finalize.
- Do not run `New-GeordiCredentialEvidence.ps1` in any action mode.
- Do not inspect, modify or clean `.runtime/m19`, its pointer, private captures or TLS material.
- Do not touch protected volumes or perform Docker/Compose lifecycle operations.
- Do not weaken credential, persisted-evidence, manifest or artifact validation.
- Do not claim M19 acceptance from SelfTest or historical evidence.

## 12. Approval record

- **PLAN-T01:** analysis completed from baseline source inspection and owner-provided checkout evidence.
- **PLAN-T02:** approved by owner, option A, 2026-11-17.
- **Approved design constraints:** preserve public contracts; extract without weakening; reject reparse points; retain current bounds; complete synthetic fixtures; no SelfTest security exceptions; confirm PowerShell compatibility before implementation.
- **Implementation authorization:** **NOT GRANTED**.
- **M19 milestone status:** unchanged — **M19 NOT READY — REMEDIATION REQUIRED**.
