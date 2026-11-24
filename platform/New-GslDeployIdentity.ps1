<#
.SYNOPSIS
    One-time setup of the shared AKS deployment identity (no Entra app registration).

.DESCRIPTION
    Creates (or reuses) a user-assigned managed identity and gives it exactly ONE
    federated credential that trusts the central GitHub workflow:

        issuer  : https://token.actions.githubusercontent.com
        subject : repository_owner_id:<org id>:job_workflow_ref:<org>/<central repo>/.github/workflows/<file>@refs/heads/<branch>
        audience: api://AzureADTokenExchange

    Then assigns the minimum Azure roles that every app shares:
        AcrPush   on the container registry  (push images)
        Reader    on the container registry  (lets 'az acr login' / 'az acr show' resolve the registry)
        Azure Kubernetes Service Cluster User Role  on the AKS cluster (get user kubeconfig)
    Namespace write access is granted per app by Add-GslApp.ps1.

    Every operation is an Azure Resource Manager call. Nothing is written to Entra
    through Microsoft Graph, so no directory role (Application Administrator /
    Application Developer) is needed.

    Optional -RenderKitTo copies the GitHub files from this kit with the
    placeholders (__AZURE_CLIENT_ID__ etc.) filled in.

.NOTES
    Requires : Azure CLI 2.60+ (az login done, correct cloud), GitHub CLI 'gh' (or -GitHubOrgId)
    Rights   : Managed Identity Contributor + Role Based Access Control Administrator
               (or Owner) on the resource group / registry / cluster. No Entra role.
    Idempotent: safe to re-run. Supports -WhatIf.
    Version  : 1.0  (GSL deployment identity POC)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$IdentityName   = "uami-gsl-aks-deploy-dev",
    [string]$Location,
    [Parameter(Mandatory)][string]$AksName,
    [string]$AksResourceGroup,
    [Parameter(Mandatory)][string]$AcrName,
    [string]$AcrResourceGroup,
    [Parameter(Mandatory)][string]$GitHubOrg,
    [string]$GitHubOrgId,
    [string]$CentralRepo    = "gsl-deploy",
    [string]$WorkflowFile   = "deploy-to-aks.yml",
    [string]$Branch         = "main",
    [string]$RenderKitTo,
    [string]$StatePath      = (Join-Path $PSScriptRoot "poc-state.json")
)

$ErrorActionPreference = "Stop"
$Issuer   = "https://token.actions.githubusercontent.com"
$Audience = "api://AzureADTokenExchange"
$FicName  = "github-central-deploy-$Branch"

function Invoke-Az {
    # Runs az, returns parsed JSON (or $null), throws with az's message on failure.
    param([Parameter(ValueFromRemainingArguments)][string[]]$AzArgs)
    $out = & { $ErrorActionPreference = 'Continue'; & az @AzArgs -o json 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "az $($AzArgs -join ' ') failed: $(($out | Out-String).Trim())" }
    $text = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }

if (-not $AksResourceGroup) { $AksResourceGroup = $ResourceGroup }
if (-not $AcrResourceGroup) { $AcrResourceGroup = $ResourceGroup }

Write-Step "Context"
Invoke-Az account set --subscription $SubscriptionId | Out-Null
$acct = Invoke-Az account show
Write-Host "  Subscription : $($acct.name) ($($acct.id))"
Write-Host "  Tenant       : $($acct.tenantId)"
Write-Host "  Signed in as : $($acct.user.name)"
$cloud = (Invoke-Az cloud show).name

$aks = Invoke-Az aks show -g $AksResourceGroup -n $AksName
$acr = Invoke-Az acr show -g $AcrResourceGroup -n $AcrName
if (-not $Location) { $Location = (Invoke-Az group show -n $ResourceGroup).location }
Write-Host "  AKS          : $($aks.id)"
Write-Host "  ACR          : $($acr.id) ($($acr.loginServer))"

