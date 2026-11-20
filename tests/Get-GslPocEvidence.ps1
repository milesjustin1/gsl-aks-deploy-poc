<#
.SYNOPSIS
    Collects evidence for the POC acceptance criteria and writes a Markdown evidence report. Read-only.

.DESCRIPTION
    Checks, for the shared deployment identity in poc-state.json:
      - Exactly one federated credential, matching the central workflow subject
      - Azure roles held (and that none are broad)
      - Wizard-style Entra app registrations ("workflowapp-*") created since the POC started
      - Per app: namespace access, images in ACR (tags = deployments), workload status in AKS
      - Optional: managed identity sign-ins from Log Analytics (-WorkspaceId)
    Negative tests (D, E, F) are recorded from the GitHub run links you pass in.

.EXAMPLE
    .\Get-GslPocEvidence.ps1 -AppRepo ssop-container,gsl-poc-hello `
        -NegativeRunUrl @{ D = "https://github.com/.../runs/1"; E = "https://github.com/.../runs/2"; F = "https://github.com/.../runs/3" }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$AppRepo,
    [string]$StatePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "platform/poc-state.json"),
    [string]$WorkspaceId,
    [hashtable]$NegativeRunUrl = @{},
    [string]$OutputPath = (Get-Location).Path
)
$ErrorActionPreference = "Continue"

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$AzArgs)
    $out = & az @AzArgs -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($AzArgs[0..2] -join ' ') failed: $((($out | Out-String).Trim()) -replace '\s+', ' ')" }
    $text = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}
function ConvertTo-AppName { param([string]$Repo) $n = ($Repo.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-'); if ($n.Length -gt 63) { $n = $n.Substring(0, 63) }; $n }

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row { param([string]$Criterion, [string]$Target, [string]$Observed, [ValidateSet("Pass","Fail","Manual","Not assessed")][string]$Result)
    $rows.Add([pscustomobject]@{ Criterion = $Criterion; Target = $Target; Observed = $Observed; Result = $Result }) | Out-Null
    $c = switch ($Result) { "Pass" {"Green"} "Fail" {"Red"} default {"Yellow"} }
    Write-Host ("  [{0,-12}] {1}: {2}" -f $Result, $Criterion, $Observed) -ForegroundColor $c
}

$s = Get-Content $StatePath -Raw | ConvertFrom-Json
# PowerShell 7 turns ISO strings into DateTime on ConvertFrom-Json; 5.1 leaves strings. Handle both.
$start = if ($s.createdUtc -is [datetime]) { $s.createdUtc.ToUniversalTime() } else {
    [datetime]::Parse([string]$s.createdUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) }
Invoke-Az account set --subscription $s.subscriptionId | Out-Null
Write-Host "POC evidence for $($s.identityName) since $($start.ToString('u'))`n" -ForegroundColor Cyan

# 1. Federated credentials
try {
    $fics = @(Invoke-Az identity federated-credential list -g $s.resourceGroup --identity-name $s.identityName)
    $ok = $fics.Count -eq 1 -and $fics[0].subject -eq $s.federatedSubject
    Add-Row "Federated credentials on the deployment identity" "1 (central workflow only)" "$($fics.Count): $(($fics | ForEach-Object { $_.subject }) -join '; ')" $(if ($ok) {"Pass"} else {"Fail"})
} catch { Add-Row "Federated credentials on the deployment identity" "1" $_.Exception.Message "Not assessed" }

# 2. Roles
try {
    $ras = @(Invoke-Az role assignment list --assignee $s.principalId --all)
    $broad = @($ras | Where-Object { $_.roleDefinitionName -in @("Owner","Contributor","User Access Administrator","Role Based Access Control Administrator","Azure Kubernetes Service RBAC Cluster Admin","Azure Kubernetes Service Cluster Admin Role") })
    $txt = ($ras | ForEach-Object { "$($_.roleDefinitionName) @ $(($_.scope -split '/')[-1])$(if ($_.scope -match '/namespaces/') {' (namespace)'})" }) -join "; "
    Add-Row "Deployment identity roles are least-privilege" "No Owner/Contributor/cluster-admin" $txt $(if ($broad.Count -eq 0) {"Pass"} else {"Fail"})
} catch { Add-Row "Deployment identity roles are least-privilege" "No broad roles" $_.Exception.Message "Not assessed" }

# 3. Client secrets
Add-Row "Client secrets used for deployment" "0" "0 - a managed identity cannot hold a client secret" "Pass"

