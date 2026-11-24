<#
.SYNOPSIS
    Creates the central deploy repo and three synthetic app repos in your GitHub account, onboards each app,
    and lets GitHub Actions deploy all three with the SAME managed identity and the SAME federated credential.

.DESCRIPTION
    Order (it matters):
      1. <owner>/gsl-deploy  : central reusable workflow (rendered with your IDs), ALLOWED_APPS = the 3 apps,
                               CODEOWNERS; shared with your other repos if private.
      2. For each app        : create an EMPTY repo, run ..\platform\Add-GslApp.ps1 (namespace, namespace role,
                               OIDC subject opt-in, environment). No Azure identity or Entra change.
      3. Wait for Azure RBAC to apply, then push each app's code + caller workflow + manifests.
         The push to main triggers the deployment. The script follows each run to completion.

    Apps (all listen on 8080, different stacks on purpose):
      hello-web     static site (nginx, unprivileged)
      forecast-api  Python Flask + gunicorn, synthetic point forecast JSON
      obs-ingest    Node.js, synthetic station-observation feed
      station-map   static page; kept back for the live "onboard app #4" moment:
                    .\Publish-GslLabRepos.ps1 -Apps hello-web,forecast-api,obs-ingest,station-map

    Requires: gh signed in with the 'workflow' scope (gh auth refresh -s workflow), git, and the state file
    from New-GslPocLab.ps1.

.EXAMPLE
    .\Publish-GslLabRepos.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Apps = @("hello-web", "forecast-api", "obs-ingest"),
    [ValidateSet("public", "private")][string]$Visibility = "public",
    [string]$StatePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "platform/poc-state.json"),
    [int]$RbacWaitSeconds = 90,
    [switch]$NoWait,
    [switch]$RefreshCode
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\LabCommon.ps1"

$s = Get-LabState $StatePath
$owner = $s.gitHubOrg
$central = "$owner/$($s.centralRepo)"
$rendered = Join-Path $KitRoot "rendered"
if (-not (Test-Path (Join-Path $rendered "gsl-deploy"))) { throw "Rendered files not found in $rendered. Run New-GslPocLab.ps1 first." }

Write-Step "GitHub prerequisites"
Assert-GitHubOwnerUsable -Owner $owner | Out-Null
foreach ($v in @("GH_TOKEN", "GITHUB_TOKEN")) {
    if ([Environment]::GetEnvironmentVariable($v)) {
        Write-Warning "`$env:$v is set. gh uses it instead of your 'gh auth login' token, so 'gh auth refresh' has no effect. Clear it for this session: Remove-Item Env:\$v"
    }
}
# Ask GitHub which scopes the token gh is actually using (classic OAuth tokens report X-OAuth-Scopes).
$scopeLine = @(& { $ErrorActionPreference = 'Continue'; & gh api -i user 2>$null } | Select-String -Pattern '^X-OAuth-Scopes:\s*(.*)$') | Select-Object -First 1
if ($scopeLine) {
    $scopes = $scopeLine.Matches[0].Groups[1].Value.Trim()
    if ($scopes -notmatch '(^|[\s,])workflow($|[\s,])') {
        throw "The token gh is using has scopes [$scopes] but no 'workflow' (needed to push .github/workflows). Run: gh auth refresh -h github.com -s workflow   (then: gh api -i user | Select-String X-OAuth-Scopes)"
    }
    Write-Ok "Token scopes: $scopes"
}
else {
    Write-Warning "Could not read token scopes (fine-grained token?). Continuing. Pushing workflow files needs Contents + Workflows write; creating repos needs Administration write."
}
& { $ErrorActionPreference = 'Continue'; & gh auth setup-git 2>$null } | Out-Null
$ident = Get-GitIdentity
$ownerType = (Invoke-Gh api "users/$owner" --jq .type).Trim()
Write-Ok "Pushing as $($ident.Name); owner $owner is a GitHub $ownerType; repos will be $Visibility"
if ($Visibility -eq "private") {
    Write-Warning "Private repos on a free personal plan cannot use environment protection rules. The deploys still run; approval gates need public repos or a paid plan."
}

# ------------------------------------------------------------------ 1. Central repo
Write-Step "Central repo $central"
New-GhRepo -Full $central -Visibility $Visibility -Description "Central reusable deploy workflow: the only workflow trusted by the shared AKS deployment identity"
$wc = Get-RepoWorkingCopy $central
Copy-FolderContent -From (Join-Path $rendered "gsl-deploy") -To $wc
$wfPath = Join-Path $wc ".github/workflows/$($s.workflowFile)"
$wf = Get-Content $wfPath -Raw
$allow = ($Apps | ForEach-Object { "    $_" }) -join "`n"
$wf = [regex]::Replace($wf, '(?m)(  ALLOWED_APPS: \|\r?\n)((?:    \S.*\r?\n)+)', { param($m) $m.Groups[1].Value + $allow + "`n" })
[System.IO.File]::WriteAllText($wfPath, $wf)
New-Item -ItemType Directory -Force -Path (Join-Path $wc ".github") | Out-Null
"* @$owner`n" | Set-Content -Path (Join-Path $wc ".github/CODEOWNERS") -Encoding ASCII
@"
# $($s.centralRepo)

Central reusable workflow for AKS deployments. It is the only workflow the shared managed identity
``$($s.identityName)`` trusts (one federated credential, subject pinned to this file on ``main``).

