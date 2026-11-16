[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Identity','Seal','Replacement','OutputCardinality','NoisyReplacementFailure','Failures','Manifest','StreamsEmpty','StreamsOutput','StreamsIntegrity','StreamsPathUniqueness','HandoffTimestamps','AlreadySealedTimestamp','AlreadySealedCulture','ActivePathChronology','RetryRetainedFailure','HandoffBoundaryUniqueness','ReverseHandoffReference','OrphanHandoff','HandoffAdjacency','AuthContract','Boundaries')][string] $Case)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureGenerations.ps1')

function Assert-CaptureGeneration([bool] $Condition,[string] $Message) {
    if (!$Condition) { throw "Capture generation regression failed: $Message" }
}
function Get-CaptureTestFunction {
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst] $Ast,[Parameter(Mandatory)][string] $Name)
    $matches=@($Ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name},$true))
    if($matches.Count -ne 1){return $null};return $matches[0]
}
function Get-CaptureTestCommands {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Ast)
    return @($Ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
}
function Test-GeordiEvaluationAuthenticationContract {
    param([Parameter(Mandatory)][string] $EvaluationSource,[Parameter(Mandatory)][string] $AuthenticationSource)
    $tokens=$null;$errors=$null;$evaluationAst=[System.Management.Automation.Language.Parser]::ParseInput($EvaluationSource,[ref]$tokens,[ref]$errors)
    if($errors.Count){return $false}
    $tokens=$null;$errors=$null;$authenticationAst=[System.Management.Automation.Language.Parser]::ParseInput($AuthenticationSource,[ref]$tokens,[ref]$errors)
    if($errors.Count){return $false}
    $dotSource=@($evaluationAst.FindAll({param($node)
        if($node -isnot [System.Management.Automation.Language.CommandAst] -or $node.CommandElements.Count -lt 1){return $false}
        !$node.GetCommandName() -and $node.Extent.Text.TrimStart().StartsWith('. ',[StringComparison]::Ordinal) -and
            $node.CommandElements[0] -is [System.Management.Automation.Language.ParenExpressionAst] -and
            $node.CommandElements[0].Extent.Text -match 'Join-Path' -and $node.Extent.Text -match 'lib/GeordiAuthentication\.ps1'
    },$true)).Count -eq 1
    $initialize=@($evaluationAst.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Initialize-GeordiAuthentication' -and $node.Extent.Text -match '-Identity\s+REGRESSION'},$true)).Count -eq 1
    $textRequest=Get-CaptureTestFunction $evaluationAst 'Invoke-TextRequest'
    $jsonRequest=Get-CaptureTestFunction $evaluationAst 'Invoke-JsonRequest'
    $lifecycle=Get-CaptureTestFunction $evaluationAst 'Assert-M18LifecycleHistoryAndWebhook'
    if(!$textRequest -or !$jsonRequest -or !$lifecycle){return $false}
    $textCommands=Get-CaptureTestCommands $textRequest.Body;$jsonCommands=Get-CaptureTestCommands $jsonRequest.Body
    $lifecycleCalls=@($lifecycle.Body.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-JsonRequest' -and $node.Extent.Text -match '/lifecycle-evaluations' -and $node.Extent.Text -match "'POST'"},$true))
    $evalAuthCalls=@($evaluationAst.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-GeordiScriptRequest'},$true))
    if(!$dotSource -or !$initialize -or $textCommands -notcontains 'Invoke-GeordiScriptRequest' -or
            $textCommands -contains 'Invoke-WebRequest' -or $textCommands -contains 'Invoke-RestMethod' -or
            $jsonCommands -notcontains 'Invoke-GeordiScriptRequest' -or $jsonCommands -contains 'Invoke-WebRequest' -or
            $jsonCommands -contains 'Invoke-RestMethod' -or $lifecycleCalls.Count -ne 1 -or $evalAuthCalls.Count -ne 2){return $false}

    $scriptRequest=Get-CaptureTestFunction $authenticationAst 'Invoke-GeordiScriptRequest'
    $authenticated=Get-CaptureTestFunction $authenticationAst 'Invoke-GeordiAuthenticatedRequest'
    $httpsRequest=Get-CaptureTestFunction $authenticationAst 'Invoke-GeordiHttpsRequest'
    if(!$scriptRequest -or !$authenticated -or !$httpsRequest){return $false}
    $scriptCommands=Get-CaptureTestCommands $scriptRequest.Body;$authCommands=Get-CaptureTestCommands $authenticated.Body;$httpsCommands=Get-CaptureTestCommands $httpsRequest.Body
    $ingressRoute=@($scriptRequest.Body.FindAll({param($node)$node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -match "geordi\.localhost" -and $node.Clauses[0].Item1.Extent.Text -match '8443'},$true)).Count -gt 0
    $bearerAssignments=@($httpsRequest.Body.FindAll({param($node)$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$request.Headers.Authorization' -and
        $node.Right.Extent.Text -match 'AuthenticationHeaderValue' -and $node.Right.Extent.Text -match '\$token'},$true))
    $mutationRequest=@($lifecycle.Body.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-JsonRequest' -and $node.Extent.Text -match '/lifecycle-evaluations' -and $node.Extent.Text -match "'POST'"},$true)).Count -eq 1
    return ($scriptCommands -contains 'Invoke-GeordiAuthenticatedRequest' -and $ingressRoute -and
        $authCommands -contains 'Ensure-GeordiAuthenticationReady' -and $authCommands -contains 'Invoke-GeordiHttpsRequest' -and
        $httpsCommands -contains 'Ensure-GeordiAuthenticationReady' -and $bearerAssignments.Count -eq 1 -and $mutationRequest)
}
function Test-GeordiEvaluationAuthenticationContractCases {
    $evaluationPath=Join-Path $PSScriptRoot 'verify-alert-evaluation.ps1'
    $authenticationPath=Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1'
    $evaluation=[IO.File]::ReadAllText($evaluationPath);$authentication=[IO.File]::ReadAllText($authenticationPath)
    Assert-CaptureGeneration (Test-GeordiEvaluationAuthenticationContract $evaluation $authentication) `
        'evaluation protected API requests are not structurally bound to the trusted authenticated request path'
    $sourceMutations=@(
        @{name='comment-only-helper';source=$evaluation.Replace(". (Join-Path `$PSScriptRoot 'lib/GeordiAuthentication.ps1')", "# . (Join-Path `$PSScriptRoot 'lib/GeordiAuthentication.ps1')")},
        @{name='unused-helper';source=$evaluation.Replace('Invoke-GeordiScriptRequest -Uri $Uri -TimeoutSeconds $RequestTimeoutSeconds','$null = $Uri').Replace('Invoke-GeordiScriptRequest -Uri $Uri -Method $Method -TimeoutSeconds 15','$null = $Uri')},
        @{name='raw-protected-request';source=$evaluation.Replace('Invoke-GeordiScriptRequest -Uri $Uri -Method $Method -TimeoutSeconds 15','Invoke-WebRequest -Uri $Uri -Method $Method -TimeoutSec 15')},
        @{name='auth-name-string-only';source=$evaluation.Replace('Invoke-GeordiScriptRequest -Uri $Uri -TimeoutSeconds $RequestTimeoutSeconds',"'Invoke-GeordiScriptRequest -Uri `$Uri -TimeoutSeconds `$RequestTimeoutSeconds'")},
        @{name='anonymous-wrong-helper';source=$evaluation.Replace('Invoke-GeordiScriptRequest -Uri $Uri -TimeoutSeconds $RequestTimeoutSeconds','Invoke-GeordiAnonymousRequest -Uri $Uri -TimeoutSeconds $RequestTimeoutSeconds')},
        @{name='mutation-bypasses-auth-wrapper';source=$evaluation.Replace('Invoke-JsonRequest "$BackendBaseUrl/api/alert-policies/$([uri]::EscapeDataString($M18PolicyId))/lifecycle-evaluations" ''POST''','Invoke-WebRequest -Uri "$BackendBaseUrl/api/alert-policies/$([uri]::EscapeDataString($M18PolicyId))/lifecycle-evaluations" -Method Post')}
    )
    foreach($mutation in $sourceMutations){
        Assert-CaptureGeneration ($mutation.source -cne $evaluation) ("negative control mutation was not applied: " + $mutation.name)
        Assert-CaptureGeneration (!(Test-GeordiEvaluationAuthenticationContract $mutation.source $authentication)) `
            ("authentication contract accepted negative control: " + $mutation.name)
    }
    $authorizationAssignment='$request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(''Bearer'', $token)'
    $authStringOnly=$authentication.Replace($authorizationAssignment,"`$null = '$authorizationAssignment'")
    Assert-CaptureGeneration ($authStringOnly -cne $authentication) 'Authorization string-only mutation was not applied'
    Assert-CaptureGeneration (!(Test-GeordiEvaluationAuthenticationContract $evaluation $authStringOnly)) `
        'authentication contract accepted Authorization-like text without an executable header assignment'
    Write-Output 'evaluation_auth_contract=PASS identity=REGRESSION shared_script_request=true trusted_bearer=true protected_mutation=true negative_controls=6'
}
function New-GenerationTestRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-generation-test-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $manifest=[ordered]@{version=2;root=$root;runId='synthetic-run';startedUtc=[DateTimeOffset]::UtcNow.ToString('o');
        captureStartedUtc=[DateTimeOffset]::UtcNow.ToString('o');captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{}}
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 32 -Compress),[Text.UTF8Encoding]::new($false))
    return $root
}
function Remove-GenerationTestRoot([string] $Root) {
    if (Test-Path -LiteralPath $Root) {
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object { $_.IsReadOnly=$false }
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
}
function Read-GenerationManifest([string] $Root) { return [IO.File]::ReadAllText((Join-Path $Root 'manifest.json')) | ConvertFrom-Json -AsHashtable }

$script:mockAlive=@{}
$script:mockPid=31000
$script:nextFollowerOutputMode='stdout'
$script:mockStart={
    param($stdout,$stderr,$processRecord,$arguments,$target)
    $script:mockPid++
    $id=$script:mockPid
    $start=[DateTimeOffset]::UtcNow.ToString('o')
    $record=[ordered]@{id=$id;name='synthetic-docker';startUtc=$start;containerId=[string]$target.containerId;
        service=[string]$target.service;project=[string]$target.project;createdUtc=[string]$target.createdUtc}
    [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
    switch ($script:nextFollowerOutputMode) {
        'silent' { [IO.File]::WriteAllText($stdout,'',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false)) }
        'stderr' { [IO.File]::WriteAllText($stdout,'',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderr,"synthetic-stderr-$($target.service)`n",[Text.UTF8Encoding]::new($false)) }
        'stdout' { [IO.File]::WriteAllText($stdout,"synthetic-stdout-$($target.service)-$($target.containerId)`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false)) }
        default { throw 'Unknown synthetic follower output mode.' }
    }
    $script:mockAlive[[string]$id]=$true
    return [pscustomobject]@{id=$id;name='synthetic-docker';startUtc=$start}
}
$script:mockTestProcess={ param($record) return [bool]$script:mockAlive[[string]$record.id] }
$script:mockStopProcess={ param($record) $script:mockAlive[[string]$record.id]=$false }
function New-ContainerIdentity([string] $Id,[string] $Service) {
    return [pscustomobject]@{Id=$Id;Project='geordi';Service=$Service;WorkingDirectory=(Get-Location).Path;
        CreatedUtc=[DateTimeOffset]::UtcNow;Running=$true}
}
function Start-SyntheticGeneration([string] $Root,[string] $Service,[string] $ContainerId,[string] $HandoffId='', [string] $OutputMode='stdout') {
    $script:nextFollowerOutputMode=$OutputMode
    return Start-GeordiCaptureGeneration -CaptureRoot $Root -Service $Service `
        -ContainerIdentity (New-ContainerIdentity $ContainerId $Service) -DockerPath 'synthetic-docker' `
        -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker' -WorkingDirectory (Get-Location).Path `
        -HandoffId $HandoffId -StartFollower $script:mockStart
}
function Seal-SyntheticGeneration([string] $Root,[string] $Service,[string] $GenerationId) {
    return Seal-GeordiCaptureGeneration -CaptureRoot $Root -Service $Service -GenerationId $GenerationId `
        -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
}
function New-SealedGenerationChain([string] $Service,[string[]] $ContainerIds,[string] $OutputMode='stdout') {
    if($ContainerIds.Count -lt 1){throw 'Synthetic generation chain requires at least one container identity.'}
    $chainRoot=New-GenerationTestRoot
    $generationIds=[Collections.Generic.List[string]]::new()
    $handoffIds=[Collections.Generic.List[string]]::new()
    $active=Start-SyntheticGeneration $chainRoot $Service $ContainerIds[0] '' $OutputMode
    $generationIds.Add([string]$active)
    for($index=1;$index -lt $ContainerIds.Count;$index++){
        $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $chainRoot -Service $Service -Reason 'synthetic-chain' `
            -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
        $active=Start-SyntheticGeneration $chainRoot $Service $ContainerIds[$index] $handoff $OutputMode
        $handoffIds.Add([string]$handoff)
        $generationIds.Add([string]$active)
    }
    $null=Seal-SyntheticGeneration $chainRoot $Service $active
    return [pscustomobject]@{Root=$chainRoot;Generations=@($generationIds.ToArray());Handoffs=@($handoffIds.ToArray())}
}
function Copy-SyntheticHandoff([System.Collections.IDictionary] $Source) {
    $copy=[ordered]@{}
    foreach($key in $Source.Keys){$copy[$key]=$Source[$key]}
    return $copy
}

$root=New-GenerationTestRoot
try {
    switch ($Case) {
        'Identity' {
            $id=Start-SyntheticGeneration $root 'backend' ('a' * 64)
            $manifest=Read-GenerationManifest $root
            $record=Get-GeordiCaptureGenerationRecord $manifest 'backend' $id
            $process=Get-Content -LiteralPath $record.processRecordPath -Raw | ConvertFrom-Json
            Assert-CaptureGeneration ($record.containerId -ceq ('a' * 64) -and $record.logicalService -ceq 'backend') 'logical service/container identity was not recorded'
            Assert-CaptureGeneration ($process.containerId -ceq $record.containerId -and $process.service -ceq $record.logicalService) 'follower was not bound to exact container ID'
            Assert-CaptureGeneration ([IO.Path]::GetFileName($record.capturePath) -ceq $record.captureFileIdentity) 'capture file identity is ambiguous'
            $secondRejected=$false
            try { $null=Start-SyntheticGeneration $root 'backend' ('b' * 64) } catch { $secondRejected=$true }
            Assert-CaptureGeneration $secondRejected 'parallel active generation was accepted for one service'
            Write-Output 'capture_generation_identity=PASS exact_container=true follower_bound=true active_unique=true'
        }
        'Seal' {
            $id=Start-SyntheticGeneration $root 'backend' ('c' * 64)
            $sealed=Seal-SyntheticGeneration $root 'backend' $id
            $hash=(Get-FileHash -LiteralPath $sealed.capturePath -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-CaptureGeneration ($sealed.terminalStatus -ceq 'sealed' -and $sealed.sha256 -ceq $hash -and $sealed.byteCount -gt 0) 'seal metadata was incomplete'
            Assert-CaptureGeneration ((Get-Item -LiteralPath $sealed.capturePath -Force).IsReadOnly) 'sealed historical file is not immutable'
            $manifest=Read-GenerationManifest $root
            Assert-CaptureGeneration ($sealed.capturePath -in @($manifest.generationCaptures.backend)) 'sealed file was not registered to its logical channel'
            Write-Output 'capture_generation_seal=PASS immutable=true byte_count_hash=true'
        }
        'StreamsEmpty' {
            $id=Start-SyntheticGeneration $root 'oidc-fixture' ('c' * 64) '' 'silent'
            $sealed=Seal-SyntheticGeneration $root 'oidc-fixture' $id
            Assert-GeordiCaptureGenerationManifest (Read-GenerationManifest $root)
            $emptyHash='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            Assert-CaptureGeneration ($sealed.byteCount -eq 0 -and $sealed.sha256 -ceq $emptyHash -and
                $sealed.stderrByteCount -eq 0 -and $sealed.stderrSha256 -ceq $emptyHash -and
                (Test-Path -LiteralPath $sealed.capturePath -PathType Leaf) -and (Test-Path -LiteralPath $sealed.stderrCapturePath -PathType Leaf)) `
                'silent OIDC generation did not seal both existing empty streams with exact identities and hashes'            $emptyPathsRejected=$false
            try { $null=Get-GeordiCaptureGenerationPaths -Manifest (Read-GenerationManifest $root) -Service 'oidc-fixture' } catch { $emptyPathsRejected=$true }
            Assert-CaptureGeneration $emptyPathsRejected 'empty physical streams were incorrectly exposed to the credential scanner'
            Write-Output 'capture_generation_empty_streams=PASS silent_oidc=true stdout=0 stderr=0 existing_and_hashed=true scanner_sources=0'
        }
        'StreamsOutput' {
            foreach ($mode in @('stderr','stdout')) {
                $streamRoot=New-GenerationTestRoot
                try {
                    $containerId=if($mode -ceq 'stderr'){'d'*64}else{'e'*64}
                    $id=Start-SyntheticGeneration $streamRoot 'backend' $containerId '' $mode
                    $sealed=Seal-SyntheticGeneration $streamRoot 'backend' $id
                    Assert-GeordiCaptureGenerationManifest (Read-GenerationManifest $streamRoot)
                    $expectedPath=if($mode -ceq 'stderr'){[string]$sealed.stderrCapturePath}else{[string]$sealed.capturePath}
                    $unexpectedBytes=if($mode -ceq 'stderr'){[long]$sealed.byteCount}else{[long]$sealed.stderrByteCount}
                    $paths=@(Get-GeordiCaptureGenerationPaths -Manifest (Read-GenerationManifest $streamRoot) -Service backend)
                    Assert-CaptureGeneration ($paths.Count -eq 1 -and $paths[0] -ceq $expectedPath -and $unexpectedBytes -eq 0) `
                        "$mode-only generation did not include exactly its nonempty stream"
                } finally { Remove-GenerationTestRoot $streamRoot }
            }
            Write-Output 'capture_generation_single_stream=PASS stderr_only=true stdout_only=true independent_stream_hashes=true'
        }
        'StreamsIntegrity' {
            foreach ($missingStream in @('stdout','stderr')) {
                $missingRoot=New-GenerationTestRoot
                try {
                    $missingContainerId=if($missingStream -ceq 'stdout'){'f'*64}else{'a'*64}
                    $id=Start-SyntheticGeneration $missingRoot 'backend' $missingContainerId
                    $record=Get-GeordiCaptureGenerationRecord (Read-GenerationManifest $missingRoot) backend $id
                    $path=if($missingStream -ceq 'stdout'){[string]$record.capturePath}else{[string]$record.stderrCapturePath}
                    Remove-Item -LiteralPath $path -Force
                    $missingRejected=$false
                    try { $null=Seal-SyntheticGeneration $missingRoot backend $id } catch { $missingRejected=$true }
                    $manifest=Read-GenerationManifest $missingRoot
                    Assert-CaptureGeneration ($missingRejected -and (Get-GeordiCaptureGenerationRecord $manifest backend $id).terminalStatus -ceq 'sealing-failed') `
                        "missing $missingStream stream was accepted or not recorded fail-closed"
                } finally { Remove-GenerationTestRoot $missingRoot }
            }

            $truncatedId=Start-SyntheticGeneration $root backend ('b'*64)
            $truncated=Get-GeordiCaptureGenerationRecord (Read-GenerationManifest $root) backend $truncatedId
            [IO.File]::WriteAllBytes([string]$truncated.capturePath,[byte[]]@())
            $truncatedRejected=$false
            try { Assert-GeordiCaptureGenerationManifest (Read-GenerationManifest $root) } catch { $truncatedRejected=$true }
            Assert-CaptureGeneration $truncatedRejected 'truncated nonempty stream was accepted as a valid empty stream'

            $hashRoot=New-GenerationTestRoot
            try {
                $hashId=Start-SyntheticGeneration $hashRoot backend ('c'*64)
                $null=Seal-SyntheticGeneration $hashRoot backend $hashId
                $bad=Read-GenerationManifest $hashRoot
                (Get-GeordiCaptureGenerationRecord $bad backend $hashId).stderrSha256='0'*64
                $hashRejected=$false
                try { Assert-GeordiCaptureGenerationManifest $bad } catch { $hashRejected=$true }
                Assert-CaptureGeneration $hashRejected 'stderr hash mismatch was accepted'
            } finally { Remove-GenerationTestRoot $hashRoot }
            Write-Output 'capture_generation_stream_integrity=PASS missing_stdout=fail_closed missing_stderr=fail_closed truncation=fail_closed stdout_stderr_hashes=checked'
        }
        'StreamsPathUniqueness' {
            $chain=New-SealedGenerationChain -Service backend -ContainerIds @([string]::new([char]'1',64),[string]::new([char]'2',64)) -OutputMode silent
            try{
                $valid=Read-GenerationManifest $chain.Root
                Assert-GeordiCaptureGenerationManifest $valid
                $allPaths=@(foreach($record in @($valid.captureGenerations.backend)){@([string]$record.capturePath,[string]$record.stderrCapturePath)})
                $uniquePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach($path in $allPaths){[void]$uniquePaths.Add([IO.Path]::GetFullPath($path))}
                Assert-CaptureGeneration ($allPaths.Count -eq 4 -and $uniquePaths.Count -eq 4) 'valid two-generation stdout/stderr evidence did not use four distinct physical paths'

                $duplicateEmpty=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $valid -Depth 64 -Compress) -AsHashtable
                $first=Get-GeordiCaptureGenerationRecord $duplicateEmpty backend $chain.Generations[0]
                $second=Get-GeordiCaptureGenerationRecord $duplicateEmpty backend $chain.Generations[1]
                $second.stderrCapturePath=[string]$first.stderrCapturePath
                $second.stderrFileIdentity=[IO.Path]::GetFileName([string]$first.stderrCapturePath)
                $emptyPathRejected=$false
                try{Assert-GeordiCaptureGenerationManifest $duplicateEmpty}catch{$emptyPathRejected=$true}
                Assert-CaptureGeneration $emptyPathRejected 'duplicate zero-byte stderr path across generations was accepted'

                $crossStream=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $valid -Depth 64 -Compress) -AsHashtable
                $first=Get-GeordiCaptureGenerationRecord $crossStream backend $chain.Generations[0]
                $second=Get-GeordiCaptureGenerationRecord $crossStream backend $chain.Generations[1]
                $second.stderrCapturePath=[string]$first.capturePath
                $second.stderrFileIdentity=[IO.Path]::GetFileName([string]$first.capturePath)
                $second.stderrByteCount=[long]$first.byteCount
                $second.stderrSha256=[string]$first.sha256
                $crossStreamRejected=$false
                try{Assert-GeordiCaptureGenerationManifest $crossStream}catch{$crossStreamRejected=$true}
                Assert-CaptureGeneration $crossStreamRejected 'stderr path reused a different generation stdout path'
            }finally{Remove-GenerationTestRoot $chain.Root}

            $sameGeneration=New-SealedGenerationChain -Service backend -ContainerIds @([string]::new([char]'3',64)) -OutputMode silent
            try{
                $candidate=Read-GenerationManifest $sameGeneration.Root
                $record=Get-GeordiCaptureGenerationRecord $candidate backend $sameGeneration.Generations[0]
                $record.stderrCapturePath=[string]$record.capturePath
                $record.stderrFileIdentity=[string]$record.captureFileIdentity
                $sameStreamRejected=$false
                try{Assert-GeordiCaptureGenerationManifest $candidate}catch{$sameStreamRejected=$true}
                Assert-CaptureGeneration $sameStreamRejected 'same-generation stdout/stderr path alias was accepted'
            }finally{Remove-GenerationTestRoot $sameGeneration.Root}
            Write-Output 'capture_generation_stream_paths=PASS all_four_unique=true duplicate_empty_stderr=rejected cross_stream_collision=rejected same_generation_collision=rejected'
        }
        'HandoffTimestamps' {
            $oldId=Start-SyntheticGeneration $root backend ('4'*64)
            $handoffId=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service backend -Reason 'timestamp-validation' `
                -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
            $newId=Start-SyntheticGeneration $root backend ('5'*64) -HandoffId $handoffId
            $null=Seal-SyntheticGeneration $root backend $newId
            $base=Read-GenerationManifest $root
            Assert-GeordiCaptureGenerationManifest $base
            $baseOld=Get-GeordiCaptureGenerationRecord $base backend $oldId
            $baseNew=Get-GeordiCaptureGenerationRecord $base backend $newId
            $baseHandoff=$base.captureHandoffs[$handoffId]
            $oldStartInstant=ConvertTo-GeordiCaptureUtcInstant $baseOld.captureStartedUtc oldStart
            $oldEndInstant=ConvertTo-GeordiCaptureUtcInstant $baseOld.captureEndedUtc oldEnd
            $handoffStartInstant=ConvertTo-GeordiCaptureUtcInstant $baseHandoff.startedUtc handoffStart
            $newStartInstant=ConvertTo-GeordiCaptureUtcInstant $baseNew.captureStartedUtc newStart
            $completedInstant=ConvertTo-GeordiCaptureUtcInstant $baseHandoff.completedUtc completed
            Assert-CaptureGeneration ($oldStartInstant.UtcTicks -le $handoffStartInstant.UtcTicks -and
                $handoffStartInstant.UtcTicks -le $oldEndInstant.UtcTicks -and $oldEndInstant.UtcTicks -le $newStartInstant.UtcTicks -and
                $handoffStartInstant.UtcTicks -le $newStartInstant.UtcTicks -and $newStartInstant.UtcTicks -le $completedInstant.UtcTicks) `
                'active-generation handoff chronology does not follow old-start <= handoff-start <= old-end <= new-start <= completion'

            $cloneManifest={
                param($source)
                return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $source -Depth 64 -Compress) -AsHashtable
            }.GetNewClosure()
            $setTimeline={
                param($candidate,[string]$oldEnd,[string]$newStart,[long]$declared,[long]$maximum,
                    [string]$handoffStart,[string]$completed,[string]$recordedOld,[string]$recordedNew)
                $oldRecord=Get-GeordiCaptureGenerationRecord $candidate backend $oldId
                $newRecord=Get-GeordiCaptureGenerationRecord $candidate backend $newId
                $event=$candidate.captureHandoffs[$handoffId]
                $oldRecord.captureStartedUtc='2026-10-01T09:59:00.0000000Z'
                $oldRecord.captureEndedUtc=$oldEnd
                $newRecord.captureStartedUtc=$newStart
                $newRecord.captureEndedUtc='2026-10-01T10:01:00.0000000Z'
                $event.startedUtc=$handoffStart
                $event.oldCaptureEndedUtc=$recordedOld
                $event.newCaptureStartedUtc=$recordedNew
                $event.completedUtc=$completed
                $event.gapDurationMilliseconds=$declared
                $event.maximumGapMilliseconds=$maximum
                $event.status='complete'
                $event.gapState='bounded-transition'
            }.GetNewClosure()
            $assertValid={
                param([string]$name,[string]$oldEnd,[string]$newStart,[long]$declared,[long]$maximum,
                    [string]$handoffStart,[string]$completed,[string]$recordedOld,[string]$recordedNew)
                $candidate=& $cloneManifest $base
                & $setTimeline $candidate $oldEnd $newStart $declared $maximum $handoffStart $completed $recordedOld $recordedNew
                Assert-GeordiCaptureGenerationManifest $candidate
            }.GetNewClosure()
            $assertInvalid={
                param([string]$name,[scriptblock]$mutate)
                $candidate=& $cloneManifest $base
                & $setTimeline $candidate '2026-10-01T10:00:00.0000000Z' '2026-10-01T10:00:00.8500000Z' 850 1000 `
                    '2026-10-01T09:59:30.0000000Z' '2026-10-01T10:00:01.0000000Z' `
                    '2026-10-01T10:00:00.0000000Z' '2026-10-01T10:00:00.8500000Z'
                & $mutate $candidate
                $rejected=$false
                try { Assert-GeordiCaptureGenerationManifest $candidate } catch { $rejected=$true }
                Assert-CaptureGeneration $rejected ("invalid handoff timestamp case was accepted: " + $name)
            }.GetNewClosure()

            & $assertValid 'zero-gap' '2026-10-01T10:00:00.0000000Z' '2026-10-01T10:00:00.0000000Z' 0 1000 `
                '2026-10-01T09:59:30.0000000Z' '2026-10-01T10:00:01.0000000Z' `
                '2026-10-01T10:00:00.0000000Z' '2026-10-01T10:00:00.0000000Z'
            & $assertValid 'bounded-gap' '2026-10-01T10:00:00.0000000Z' '2026-10-01T10:00:00.8500000Z' 850 1000 `
                '2026-10-01T09:59:30.0000000Z' '2026-10-01T10:00:01.0000000Z' `
                '2026-10-01T10:00:00.0000000Z' '2026-10-01T10:00:00.8500000Z'
            & $assertValid 'offset-equivalent' '2026-10-01T10:00:00.0000000Z' '2026-10-01T12:00:00.8500000+02:00' 850 1000 `
                '2026-10-01T11:59:30.0000000+02:00' '2026-10-01T12:00:01.0000000+02:00' `
                '2026-10-01T12:00:00.0000000+02:00' '2026-10-01T10:00:00.8500000Z'
            & $assertValid 'already-sealed-generation' '2026-10-01T10:00:00.0000000Z' '2026-10-01T10:00:00.8500000Z' 850 1000 `
                '2026-10-01T10:00:00.2000000Z' '2026-10-01T10:00:01.0000000Z' `
                '2026-10-01T10:00:00.0000000Z' '2026-10-01T10:00:00.8500000Z'

            & $assertInvalid 'handoff-before-old-generation-start' { param($m) $m.captureHandoffs[$handoffId].startedUtc='2026-10-01T09:58:59.0000000Z' }
            & $assertInvalid 'handoff-after-new-generation-start' { param($m) $m.captureHandoffs[$handoffId].startedUtc='2026-10-01T10:00:00.9000000Z' }
            & $assertInvalid 'declared-zero-gap-mismatch' { param($m) $m.captureHandoffs[$handoffId].gapDurationMilliseconds=0 }
            & $assertInvalid 'declared-positive-gap-mismatch' { param($m) $m.captureHandoffs[$handoffId].gapDurationMilliseconds=50 }
            & $assertInvalid 'actual-gap-over-maximum' { param($m) $m.captureHandoffs[$handoffId].maximumGapMilliseconds=500 }
            & $assertInvalid 'timestamp-only-source-tamper' { param($m) (Get-GeordiCaptureGenerationRecord $m backend $newId).captureStartedUtc='2026-10-01T10:00:00.8510000Z' }
            & $assertInvalid 'unsupported-overlap' {
                param($m)
                (Get-GeordiCaptureGenerationRecord $m backend $oldId).captureEndedUtc='2026-10-01T10:00:00.8500000Z'
                $m.captureHandoffs[$handoffId].oldCaptureEndedUtc='2026-10-01T10:00:00.8500000Z'
                (Get-GeordiCaptureGenerationRecord $m backend $newId).captureStartedUtc='2026-10-01T10:00:00.0000000Z'
                $m.captureHandoffs[$handoffId].newCaptureStartedUtc='2026-10-01T10:00:00.0000000Z'
                $m.captureHandoffs[$handoffId].gapDurationMilliseconds=0
            }
            & $assertInvalid 'reversed-handoff' { param($m) $m.captureHandoffs[$handoffId].startedUtc='2026-10-01T10:00:02.0000000Z' }
            & $assertInvalid 'completion-before-new-generation' { param($m) $m.captureHandoffs[$handoffId].completedUtc='2026-10-01T10:00:00.5000000Z' }
            & $assertInvalid 'source-record-mismatch' { param($m) $m.captureHandoffs[$handoffId].oldCaptureEndedUtc='2026-10-01T09:59:59.9990000Z' }
            & $assertInvalid 'malformed-timestamp' { param($m) (Get-GeordiCaptureGenerationRecord $m backend $oldId).captureEndedUtc='not-a-timestamp' }
            & $assertInvalid 'missing-timestamp' { param($m) $m.captureHandoffs[$handoffId].completedUtc='' }
            Write-Output 'capture_generation_handoff_timestamps=PASS active_and_already_sealed_chronology=true recomputed_gap=true normalized_offsets=true chronology_and_identity_fail_closed=true'
        }
        'AuthContract' {
            Test-GeordiEvaluationAuthenticationContractCases        }
        'Boundaries' {
            $root=New-GenerationTestRoot
            $sourceFacts=@(
                @{file='verify-alert-evaluation.ps1';tokens=@();absent=@('docker compose','Start-GeordiCaptureGeneration')},
                @{file='verify-alert-lifecycle.ps1';tokens=@("-Phase m10-reset -Services backend", 'docker compose --project-directory $Root rm -sf backend', 'Invoke-GeordiM10BackendControlledReplacement')},
                @{file='lib/GeordiM10BackendReplacement.ps1';tokens=@("@('rm','-sf','backend')", "@('up','-d','--force-recreate','backend')", 'Invoke-GeordiCaptureHandoffReplacement')},
                @{file='verify-notification-delivery.ps1';tokens=@("-Phase m11-reset -Services backend,victoriametrics -SkipLogSnapshot", "@('rm', '-sf', 'backend', 'victoriametrics')", "@('up', '-d', '--no-deps', '--force-recreate', 'victoriametrics', 'backend')", 'Invoke-M11BackendGenerationReplacement')},
                @{file='verify-alert-scheduling.ps1';tokens=@('-Phase m12-reset -Services $legacyCaptureServices', "'rm','-sf','backend','m12-burn-demo','victoriametrics'", 'Invoke-GeordiM12CollectorControlledReplacement', 'Invoke-GeordiM12BackendGenerationReplacement')},
                @{file='lib/GeordiM12CollectorReplacement.ps1';tokens=@('Get-GeordiM12CollectorReplacementArguments', "'up','-d','--no-deps','--force-recreate','otel-collector'", 'Invoke-GeordiCaptureHandoffReplacement')},
                @{file='lib/GeordiM12BackendReplacement.ps1';tokens=@('Get-GeordiM12BackendRecreationArguments', "'up','-d','--no-deps','--force-recreate','backend'", 'Invoke-GeordiCaptureHandoffReplacement')},
                @{file='verify-alert-routing.ps1';tokens=@("-Phase m13-reset -Services backend,victoriametrics,otel-collector,burn-demo,webhook-receiver-a,webhook-receiver-b", "'rm', '-sf', 'backend', 'victoriametrics', 'webhook-receiver-a', 'webhook-receiver-b'", "'up', '-d', '--force-recreate', 'victoriametrics', 'otel-collector', 'backend', 'burn-demo', 'webhook-receiver-a', 'webhook-receiver-b'")},
                @{file='verify-alert-history.ps1';tokens=@("-Services @('backend','otel-collector')", 'Begin-GeordiCaptureHandoff', 'Invoke-GeordiCaptureHandoffReplacement')}
            )
            foreach($fact in $sourceFacts){
                $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot ([string]$fact.file)) -Raw
                foreach($token in $fact.tokens){Assert-CaptureGeneration ($source.Contains([string]$token)) ("authoritative lifecycle source marker missing: " + $fact.file)}
                if($fact.Contains('absent')){foreach($token in @($fact['absent'])){if($token){Assert-CaptureGeneration (!$source.Contains([string]$token)) ("unexpected lifecycle mutation marker in " + $fact.file)}}}
            }

            $script:mockAlive=@{}
            $script:mockPid=41000
            $serviceState=[ordered]@{backend=('1'*64);'otel-collector'=([guid]::NewGuid().ToString('N')+'00000000000000000000000000000000').Substring(0,64);frontend=('3'*64)}
            $originals=@{}
            foreach($service in @('backend','otel-collector','frontend')){
                $generation=Start-SyntheticGeneration $root $service $serviceState[$service]
                $originals[$service]=[Collections.Generic.List[object]]::new()
                $originals[$service].Add($generation)
            }
            $stageSequence=@(
                @{stage='M10-reset';service='backend'},
                @{stage='M11-reset';service='backend'},
                @{stage='M12-reset';service='otel-collector'},
                @{stage='M12-reset';service='backend'},
                @{stage='M12-scheduler-enable';service='backend'},
                @{stage='M13-reset';service='backend'},
                @{stage='M13-reset';service='otel-collector'}
            )
            $replacementOperations=[Collections.Generic.List[string]]::new()
            $nextContainerOrdinal=10
            foreach($operation in $stageSequence){
                $service=[string]$operation.service
                $stage=[string]$operation.stage
                $oldId=[string]$originals[$service][-1]
                $before=Read-GenerationManifest $root
                $oldRecord=Get-GeordiCaptureGenerationRecord $before $service $oldId
                $oldHash=(Get-FileHash -LiteralPath ([string]$oldRecord.capturePath) -Algorithm SHA256).Hash
                $oldProcess=Get-Content -LiteralPath ([string]$oldRecord.processRecordPath) -Raw | ConvertFrom-Json -AsHashtable
                Assert-CaptureGeneration ([string]$oldProcess.containerId -ceq [string]$oldRecord.containerId) ("$($operation.stage) old follower is not bound to the captured container")
                $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service $service -Reason ([string]$operation.stage) `
                    -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
                $sealed=Get-GeordiCaptureGenerationRecord (Read-GenerationManifest $root) $service $oldId
                Assert-CaptureGeneration ($sealed.terminalStatus -ceq 'sealed' -and (Get-Item -LiteralPath $sealed.capturePath -Force).IsReadOnly) `
                    ("$($operation.stage) did not seal and protect its old generation before replacement")
                Assert-CaptureGeneration ((Get-FileHash -LiteralPath $sealed.capturePath -Algorithm SHA256).Hash -ceq $oldHash) `
                    ("$($operation.stage) changed historical old-generation evidence before replacement")
                $nextContainerOrdinal++
                $newContainerId=$nextContainerOrdinal.ToString('x64')
                $replaceAction={
                    $latest=Read-GenerationManifest $root
                    $latestOld=Get-GeordiCaptureGenerationRecord $latest $service $oldId
                    if($latestOld.terminalStatus -cne 'sealed'){throw 'synthetic replace called before old seal'}
                    $replacementOperations.Add($stage + ':' + $service)
                }.GetNewClosure()
                $identityProvider={param($name) New-ContainerIdentity $newContainerId $name}.GetNewClosure()
                $newGeneration=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $root -Service $service -HandoffId $handoff `
                    -RepositoryRoot (Get-Location).Path -Replace $replaceAction -GetContainerIdentity $identityProvider -StartFollower $script:mockStart
                $after=Read-GenerationManifest $root
                $newRecord=Get-GeordiCaptureGenerationRecord $after $service $newGeneration
                $newProcess=Get-Content -LiteralPath ([string]$newRecord.processRecordPath) -Raw | ConvertFrom-Json -AsHashtable
                $event=$after.captureHandoffs[$handoff]
                Assert-CaptureGeneration ([string]$newRecord.containerId -ceq $newContainerId -and [string]$newProcess.containerId -ceq $newContainerId) `
                    ("$($operation.stage) new follower is not bound to the exact new container")
                Assert-CaptureGeneration ($event.status -ceq 'complete' -and $event.oldGenerationId -ceq $oldId -and
                    $event.newGenerationId -ceq $newGeneration -and $event.oldContainerId -ceq $oldRecord.containerId -and
                    $event.newContainerId -ceq $newContainerId) ("$($operation.stage) replacement/handoff manifest linkage is incorrect")
                Assert-CaptureGeneration ((Get-FileHash -LiteralPath $sealed.capturePath -Algorithm SHA256).Hash -ceq $oldHash) `
                    ("$($operation.stage) replacement modified immutable historical evidence")
                $originals[$service].Add([string]$newGeneration)
            }
            foreach($service in @('backend','otel-collector','frontend')){
                $active=Get-GeordiActiveCaptureGenerationRecord (Read-GenerationManifest $root) $service
                $null=Seal-SyntheticGeneration $root $service ([string]$active.generationId)
            }
            $finalManifest=Read-GenerationManifest $root
            Assert-GeordiCaptureGenerationManifest $finalManifest
            foreach($service in @('backend','otel-collector','frontend')){
                $records=@($finalManifest.captureGenerations[$service])
                Assert-CaptureGeneration ($records.Count -eq $originals[$service].Count) ("$service generation was silently omitted")
                for($index=1;$index -lt $records.Count;$index++){
                    $record=$records[$index]
                    $prior=$records[$index-1]
                    $event=$finalManifest.captureHandoffs[[string]$record.handoffId]
                    Assert-CaptureGeneration ($event.oldGenerationId -ceq $prior.generationId -and $event.newGenerationId -ceq $record.generationId) `
                        ("$service generation order skipped or mislinked a boundary")
                }
                $scannerPaths=@(Get-GeordiCaptureGenerationPaths -Manifest $finalManifest -Service $service)
                Assert-CaptureGeneration ($scannerPaths.Count -eq $records.Count) ("$service scanner inventory omitted a nonempty generation")
            }
            Assert-CaptureGeneration ($finalManifest.captureGenerations.backend.Count -eq 6 -and
                $finalManifest.captureGenerations['otel-collector'].Count -eq 3 -and
                $finalManifest.captureGenerations.frontend.Count -eq 1 -and
                $replacementOperations.Count -eq $stageSequence.Count) 'pre-M14 service-specific recreate/reuse classification drifted'
            Write-Output 'pre_m14_generation_boundaries=PASS stages=M9-M10-M11-M12-M13-M14-boundary backend_recreated=M10,M11,M12-reset,M12-enable,M13 collector_recreated=M12,M13 frontend=reused vm=snapshot-only'

            $invalidBase=Read-GenerationManifest $root
            $clone={param($m) ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $m -Depth 64 -Compress) -AsHashtable}.GetNewClosure()
            $expectRejected={param([string]$name,$candidate)
                $rejected=$false;try{Assert-GeordiCaptureGenerationManifest $candidate}catch{$rejected=$true}
                Assert-CaptureGeneration $rejected ("pre-M14 fail-closed case was accepted: "+$name)
            }.GetNewClosure()

            $missingGeneration=& $clone $invalidBase
            $missingGeneration.captureGenerations.backend=@($missingGeneration.captureGenerations.backend | Select-Object -SkipLast 1)
            & $expectRejected 'missing-generation' $missingGeneration
            $missingHandoff=& $clone $invalidBase
            $firstHandoff=[string]$missingHandoff.captureGenerations.backend[1].handoffId
            $missingHandoff.captureHandoffs.Remove($firstHandoff)
            & $expectRejected 'missing-handoff' $missingHandoff
            $badOrder=& $clone $invalidBase
            [array]::Reverse($badOrder.captureGenerations.backend)
            & $expectRejected 'broken-generation-order' $badOrder
            $badTimestamp=& $clone $invalidBase
            $firstEvent=$badTimestamp.captureHandoffs[[string]$badTimestamp.captureGenerations.backend[1].handoffId]
            $firstEvent.newCaptureStartedUtc=([DateTimeOffset]$firstEvent.newCaptureStartedUtc).AddMilliseconds(1).ToString('o')
            & $expectRejected 'inconsistent-handoff-timestamp' $badTimestamp
            $missingCapture=& $clone $invalidBase
            $lastBackend=Get-GeordiCaptureGenerationRecord $missingCapture backend ([string]$missingCapture.captureGenerations.backend[-1].generationId)
            $missingCapture.generationCaptures.backend=@($missingCapture.generationCaptures.backend | Where-Object { $_ -cne $lastBackend.capturePath })
            & $expectRejected 'missing-generation-capture' $missingCapture

            $unsealedRoot=New-GenerationTestRoot
            try{
                $unsealedId=Start-SyntheticGeneration $unsealedRoot backend ('a'*64)
                $unsealedHandoff=Begin-GeordiCaptureHandoff -CaptureRoot $unsealedRoot -Service backend -Reason 'negative-unsealed'
                $unsealedManifest=Read-GenerationManifest $unsealedRoot
                $unsealedManifest.captureHandoffs[$unsealedHandoff].status='in_progress'
                Write-GeordiM19ManifestAtomic -Path (Join-Path $unsealedRoot 'manifest.json') -Manifest $unsealedManifest
                $replaceCalled=$false;$unsealedRejected=$false
                try{Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $unsealedRoot -Service backend -HandoffId $unsealedHandoff `
                    -RepositoryRoot (Get-Location).Path -Replace {$replaceCalled=$true} `
                    -GetContainerIdentity {param($service) New-ContainerIdentity ('b'*64) $service} -StartFollower $script:mockStart}catch{$unsealedRejected=$true}
                Assert-CaptureGeneration ($unsealedRejected -and !$replaceCalled) 'replacement ran without a sealed handoff authorization'
            }finally{Remove-GenerationTestRoot $unsealedRoot}

            $mismatchRoot=New-GenerationTestRoot
            try{
                $mismatchId=Start-SyntheticGeneration $mismatchRoot backend ('c'*64)
                $mismatchRecord=Get-GeordiCaptureGenerationRecord (Read-GenerationManifest $mismatchRoot) backend $mismatchId
                $disk=Get-Content -LiteralPath $mismatchRecord.processRecordPath -Raw | ConvertFrom-Json -AsHashtable
                $disk.containerId='d'*64
                [IO.File]::WriteAllText($mismatchRecord.processRecordPath,(ConvertTo-Json -InputObject $disk -Compress),[Text.UTF8Encoding]::new($false))
                $mismatchRejected=$false
                try{Begin-GeordiCaptureHandoff -CaptureRoot $mismatchRoot -Service backend -Reason 'negative-follower-binding' -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess|Out-Null}catch{$mismatchRejected=$true}
                Assert-CaptureGeneration $mismatchRejected 'old follower container mismatch was accepted'
            }finally{Remove-GenerationTestRoot $mismatchRoot}

            $noGenerationRoot=New-GenerationTestRoot
            try{
                $noGenerationId=Start-SyntheticGeneration $noGenerationRoot backend ('e'*64)
                $noGenerationHandoff=Begin-GeordiCaptureHandoff -CaptureRoot $noGenerationRoot -Service backend -Reason 'negative-missing-new-generation' -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
                $script:mockNoGenerationReplaceCalled=$false;$noGenerationRejected=$false
                try{Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $noGenerationRoot -Service backend -HandoffId $noGenerationHandoff `
                    -RepositoryRoot (Get-Location).Path -Replace {$script:mockNoGenerationReplaceCalled=$true} `
                    -GetContainerIdentity {throw 'synthetic new identity unavailable'} -StartFollower $script:mockStart}catch{$noGenerationRejected=$true}
                $state=Read-GenerationManifest $noGenerationRoot
                Assert-CaptureGeneration ($noGenerationRejected -and $script:mockNoGenerationReplaceCalled -and $state.captureHandoffs[$noGenerationHandoff].status -ceq 'incomplete-replacement' -and
                    @($state.captureGenerations.backend).Count -eq 1) 'replacement without registered new generation was not rejected'
            }finally{Remove-GenerationTestRoot $noGenerationRoot;Remove-Variable -Name mockNoGenerationReplaceCalled -Scope Script -ErrorAction SilentlyContinue}

            $sameContainerRoot=New-GenerationTestRoot
            try{
                $sameId=Start-SyntheticGeneration $sameContainerRoot backend ('f'*64)
                $sameHandoff=Begin-GeordiCaptureHandoff -CaptureRoot $sameContainerRoot -Service backend -Reason 'negative-same-container' -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
                $sameRejected=$false
                try{Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $sameContainerRoot -Service backend -HandoffId $sameHandoff `
                    -RepositoryRoot (Get-Location).Path -Replace {} -GetContainerIdentity {param($service) New-ContainerIdentity ('f'*64) $service} -StartFollower $script:mockStart}catch{$sameRejected=$true}
                $sameState=Read-GenerationManifest $sameContainerRoot
                Assert-CaptureGeneration ($sameRejected -and $sameState.captureHandoffs[$sameHandoff].status -ceq 'incomplete-new-generation' -and
                    @($sameState.captureGenerations.backend).Count -eq 2) 'new generation registered with the old container ID was accepted'
            }finally{Remove-GenerationTestRoot $sameContainerRoot}

            $wrongFollowerRoot=New-GenerationTestRoot
            try{
                $wrongId=Start-SyntheticGeneration $wrongFollowerRoot backend ('a'*64)
                $wrongHandoff=Begin-GeordiCaptureHandoff -CaptureRoot $wrongFollowerRoot -Service backend -Reason 'negative-wrong-new-follower' -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
                $badFollower={param($stdout,$stderr,$processRecord,$arguments,$target)
                    $script:mockPid++;$start=[DateTimeOffset]::UtcNow.ToString('o');$badContainer='b'*64
                    [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject @{id=$script:mockPid;name='synthetic-docker';startUtc=$start;containerId=$badContainer;service=$target.service;project=$target.project;createdUtc=$target.createdUtc} -Compress),[Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText($stdout,'wrong-follower');[IO.File]::WriteAllText($stderr,'');$script:mockAlive[[string]$script:mockPid]=$true
                    return [pscustomobject]@{id=$script:mockPid;name='synthetic-docker';startUtc=$start}
                }.GetNewClosure()
                $wrongRejected=$false
                try{Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $wrongFollowerRoot -Service backend -HandoffId $wrongHandoff `
                    -RepositoryRoot (Get-Location).Path -Replace {} -GetContainerIdentity {param($service) New-ContainerIdentity ('c'*64) $service} -StartFollower $badFollower}catch{$wrongRejected=$true}
                $wrongState=Read-GenerationManifest $wrongFollowerRoot
                Assert-CaptureGeneration ($wrongRejected -and @($wrongState.captureGenerations.backend | Where-Object terminalStatus -ceq 'incomplete-start').Count -eq 1) `
                    'new follower bound to the wrong container was accepted'
            }finally{Remove-GenerationTestRoot $wrongFollowerRoot}
            $oldest=Get-GeordiCaptureGenerationRecord $finalManifest backend ([string]$finalManifest.captureGenerations.backend[0].generationId)
            $oldestHash=(Get-FileHash -LiteralPath $oldest.capturePath -Algorithm SHA256).Hash
            $oldestItem=Get-Item -LiteralPath $oldest.capturePath -Force
            $overwriteRejected=$false
            try{[IO.File]::WriteAllText($oldest.capturePath,'synthetic-overwrite-attempt',[Text.UTF8Encoding]::new($false))}catch{$overwriteRejected=$true}
            Assert-CaptureGeneration ($overwriteRejected -and $oldestItem.IsReadOnly -and
                (Get-FileHash -LiteralPath $oldest.capturePath -Algorithm SHA256).Hash -ceq $oldestHash) 'historical generation evidence was not immutable'
            Write-Output 'pre_m14_generation_fail_closed=PASS unsealed=reject follower_mismatch=reject missing_new_generation=reject same_container=reject wrong_new_follower=reject order=reject missing_capture=reject missing_handoff=reject timestamp_mismatch=reject historical_immutable=true'
        }
        'Replacement' {
            $oldId=Start-SyntheticGeneration $root 'otel-collector' ('d' * 64)
            $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service 'otel-collector' -Reason 'synthetic-replacement' `
                -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
            $replacementId=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $root -Service 'otel-collector' -HandoffId $handoff `
                -RepositoryRoot (Get-Location).Path -StartFollower $script:mockStart -GetContainerIdentity { param($service) New-ContainerIdentity ('e' * 64) $service } -Replace { $script:mockReplacementCalled=$true }
            $new=Seal-SyntheticGeneration $root 'otel-collector' $replacementId
            $manifest=Read-GenerationManifest $root
            Assert-GeordiCaptureGenerationManifest $manifest
            $event=$manifest.captureHandoffs[$handoff]
            Assert-CaptureGeneration ($event.oldGenerationId -ceq $oldId -and $event.newGenerationId -ceq $replacementId) 'handoff order or generation identities changed'
            Assert-CaptureGeneration ($event.oldContainerId -ceq ('d' * 64) -and $event.newContainerId -ceq ('e' * 64)) 'replacement follower attribution is wrong'
            Assert-CaptureGeneration ($event.gapState -ceq 'bounded-transition' -and $event.maximumGapMilliseconds -gt 0) 'bounded transition was not represented'
            Assert-CaptureGeneration ($manifest.generationCaptures.otel.Count -eq 2 -and $manifest.generationCaptures.collector.Count -eq 2) 'multiple generations were not kept as one logical channel path list'
            Write-Output 'capture_generation_replacement=PASS old_sealed=true new_id_distinct=true exact_binding=true bounded_gap=true'
        }
        'OutputCardinality' {
            $oldId=Start-SyntheticGeneration $root 'backend' ('d' * 64)
            $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service backend -Reason 'synthetic-noisy-success' `
                -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
            $returned=@(Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $root -Service backend -HandoffId $handoff `
                -RepositoryRoot (Get-Location).Path -StartFollower $script:mockStart `
                -GetContainerIdentity { param($service) New-ContainerIdentity ('e' * 64) $service } `
                -Replace { Write-Output 'compose-rm-output'; Write-Output 'compose-up-output' })
            Assert-CaptureGeneration ($returned.Count -eq 1 -and $returned[0] -is [string] -and
                [string]$returned[0] -match '^[0-9a-f]{32}$' -and
                $returned -notcontains 'compose-rm-output' -and $returned -notcontains 'compose-up-output') `
                'noisy Replace success output escaped or contaminated the generation ID result'
            $newId=[string]$returned[0]
            $new=Seal-SyntheticGeneration $root backend $newId
            Assert-GeordiCaptureGenerationManifest (Read-GenerationManifest $root)
            Assert-CaptureGeneration ($new.containerId -ceq ('e' * 64)) 'noisy Replace did not return the replacement generation identity'
            Write-Output 'capture_generation_output_cardinality=PASS objects=1 result=generation-id-only noisy-output=discarded'
        }
        'NoisyReplacementFailure' {
            $oldId=Start-SyntheticGeneration $root 'backend' ('d' * 64)
            $old=Seal-SyntheticGeneration $root backend $oldId
            $oldHash=(Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash
            $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service backend -Reason 'synthetic-noisy-failure'
            $observed=[Collections.Generic.List[object]]::new();$failureMessage=''
            try {
                Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $root -Service backend -HandoffId $handoff `
                    -RepositoryRoot (Get-Location).Path -StartFollower $script:mockStart `
                    -GetContainerIdentity { param($service) New-ContainerIdentity ('e' * 64) $service } `
                    -Replace { Write-Output 'compose-before-failure-a'; Write-Output 'compose-before-failure-b'; throw 'synthetic noisy replacement failure' } |
                    ForEach-Object { $observed.Add($_) }
            } catch { $failureMessage=$_.Exception.Message }
            $manifest=Read-GenerationManifest $root
            Assert-CaptureGeneration ($observed.Count -eq 0 -and $failureMessage -match 'synthetic noisy replacement failure' -and
                $manifest.captureHandoffs[$handoff].status -ceq 'incomplete-replacement' -and
                @($manifest.captureGenerations.backend).Count -eq 1 -and
                (Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash -ceq $oldHash) `
                'noisy replacement failure leaked output, lost its original error, completed the handoff, or changed sealed evidence'
            Write-Output 'capture_generation_noisy_failure=PASS output=discarded exception=propagated handoff=incomplete-replacement history=immutable'
        }
        'Failures' {
            $id=Start-SyntheticGeneration $root 'backend' ('f' * 64)
            $manifest=Read-GenerationManifest $root
            $record=Get-GeordiCaptureGenerationRecord $manifest 'backend' $id
            $disk=Get-Content -LiteralPath $record.processRecordPath -Raw | ConvertFrom-Json -AsHashtable
            $disk.containerId='0' * 64
            [IO.File]::WriteAllText($record.processRecordPath,(ConvertTo-Json -InputObject $disk -Compress),[Text.UTF8Encoding]::new($false))
            $rejected=$false
            try { $null=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service 'backend' -Reason 'identity-mismatch' -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess } catch { $rejected=$true }
            Assert-CaptureGeneration $rejected 'mismatched follower/container identity was accepted'
            Assert-CaptureGeneration ($script:mockAlive[[string]$record.followerProcess.id]) 'identity mismatch stopped an unproven follower'
            $manifest=Read-GenerationManifest $root
            $failedHandoff=@($manifest.captureHandoffs.Values | Where-Object logicalService -ceq 'backend')[0]
            Assert-CaptureGeneration ($failedHandoff.status -ceq 'incomplete-old-seal') 'old seal failure did not leave an explicit incomplete handoff'

            $sealRoot=New-GenerationTestRoot
            try {
                $sealId=Start-SyntheticGeneration $sealRoot 'otel-collector' ('8' * 64)
                $sealRecord=Get-GeordiCaptureGenerationRecord (Read-GenerationManifest $sealRoot) 'otel-collector' $sealId
                $sealFailed=$false
                try { $null=Begin-GeordiCaptureHandoff -CaptureRoot $sealRoot -Service 'otel-collector' -Reason 'synthetic-seal-failure' `
                    -TestProcessIdentity { param($processRecord) return $false } -StopProcess $script:mockStopProcess } catch { $sealFailed=$true }
                $sealManifest=Read-GenerationManifest $sealRoot
                $sealHandoff=@($sealManifest.captureHandoffs.Values)[0]
                $sealGeneration=Get-GeordiCaptureGenerationRecord $sealManifest 'otel-collector' $sealId
                Assert-CaptureGeneration ($sealFailed -and $sealHandoff.status -ceq 'incomplete-old-seal' -and
                    $sealGeneration.terminalStatus -ceq 'sealing-failed' -and $script:mockAlive[[string]$sealRecord.followerProcess.id]) `
                    'old generation sealing failure was not recorded fail closed or stopped an unproven process'
            } finally { Remove-GenerationTestRoot $sealRoot }

            $replacementRoot=New-GenerationTestRoot
            try {
                $oldId=Start-SyntheticGeneration $replacementRoot 'backend' ('9' * 64)
                $old=Seal-SyntheticGeneration $replacementRoot 'backend' $oldId
                $oldHash=(Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash
                $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $replacementRoot -Service backend -Reason 'replacement-failure'
                $replacementFailed=$false
                try { $null=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $replacementRoot -Service backend -HandoffId $handoff `
                    -RepositoryRoot (Get-Location).Path -Replace { throw 'synthetic replacement failure' } `
                    -GetContainerIdentity { param($service) New-ContainerIdentity ('a' * 64) $service } -StartFollower $script:mockStart } catch { $replacementFailed=$true }
                $replacementManifest=Read-GenerationManifest $replacementRoot
                Assert-CaptureGeneration ($replacementFailed -and $replacementManifest.captureHandoffs[$handoff].status -ceq 'incomplete-replacement' -and
                    (Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash -ceq $oldHash) `
                    'replacement failure did not preserve sealed historical evidence and record incompletion'

                $newRoot=New-GenerationTestRoot
                try {
                    $newOld=Start-SyntheticGeneration $newRoot 'frontend' ('b' * 64)
                    $newOldRecord=Seal-SyntheticGeneration $newRoot frontend $newOld
                    $newHash=(Get-FileHash -LiteralPath $newOldRecord.capturePath -Algorithm SHA256).Hash
                    $newHandoff=Begin-GeordiCaptureHandoff -CaptureRoot $newRoot -Service frontend -Reason 'follower-start-failure'
                    $startFailed=$false
                    try { $null=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $newRoot -Service frontend -HandoffId $newHandoff `
                        -RepositoryRoot (Get-Location).Path -Replace {} -GetContainerIdentity { param($service) New-ContainerIdentity ('c' * 64) $service } `
                        -StartFollower { throw 'synthetic follower failure' } } catch { $startFailed=$true }
                    $newManifest=Read-GenerationManifest $newRoot
                    $incomplete=@($newManifest.captureGenerations.frontend | Where-Object terminalStatus -ceq 'incomplete-start')
                    Assert-CaptureGeneration ($startFailed -and $newManifest.captureHandoffs[$newHandoff].status -ceq 'incomplete-new-generation' -and
                        $incomplete.Count -eq 1 -and (Get-FileHash -LiteralPath $newOldRecord.capturePath -Algorithm SHA256).Hash -ceq $newHash) `
                        'new follower startup failure was not recorded while preserving the sealed old generation'
                } finally { Remove-GenerationTestRoot $newRoot }
            } finally { Remove-GenerationTestRoot $replacementRoot }
            Write-Output 'capture_generation_failure=PASS identity_mismatch=fail_closed seal_failure=recorded replacement_failure=preserved new_follower_failure=recorded'
        }
        'Manifest' {
            $oldId=Start-SyntheticGeneration $root 'backend' ('1' * 64)
            $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service backend -Reason 'manifest-validation' `
                -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
            $newId=Start-SyntheticGeneration $root backend ('2' * 64) -HandoffId $handoff
            $null=Seal-SyntheticGeneration $root backend $newId
            $manifest=Read-GenerationManifest $root
            Assert-GeordiCaptureGenerationManifest $manifest
            $saved=(Get-FileHash -LiteralPath (Get-GeordiCaptureGenerationRecord $manifest backend $oldId).capturePath -Algorithm SHA256).Hash
            $bad=[IO.File]::ReadAllText((Join-Path $root 'manifest.json')) | ConvertFrom-Json -AsHashtable
            $bad.captureHandoffs[$handoff].status='incomplete-replacement'
            $rejected=$false
            try { Assert-GeordiCaptureGenerationManifest $bad } catch { $rejected=$true }
            Assert-CaptureGeneration $rejected 'incomplete handoff passed manifest validation'
            Assert-CaptureGeneration ((Get-FileHash -LiteralPath (Get-GeordiCaptureGenerationRecord $manifest backend $oldId).capturePath -Algorithm SHA256).Hash -ceq $saved) 'validation mutated historical capture'
            $newRecord=Get-GeordiCaptureGenerationRecord $manifest backend $newId
            $invalidManifests=@(
                @{label='missing generation';mutate={param($m)$m.captureGenerations.backend=@($m.captureGenerations.backend[0])}},
                @{label='missing handoff';mutate={param($m)$m.captureHandoffs.Remove($handoff)}},
                @{label='hash mismatch';mutate={param($m)(Get-GeordiCaptureGenerationRecord $m backend $newId).sha256=('0'*64)}},
                @{label='byte count mismatch';mutate={param($m)(Get-GeordiCaptureGenerationRecord $m backend $newId).byteCount++}},
                @{label='container identity mismatch';mutate={param($m)(Get-GeordiCaptureGenerationRecord $m backend $newId).containerId=('3'*64)}},
                @{label='generation order';mutate={param($m)[array]::Reverse($m.captureGenerations.backend)}},
                @{label='unexplained gap';mutate={param($m)$m.captureHandoffs[$handoff].gapDurationMilliseconds=$m.captureHandoffs[$handoff].maximumGapMilliseconds+1}}
            )
            foreach ($invalid in $invalidManifests) {
                $candidate=Read-GenerationManifest $root
                & $invalid.mutate $candidate
                $invalidRejected=$false
                try { Assert-GeordiCaptureGenerationManifest $candidate } catch { $invalidRejected=$true }
                Assert-CaptureGeneration $invalidRejected ([string]$invalid.label + ' was accepted')
            }
            $missingPath=$false
            $newRecordItem=Get-Item -LiteralPath $newRecord.capturePath -Force
            $newRecordItem.IsReadOnly=$false
            $originalBytes=[IO.File]::ReadAllBytes($newRecord.capturePath)
            try {
                [IO.File]::WriteAllBytes($newRecord.capturePath,[byte[]]@())
                try { Assert-GeordiCaptureGenerationManifest (Read-GenerationManifest $root) } catch { $missingPath=$true }
            } finally { [IO.File]::WriteAllBytes($newRecord.capturePath,$originalBytes); (Get-Item -LiteralPath $newRecord.capturePath -Force).IsReadOnly=$true }
            Assert-CaptureGeneration $missingPath 'truncated generation capture was accepted'
            $manifestAfterRestore=Read-GenerationManifest $root
            $missingCaptureManifest=$false
            $backupPath=$newRecord.capturePath+'.temporarily-moved'
            Move-Item -LiteralPath $newRecord.capturePath -Destination $backupPath
            try { Assert-GeordiCaptureGenerationManifest $manifestAfterRestore } catch { $missingCaptureManifest=$true }
            finally { Move-Item -LiteralPath $backupPath -Destination $newRecord.capturePath }
            Assert-CaptureGeneration $missingCaptureManifest 'missing generation capture file was accepted'
            Write-Output 'capture_generation_manifest=PASS incomplete_handoff=fail_closed missing_truncated_hash_byte_order_gap=fail_closed historical_immutable=true'
        }
        'AlreadySealedTimestamp' {
            $oldId=Start-SyntheticGeneration $root backend ('a' * 64)
            $sealed=Seal-SyntheticGeneration $root backend $oldId
            $reloaded=Read-GenerationManifest $root
            $oldRecord=Get-GeordiCaptureGenerationRecord $reloaded backend $oldId
            $sourceInstant=ConvertTo-GeordiCaptureUtcInstant -Value $oldRecord.captureEndedUtc -Field 'oldGeneration.captureEndedUtc'
            $oldType=$oldRecord.captureEndedUtc.GetType().FullName
            $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service backend -Reason 'already-sealed-timestamp' `
                -TestProcessIdentity $script:mockTestProcess -StopProcess $script:mockStopProcess
            $published=Read-GenerationManifest $root
            $event=$published.captureHandoffs[$handoff]
            $wire=[System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText((Join-Path $root 'manifest.json')))
            try{$wireTimestamp=$wire.RootElement.GetProperty('captureHandoffs').GetProperty($handoff).GetProperty('oldCaptureEndedUtc').GetString()}finally{$wire.Dispose()}
            $wireCanonical=$wireTimestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}(?:Z|[+-]\d{2}:\d{2})$'
            $publishedInstant=ConvertTo-GeordiCaptureUtcInstant -Value $event.oldCaptureEndedUtc -Field 'handoff.oldCaptureEndedUtc'
            $newId=Start-SyntheticGeneration $root backend ('b' * 64) -HandoffId $handoff
            $null=Seal-SyntheticGeneration $root backend $newId
            Assert-GeordiCaptureGenerationManifest (Read-GenerationManifest $root)
            Assert-CaptureGeneration ($wireCanonical -and $sourceInstant.UtcTicks -eq $publishedInstant.UtcTicks -and
                $event.status -ceq 'old-sealed' -and $sealed.generationId -ceq $oldId) 'already-sealed handoff did not preserve the canonical source instant or complete a valid transition'
            Write-Output ('already_sealed_handoff_timestamp=PASS source_type='+$oldType+' wire_canonical=true exact_instant=true completed_transition=true')
        }