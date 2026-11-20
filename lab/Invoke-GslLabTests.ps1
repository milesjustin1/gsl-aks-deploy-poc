<#
.SYNOPSIS
    Runs the reuse and security tests against the lab and produces the evidence report.

.DESCRIPTION
    C  Repeat deploy   : change hello-web (v1 -> v2) and push. Expect success, new image tag, no identity change.
    D  Rogue repo      : create '<owner>/rogue-app' that is NOT onboarded, with the same caller workflow.
                         D1 its deploy run is refused by the central workflow's allowlist;
                         D2 a direct azure/login from it is refused by Entra (no matching federated credential).
    E  Bypass          : in onboarded forecast-api, a workflow that calls azure/login directly with the shared
                         client ID. Expect Entra to refuse (the workflow reports PASS when the login fails).
    F  Namespace escape: on a throwaway branch of obs-ingest, a manifest targeting hello-web's namespace,
                         deployed by dispatching deploy.yml on that branch. Expect the apply to fail and nothing
                         to appear in hello-web.
    Then runs ..\tests\Get-GslPocEvidence.ps1 with the run links.

.EXAMPLE
    .\Invoke-GslLabTests.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Apps = @("hello-web", "forecast-api", "obs-ingest"),
    [string]$RogueRepo = "rogue-app",
    [ValidateSet("public", "private")][string]$Visibility = "public",
    [string]$StatePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "platform/poc-state.json"),
    [string]$OutputPath = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\LabCommon.ps1"

$s = Get-LabState $StatePath
$owner = $s.gitHubOrg
$rendered = Join-Path $KitRoot "rendered"
$ident = Get-GitIdentity
$negWf = Join-Path $rendered "negative-tests/.github/workflows/poc-negative-direct-login.yml"
$results = New-Object System.Collections.Generic.List[object]

function Add-TestResult {
    param([string]$Test, [string]$Expect, $Run, [bool]$Passed, [string]$Detail)
    $results.Add([pscustomobject]@{ Test = $Test; Expected = $Expect; Outcome = $(if ($Passed) { "PASS" } else { "FAIL" }); Detail = $Detail; Run = $Run.Url }) | Out-Null
    $c = if ($Passed) { "Green" } else { "Red" }
    Write-Host ("    {0}  {1}" -f $(if ($Passed) { "PASS" } else { "FAIL" }), $Detail) -ForegroundColor $c
}

$ficBefore = @(Invoke-Az identity federated-credential list -g $s.resourceGroup --identity-name $s.identityName).Count
$rolesBefore = @(Invoke-Az role assignment list --assignee $s.principalId --all).Count

# ------------------------------------------------------------------ C
Write-Step "Test C: repeat deployment of hello-web (v1 -> v2)"
$wc = Get-RepoWorkingCopy "$owner/hello-web"
$idx = Join-Path $wc "index.html"
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmm")
(Get-Content $idx -Raw) -replace '<code>v[^<]*</code>', "<code>v2-$stamp</code>" | Set-Content -Path $idx -Encoding UTF8 -NoNewline
$t0 = (Get-Date).ToUniversalTime().AddSeconds(-30)
Save-RepoChanges -Dir $wc -Message "hello-web v2-$stamp" -Identity $ident | Out-Null
$r = Wait-GhRun -Full "$owner/hello-web" -Workflow "deploy.yml" -After $t0
$tags = @(Invoke-Az acr repository show-tags -n $s.acrName --repository hello-web)
$whyC = if ($r.Conclusion -ne "success") { "; error: " + (Get-RunFailureLine -Full "$owner/hello-web" -RunId $r.Id) } else { "" }
Add-TestResult "C. Repeat deploy" "Succeeds, new image tag" $r ($r.Conclusion -eq "success") "run $($r.Conclusion); hello-web image tags in ACR: $($tags.Count)$whyC"

# ------------------------------------------------------------------ D
Write-Step "Test D: repo that was never onboarded ($owner/$RogueRepo)"
New-GhRepo -Full "$owner/$RogueRepo" -Visibility $Visibility -Description "Negative test: NOT onboarded; must not be able to deploy"
$wc = Get-RepoWorkingCopy "$owner/$RogueRepo"
Copy-FolderContent -From (Join-Path $PSScriptRoot "apps/hello-web") -To $wc
New-Item -ItemType Directory -Force -Path (Join-Path $wc ".github/workflows"), (Join-Path $wc "manifests") | Out-Null
Copy-Item (Join-Path $rendered "app-template/.github/workflows/deploy.yml") (Join-Path $wc ".github/workflows/deploy.yml") -Force
Copy-Item $negWf (Join-Path $wc ".github/workflows/poc-negative-direct-login.yml") -Force
Copy-Item (Join-Path $rendered "app-template/manifests/*.yaml") (Join-Path $wc "manifests") -Force
$t0 = (Get-Date).ToUniversalTime().AddSeconds(-30)
Save-RepoChanges -Dir $wc -Message "rogue app attempts to use the shared deploy workflow" -Identity $ident | Out-Null
$r = Wait-GhRun -Full "$owner/$RogueRepo" -Workflow "deploy.yml" -After $t0
$why = Get-RunFailureLine -Full "$owner/$RogueRepo" -RunId $r.Id
Add-TestResult "D1. Not onboarded, via central workflow" "Refused by allowlist" $r (($r.Conclusion -eq "failure") -and ($why -match "ALLOWED_APPS")) "run $($r.Conclusion): $why"