- App repos call ``.github/workflows/$($s.workflowFile)@main``; see any app repo's ``deploy.yml``.
- Onboarding an app = run ``Add-GslApp.ps1`` + add its name to ``ALLOWED_APPS`` here (pull request).
- Anyone who can merge to ``main`` controls what every app deploys: protect it.
"@ | Set-Content -Path (Join-Path $wc "README.md") -Encoding UTF8
if (Save-RepoChanges -Dir $wc -Message "Central deploy workflow; allow: $($Apps -join ', ')" -Identity $ident) { Write-Ok "Pushed central workflow (ALLOWED_APPS: $($Apps -join ', '))" }
if ($Visibility -eq "private") {
    $level = if ($ownerType -eq "Organization") { "organization" } else { "user" }
    Invoke-Gh api -X PUT "repos/$central/actions/permissions/access" -f "access_level=$level" | Out-Null
    Write-Ok "Central workflow shared with $owner's repositories ($level)"
}

# ------------------------------------------------------------------ 2. Onboard
Write-Step "Create and onboard app repos (no Azure identity or Entra changes)"
foreach ($app in $Apps) {
    if (-not (Test-Path (Join-Path $PSScriptRoot "apps/$app"))) { throw "No sample app folder for '$app' under lab/apps" }
    New-GhRepo -Full "$owner/$app" -Visibility $Visibility -Description "Synthetic GSL POC app deployed by the shared AKS deployment identity"
    & (Join-Path $KitRoot "platform/Add-GslApp.ps1") -AppRepo $app -StatePath $StatePath -SkipReminders
}
Write-Info "Waiting $RbacWaitSeconds s for namespace role assignments to apply (the workflow also retries)..."
Start-Sleep -Seconds $RbacWaitSeconds

# ------------------------------------------------------------------ 3. Push code -> automatic deploys
Write-Step "Push app code; each push to main triggers a deployment"
$pushed = @{}
foreach ($app in $Apps) {
    if (-not $RefreshCode -and (& { $ErrorActionPreference = 'Continue'; & git ls-remote --heads "https://github.com/$owner/$app.git" 2>$null })) {
        Write-Info "$app already has code; not pushed again (use -RefreshCode to overwrite)"
        continue
    }
    $wc = Get-RepoWorkingCopy "$owner/$app"
    Copy-FolderContent -From (Join-Path $PSScriptRoot "apps/$app") -To $wc
    New-Item -ItemType Directory -Force -Path (Join-Path $wc ".github/workflows"), (Join-Path $wc "manifests") | Out-Null
    Copy-Item (Join-Path $rendered "app-template/.github/workflows/deploy.yml") (Join-Path $wc ".github/workflows/deploy.yml") -Force
    Copy-Item (Join-Path $rendered "app-template/manifests/*.yaml") (Join-Path $wc "manifests") -Force
    Copy-Item (Join-Path $PSScriptRoot "manifests/ingress.yaml") (Join-Path $wc "manifests/ingress.yaml") -Force
    $t0 = (Get-Date).ToUniversalTime().AddSeconds(-30)
    if (Save-RepoChanges -Dir $wc -Message "$app v1: app, caller workflow, manifests" -Identity $ident) {
        Write-Ok "Pushed $owner/$app"
        $pushed[$app] = $t0
    }
}

if ($NoWait) { Write-Host "`n  Runs started. Watch them at https://github.com/$owner/<app>/actions"; return }

Write-Step "Follow the three deployments"
$results = @()
foreach ($app in $Apps) {
    if (-not $pushed.ContainsKey($app)) { continue }
    Write-Host "  $app" -ForegroundColor White
    $r = Wait-GhRun -Full "$owner/$app" -Workflow "deploy.yml" -After $pushed[$app]
    if ($r.Conclusion -ne "success") { Write-Warning "$app deploy concluded '$($r.Conclusion)': $(Get-RunFailureLine -Full "$owner/$app" -RunId $r.Id)" }
    else { Write-Ok "$app deployed" }
    $results += [pscustomobject]@{ App = $app; Result = $r.Conclusion; Run = $r.Url }
}
$results | Format-Table -AutoSize

Write-Step "What is running"
foreach ($app in $Apps) { & { $ErrorActionPreference = 'Continue'; & kubectl get deploy,pods -n $app -o wide 2>$null } }
$ip = (& { $ErrorActionPreference = 'Continue'; & kubectl get svc nginx -n app-routing-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null })
if ($ip) {
    Write-Host "`n  Try the apps through the app routing ingress:" -ForegroundColor Cyan
    foreach ($app in $Apps) { Write-Host "    curl -H `"Host: $app.gsl-lab.local`" http://$ip/" }
}

if ($results.Count -eq 0) { Write-Info "Nothing new was pushed, so no runs to follow." }

Write-Step "Proof of reuse"
$fics = @(Invoke-Az identity federated-credential list -g $s.resourceGroup --identity-name $s.identityName)
Write-Host "  Federated credentials on $($s.identityName): $($fics.Count)  (one, for all $($Apps.Count) apps)" -ForegroundColor Green
$now = Get-OwnedAppCount
Write-Host "  App registrations you own: $now  (baseline $($s.ownedAppsBaseline))" -ForegroundColor Green
Write-Host "`n  Next: .\Invoke-GslLabTests.ps1   (repeat deploy + three negative tests + evidence report)"