$azureRbac = [bool]$aks.aadProfile.enableAzureRbac
Write-Host "  AKS authz    : $(if ($azureRbac) { 'Azure RBAC for Kubernetes (namespace role assignments)' } else { 'Kubernetes RBAC (RoleBindings to the identity object ID)' })"
if ($aks.apiServerAccessProfile.enablePrivateCluster -or @($aks.apiServerAccessProfile.authorizedIpRanges | Where-Object { $_ }).Count -gt 0) {
    Write-Warning "API server is private or IP-restricted. GitHub-hosted runners cannot reach it; use a self-hosted runner (workflow input 'runner')."
}
if ($acr.publicNetworkAccess -eq "Disabled" -or $acr.networkRuleSet.defaultAction -eq "Deny") {
    Write-Warning "Registry blocks public network access. GitHub-hosted runners cannot push; use a self-hosted runner in the VNet."
}

Write-Step "GitHub owner ID (org or user; used in the trust subject)"
if (-not $GitHubOrgId) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "gh not found. Install GitHub CLI or pass -GitHubOrgId." }
    # users/<login> works for organizations and personal accounts alike
    $GitHubOrgId = (& gh api "users/$GitHubOrg" --jq .id).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $GitHubOrgId) { throw "Could not read org ID for $GitHubOrg (gh auth login?)" }
}
$Subject = "repository_owner_id:$($GitHubOrgId):job_workflow_ref:$GitHubOrg/$CentralRepo/.github/workflows/$($WorkflowFile)@refs/heads/$Branch"
Write-Host "  $GitHubOrg = $GitHubOrgId"
Write-Host "  Subject    = $Subject"