$t0 = (Get-Date).ToUniversalTime().AddSeconds(-10)
Start-GhWorkflow -Full "$owner/$RogueRepo" -Workflow "poc-negative-direct-login.yml"
$r = Wait-GhRun -Full "$owner/$RogueRepo" -Workflow "poc-negative-direct-login.yml" -After $t0
$why = Get-RunFailureLine -Full "$owner/$RogueRepo" -RunId $r.Id -AllLogs
Add-TestResult "D2. Not onboarded, direct sign-in" "Entra refuses token" $r ($r.Conclusion -eq "success") "login refused by Entra: $why"

# ------------------------------------------------------------------ E
$eRepo = "$owner/$($Apps[1])"
Write-Step "Test E: onboarded repo bypasses the central workflow ($eRepo)"
$wc = Get-RepoWorkingCopy $eRepo
Copy-Item $negWf (Join-Path $wc ".github/workflows/poc-negative-direct-login.yml") -Force
Save-RepoChanges -Dir $wc -Message "negative test: direct sign-in as the shared identity" -Identity $ident | Out-Null
Start-Sleep -Seconds 5
$t0 = (Get-Date).ToUniversalTime().AddSeconds(-10)
Start-GhWorkflow -Full $eRepo -Workflow "poc-negative-direct-login.yml"
$r = Wait-GhRun -Full $eRepo -Workflow "poc-negative-direct-login.yml" -After $t0
$why = Get-RunFailureLine -Full $eRepo -RunId $r.Id -AllLogs
Add-TestResult "E. Onboarded repo, direct sign-in" "Entra refuses token" $r ($r.Conclusion -eq "success") "login refused by Entra: $why"
Write-Info "(Adding the file also pushed to main, so $($Apps[1]) redeployed through the central workflow - another reuse.)"

# ------------------------------------------------------------------ F
$fRepo = "$owner/$($Apps[2])"
Write-Step "Test F: $($Apps[2]) tries to write into hello-web's namespace"
$wc = Get-RepoWorkingCopy $fRepo
Invoke-Git $wc checkout --quiet -B escape-test | Out-Null
Copy-Item (Join-Path $PSScriptRoot "manifests/escape.yaml") (Join-Path $wc "manifests/escape.yaml") -Force
Save-RepoChanges -Dir $wc -Message "negative test: cross-namespace write" -Branch "escape-test" -Identity $ident | Out-Null
$t0 = (Get-Date).ToUniversalTime().AddSeconds(-10)
Start-GhWorkflow -Full $fRepo -Workflow "deploy.yml" -Ref "escape-test"
$r = Wait-GhRun -Full $fRepo -Workflow "deploy.yml" -After $t0
$why = Get-RunFailureLine -Full $fRepo -RunId $r.Id
& kubectl get configmap escape-attempt -n hello-web *> $null
$absent = ($LASTEXITCODE -ne 0)
# Only counts if the run failed BECAUSE of the cross-namespace object, not for some unrelated reason.
$nsDenied = $why -match "namespace|forbidden|cannot (create|patch|get)"
Add-TestResult "F. Cross-namespace write" "Apply fails on the hello-web object; nothing in hello-web" $r (($r.Conclusion -eq "failure") -and $absent -and $nsDenied) "run $($r.Conclusion); configmap in hello-web: $(if ($absent) {'absent'} else {'PRESENT'}); error: $why"
& gh api -X DELETE "repos/$fRepo/git/refs/heads/escape-test" 2>$null | Out-Null

# ------------------------------------------------------------------ Invariants
Write-Step "Invariants after all tests"
$ficAfter = @(Invoke-Az identity federated-credential list -g $s.resourceGroup --identity-name $s.identityName).Count
$rolesAfter = @(Invoke-Az role assignment list --assignee $s.principalId --all).Count
$appsNow = Get-OwnedAppCount
Write-Host "  Federated credentials : $ficBefore -> $ficAfter" -ForegroundColor $(if ($ficAfter -eq 1) { "Green" } else { "Red" })
Write-Host "  Identity role count   : $rolesBefore -> $rolesAfter (unchanged by tests)" -ForegroundColor $(if ($rolesAfter -eq $rolesBefore) { "Green" } else { "Red" })
Write-Host "  Your app registrations: baseline $($s.ownedAppsBaseline) -> $appsNow" -ForegroundColor $(if ($appsNow -eq [int]$s.ownedAppsBaseline) { "Green" } else { "Red" })

$results | Format-Table Test, Outcome, Detail -AutoSize -Wrap
$stampFile = Get-Date -Format "yyyyMMdd-HHmm"
$results | ConvertTo-Json | Set-Content -Path (Join-Path $OutputPath "GSL-Lab-Tests-$stampFile.json") -Encoding UTF8

Write-Step "Evidence report"
$neg = @{
    D = (@($results | Where-Object { $_.Test -like "D1*" }).Run | Select-Object -First 1)
    E = (@($results | Where-Object { $_.Test -like "E.*" }).Run | Select-Object -First 1)
    F = (@($results | Where-Object { $_.Test -like "F.*" }).Run | Select-Object -First 1)
}
& (Join-Path $KitRoot "tests/Get-GslPocEvidence.ps1") -AppRepo $Apps -StatePath $StatePath -NegativeRunUrl $neg -OutputPath $OutputPath