# 4. Entra app registrations (wizard pattern) since POC start
try {
    $graph = if ($s.cloud -eq "AzureUSGovernment") { "https://graph.microsoft.us" } else { "https://graph.microsoft.com" }
    $iso = $start.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $url = "$graph/v1.0/applications?`$filter=createdDateTime ge $iso and startswith(displayName,'workflowapp')&`$count=true&`$select=displayName,appId,createdDateTime"
    $apps = Invoke-Az rest --method get --url $url --headers "ConsistencyLevel=eventual"
    $n = @($apps.value).Count
    Add-Row "New wizard-style app registrations (workflowapp-*) since POC start" "0" "$n$(if ($n) { ': ' + ((@($apps.value) | ForEach-Object { $_.displayName }) -join ', ') })" $(if ($n -eq 0) {"Pass"} else {"Fail"})
} catch { Add-Row "New wizard-style app registrations since POC start" "0" "Graph not readable here; HAES runs the KQL in the report" "Not assessed" }

# 4b. Lab: app registrations owned by the operator, before vs now (baseline recorded by New-GslPocLab.ps1)
if ($null -ne $s.PSObject.Properties["ownedAppsBaseline"]) {
    try {
        # No JMESPath: on Windows az is az.cmd and cmd.exe mangles arguments such as length(@).
        $ownedJson = (& az ad app list --show-mine -o json 2>$null) -join "`n"
        $owned = $ownedJson | ConvertFrom-Json
        $nowCount = if ($null -eq $owned) { 0 } else { @($owned).Count }
        Add-Row "App registrations owned by the operator (lab)" "Unchanged from baseline ($($s.ownedAppsBaseline))" "$nowCount" $(if ($nowCount -eq [int]$s.ownedAppsBaseline) {"Pass"} else {"Fail"})
    } catch { Add-Row "App registrations owned by the operator (lab)" "Unchanged" $_.Exception.Message "Not assessed" }
}

# 5. Per app
$deployed = 0
$kc = Join-Path ([System.IO.Path]::GetTempPath()) ("gsl-evidence-" + [guid]::NewGuid().ToString("N") + ".kubeconfig")
$haveK = $false
try {
    Invoke-Az aks get-credentials -g $s.aksResourceGroup -n $s.aksName --file $kc --overwrite-existing | Out-Null
    if (Get-Command kubelogin -ErrorAction SilentlyContinue) { & kubelogin convert-kubeconfig -l azurecli --kubeconfig $kc | Out-Null }
    $haveK = $true
} catch { Write-Warning "No kubeconfig: $($_.Exception.Message)" }

$appRows = New-Object System.Collections.Generic.List[object]
foreach ($repo in $AppRepo) {
    $app = ConvertTo-AppName $repo
    $tags = @(); $access = "?"; $ready = "?"; $images = "?"
    try { $tags = @(Invoke-Az acr repository show-tags -n $s.acrName --repository $app --orderby time_desc) } catch { }
    try {
        if ($s.aksAzureRbac) { $access = if (@(Invoke-Az role assignment list --assignee $s.principalId --scope "$($s.aksId)/namespaces/$app").Count) { "Writer (namespace)" } else { "none" } }
        else { $access = "RoleBinding (check kubectl)" }
    } catch { }
    if ($haveK) {
        $dj = (& kubectl --kubeconfig $kc get deployments -n $app -o json 2>$null) -join "`n"
        if ($dj) {
            $d = $dj | ConvertFrom-Json
            $ready = (@($d.items) | ForEach-Object { "$($_.metadata.name) $([int]$_.status.readyReplicas)/$([int]$_.spec.replicas)" }) -join ", "
            $images = (@($d.items) | ForEach-Object { $_.spec.template.spec.containers | ForEach-Object { ($_.image -split '/')[-1] } }) -join ", "
            if (@($d.items | Where-Object { [int]$_.status.readyReplicas -ge 1 }).Count) { $deployed++ }
        }
    }
    $appRows.Add([pscustomobject]@{ Repo = $repo; Namespace = $app; Access = $access; ImagesInAcr = $tags.Count; LatestTags = (($tags | Select-Object -First 3) -join ", "); Running = $images; Ready = $ready }) | Out-Null
}
Remove-Item $kc -Force -ErrorAction SilentlyContinue