Write-Step "Managed identity $IdentityName"
$mi = $null
try { $mi = Invoke-Az identity show -g $ResourceGroup -n $IdentityName } catch { $mi = $null }
if (-not $mi) {
    if ($PSCmdlet.ShouldProcess($IdentityName, "Create user-assigned managed identity")) {
        $mi = Invoke-Az identity create -g $ResourceGroup -n $IdentityName -l $Location `
            --tags "purpose=github-oidc-aks-deploy" "owner=OAR-GSL" "poc=reusable-deploy-identity"
        Write-Host "  Created. Waiting 30s for the service principal to replicate before role assignments..."
        Start-Sleep -Seconds 30
    }
}
else { Write-Host "  Exists (reused)." }
if (-not $mi) { Write-Host "  (WhatIf) stopping before federated credential and roles."; return }
Write-Host "  clientId    : $($mi.clientId)"
Write-Host "  principalId : $($mi.principalId)"

Write-Step "Federated credential (exactly one)"
$fics = @(Invoke-Az identity federated-credential list -g $ResourceGroup --identity-name $IdentityName)
$match = $fics | Where-Object { $_.subject -eq $Subject -and $_.issuer -eq $Issuer }
if ($match) { Write-Host "  Exists: $($match.name)" }
elseif ($PSCmdlet.ShouldProcess($IdentityName, "Add federated credential $FicName")) {
    Invoke-Az identity federated-credential create -g $ResourceGroup --identity-name $IdentityName `
        --name $FicName --issuer $Issuer --subject $Subject --audiences $Audience | Out-Null
    Write-Host "  Added: $FicName"
}
$others = @($fics | Where-Object { $_.subject -ne $Subject })
if ($others.Count) { Write-Warning "$($others.Count) other federated credential(s) exist on this identity: $(($others | ForEach-Object { $_.subject }) -join '; ')" }

Write-Step "Role assignments (shared by all apps)"
function Grant-Role {
    param([string]$Role, [string]$Scope)
    $existing = @(Invoke-Az role assignment list --assignee $mi.principalId --scope $Scope --role $Role)
    if ($existing.Count) { Write-Host "  [exists] $Role @ $Scope"; return }
    if ($PSCmdlet.ShouldProcess($Scope, "Assign $Role")) {
        Invoke-Az role assignment create --assignee-object-id $mi.principalId --assignee-principal-type ServicePrincipal `
            --role $Role --scope $Scope | Out-Null
        Write-Host "  [added]  $Role @ $Scope"
    }
}
Grant-Role -Role "AcrPush" -Scope $acr.id
Grant-Role -Role "Reader"  -Scope $acr.id
Grant-Role -Role "Azure Kubernetes Service Cluster User Role" -Scope $aks.id

$broad = @(Invoke-Az role assignment list --assignee $mi.principalId --all) |
    Where-Object { $_.roleDefinitionName -in @("Owner","Contributor","User Access Administrator","Role Based Access Control Administrator","Azure Kubernetes Service RBAC Cluster Admin","Azure Kubernetes Service Cluster Admin Role") }
if ($broad) { Write-Warning "Identity holds broad roles that the POC does not need: $(($broad | ForEach-Object { "$($_.roleDefinitionName) @ $($_.scope)" }) -join '; ')" }

$state = [ordered]@{
    createdUtc        = (Get-Date).ToUniversalTime().ToString("o")
    cloud             = $cloud
    tenantId          = $acct.tenantId
    subscriptionId    = $acct.id
    resourceGroup     = $ResourceGroup
    identityName      = $IdentityName
    identityId        = $mi.id
    clientId          = $mi.clientId
    principalId       = $mi.principalId
    federatedSubject  = $Subject
    aksId             = $aks.id
    aksName           = $AksName
    aksResourceGroup  = $AksResourceGroup
    aksAzureRbac      = $azureRbac
    acrId             = $acr.id
    acrName           = $AcrName
    acrLoginServer    = $acr.loginServer
    gitHubOrg         = $GitHubOrg
    gitHubOrgId       = $GitHubOrgId
    centralRepo       = $CentralRepo
    workflowFile      = $WorkflowFile
    branch            = $Branch
}
if (Test-Path $StatePath) {
    $old = Get-Content $StatePath -Raw | ConvertFrom-Json
    if ($old.createdUtc) {   # keep the original POC start time
        $state.createdUtc = if ($old.createdUtc -is [datetime]) { $old.createdUtc.ToUniversalTime().ToString("o") } else { [string]$old.createdUtc }
    }
}
$state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
Write-Host "`n  State saved: $StatePath (POC start $($state.createdUtc))"

if ($RenderKitTo) {
    Write-Step "Rendering GitHub files to $RenderKitTo"
    $src = Join-Path (Split-Path $PSScriptRoot -Parent) "github"
    $map = @{
        "__AZURE_CLIENT_ID__"       = $mi.clientId
        "__AZURE_TENANT_ID__"       = $acct.tenantId
        "__AZURE_SUBSCRIPTION_ID__" = $acct.id
        "__GITHUB_ORG__"            = $GitHubOrg
        "__ACR_NAME__"              = $AcrName
        "__AKS_RG__"                = $AksResourceGroup
        "__AKS_NAME__"              = $AksName
    }
    Get-ChildItem -Path $src -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length).TrimStart('\', '/')
        $dest = Join-Path $RenderKitTo $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        if ($_.Extension -in @(".yml", ".yaml", ".md")) {
            $text = Get-Content $_.FullName -Raw
            foreach ($k in $map.Keys) { $text = $text.Replace($k, [string]$map[$k]) }
            [System.IO.File]::WriteAllText($dest, $text)
        }
        else { Copy-Item $_.FullName $dest -Force }
    }
    Write-Host "  Done. Copy $(Join-Path $RenderKitTo "gsl-deploy") into the $GitHubOrg/$CentralRepo repo."
}

Write-Step "Summary"
[pscustomobject]@{
    Identity           = $IdentityName
    ClientId           = $mi.clientId
    FederatedCredential= $Subject
    EntraAppsCreated   = 0
    Next               = "Create $GitHubOrg/$CentralRepo with the central workflow, then run Add-GslApp.ps1 per app."
} | Format-List