Add-Row "Applications deployed with the shared identity" ">= 2" "$deployed of $($AppRepo.Count) running" $(if ($deployed -ge 2) {"Pass"} elseif ($haveK) {"Fail"} else {"Not assessed"})
$first = $appRows | Select-Object -First 1
Add-Row "Repeat deployment of the first app" ">= 2 images (commit tags)" "$($first.ImagesInAcr) image tag(s) for $($first.Repo)" $(if ($first.ImagesInAcr -ge 2) {"Pass"} else {"Fail"})

# 6. Sign-ins
$kql = @"
AADManagedIdentitySignInLogs
| where TimeGenerated >= datetime($($start.ToString('yyyy-MM-ddTHH:mm:ssZ')))
| where ServicePrincipalId == '$($s.principalId)'
| summarize SignIns = count(), Failures = countif(ResultType != '0') by ResourceDisplayName
"@
if ($WorkspaceId) {
    try {
        # One line: a multi-line argument breaks when az.cmd passes it through cmd.exe on Windows.
        $kqlOneLine = (($kql -split "\r?\n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join " "
        $r = Invoke-Az monitor log-analytics query -w $WorkspaceId --analytics-query $kqlOneLine
        Add-Row "Deployment sign-ins logged in Entra" "> 0" ((@($r) | ForEach-Object { "$($_.ResourceDisplayName): $($_.SignIns) ($($_.Failures) failed)" }) -join "; ") $(if (@($r).Count) {"Pass"} else {"Fail"})
    } catch { Add-Row "Deployment sign-ins logged in Entra" "> 0" $_.Exception.Message "Not assessed" }
}
else { Add-Row "Deployment sign-ins logged in Entra" "> 0" "Run the KQL below in the Entra log workspace" "Manual" }

# 7. Negative tests
foreach ($t in @(@("D", "Repo not onboarded is refused a token"), @("E", "Direct sign-in that bypasses the central workflow is refused"), @("F", "App cannot write into another app's namespace"))) {
    $u = $NegativeRunUrl[$t[0]]
    Add-Row "Test $($t[0]): $($t[1])" "Denied" $(if ($u) { "Run: $u" } else { "Record the failed run link" }) "Manual"
}

# Report
$stamp = Get-Date -Format "yyyyMMdd-HHmm"
$md = Join-Path $OutputPath "GSL-POC-Evidence-$stamp.md"
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# GSL reusable deployment identity - POC evidence")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Identity: ``$($s.identityName)`` (client ID ``$($s.clientId)``). POC start: $($start.ToString('u')). Collected: $((Get-Date).ToUniversalTime().ToString('u')).")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| Criterion | Target | Observed | Result |")
[void]$sb.AppendLine("|---|---|---|---|")
foreach ($r in $rows) { [void]$sb.AppendLine("| $($r.Criterion) | $($r.Target) | $(($r.Observed -replace '\|','/')) | $($r.Result) |") }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Applications")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| Repo | Namespace | Identity access | Images in ACR | Latest tags | Running image | Ready |")
[void]$sb.AppendLine("|---|---|---|---|---|---|---|")
foreach ($a in $appRows) { [void]$sb.AppendLine("| $($a.Repo) | $($a.Namespace) | $($a.Access) | $($a.ImagesInAcr) | $($a.LatestTags) | $($a.Running) | $($a.Ready) |") }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Queries for HAES (Entra log workspace)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Managed identity sign-ins by the deployment identity:")
[void]$sb.AppendLine('```kusto'); [void]$sb.AppendLine($kql); [void]$sb.AppendLine('```')
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Any app registration or federated credential written by GSL users since the POC started (expected: none):")
[void]$sb.AppendLine('```kusto')
[void]$sb.AppendLine("AuditLogs")
[void]$sb.AppendLine("| where TimeGenerated >= datetime($($start.ToString('yyyy-MM-ddTHH:mm:ssZ')))")
[void]$sb.AppendLine("| where OperationName in ('Add application', 'Update application', 'Add service principal')")
[void]$sb.AppendLine("| extend Actor = tostring(InitiatedBy.user.userPrincipalName), Target = tostring(TargetResources[0].displayName)")
[void]$sb.AppendLine("| where Target startswith 'workflowapp' or Actor in~ ('<gsl engineer UPNs>')")
[void]$sb.AppendLine("| project TimeGenerated, OperationName, Actor, Target, Result")
[void]$sb.AppendLine('```')
$sb.ToString() | Set-Content -Path $md -Encoding UTF8
Write-Host "`nEvidence report: $md" -ForegroundColor Cyan
