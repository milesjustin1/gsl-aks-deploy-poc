<#
.SYNOPSIS
    Onboards one GitHub repo to the shared AKS deployment identity. No Entra changes.

.DESCRIPTION
    For repo <org>/<AppRepo> this script:
      1. Creates namespace <app> (repo name, lower-cased) with a ResourceQuota and LimitRange.
      2. Gives the deployment identity write access to THAT namespace only:
           Azure RBAC clusters : 'Azure Kubernetes Service RBAC Writer' at <aksId>/namespaces/<app>
           Kubernetes RBAC     : RoleBinding to ClusterRole 'edit' for the identity's object ID
      3. Switches the repo's GitHub OIDC subject to repository_owner_id + job_workflow_ref, so
         tokens from this repo can match the identity's single federated credential, but only
         when they come from the central workflow.
      4. Creates the 'development' GitHub environment in the repo (add required reviewers in the UI).
    It then reminds you to add the repo name to ALLOWED_APPS in the central workflow (one PR).

    What it does NOT do: create an app registration, add a federated credential, or touch Entra.

    WARNING for repos that already sign in to Azure with their own per-repo federated credential
    (for example wizard-created 'workflowapp-*' registrations): step 3 changes this repo's subject,
    so those older trusts stop matching. That is the intended cutover; plan it.

.NOTES
    Requires : az (logged in), kubectl, kubelogin (Entra clusters), gh (repo admin on the app repo)
    Rights   : RBAC Administrator (or Owner) on the AKS cluster; Kubernetes rights to create
               namespaces (e.g. Azure Kubernetes Service RBAC Cluster Admin). No Entra role.
    Idempotent; supports -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$AppRepo,
    [string]$StatePath = (Join-Path $PSScriptRoot "poc-state.json"),
    [string]$Environment = "development",
    [string]$QuotaCpuRequests = "2",
    [string]$QuotaMemoryRequests = "4Gi",
    [string]$QuotaCpuLimits = "4",
    [string]$QuotaMemoryLimits = "8Gi",
    [int]$QuotaPods = 20,
    [switch]$SkipGitHub,
    [switch]$SkipReminders
)

$ErrorActionPreference = "Stop"

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$AzArgs)
    $out = & az @AzArgs -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($AzArgs -join ' ') failed: $(($out | Out-String).Trim())" }
    $text = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}
function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function ConvertTo-AppName {
    # Must match the central workflow's derivation exactly.
    param([string]$Repo)
    $n = $Repo.ToLowerInvariant() -replace '[^a-z0-9-]+', '-'
    $n = $n.Trim('-')
    if ($n.Length -gt 63) { $n = $n.Substring(0, 63) }
    return $n
}

if (-not (Test-Path $StatePath)) { throw "State file not found: $StatePath. Run New-GslDeployIdentity.ps1 first." }
$s = Get-Content $StatePath -Raw | ConvertFrom-Json
$app = ConvertTo-AppName $AppRepo
Write-Host "App repo  : $($s.gitHubOrg)/$AppRepo"
Write-Host "Namespace : $app"
Write-Host "Identity  : $($s.identityName) ($($s.clientId))"

Invoke-Az account set --subscription $s.subscriptionId | Out-Null

# ---------------------------------------------------------------- 1. Namespace
Write-Step "Namespace, quota and default limits (admin kubeconfig via Entra)"
$kc = Join-Path ([System.IO.Path]::GetTempPath()) ("gsl-onboard-" + [guid]::NewGuid().ToString("N") + ".kubeconfig")
try {
    Invoke-Az aks get-credentials -g $s.aksResourceGroup -n $s.aksName --file $kc --overwrite-existing | Out-Null
    if (Get-Command kubelogin -ErrorAction SilentlyContinue) { & kubelogin convert-kubeconfig -l azurecli --kubeconfig $kc | Out-Null }

    $nsYaml = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $app
  labels:
    gsl.noaa.gov/app: "$app"
    gsl.noaa.gov/repo: "$AppRepo"
    gsl.noaa.gov/managed-by: "gsl-deploy"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: $app-quota
  namespace: $app
spec:
  hard:
    requests.cpu: "$QuotaCpuRequests"
    requests.memory: "$QuotaMemoryRequests"
    limits.cpu: "$QuotaCpuLimits"
    limits.memory: "$QuotaMemoryLimits"
    pods: "$QuotaPods"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: $app-defaults
  namespace: $app
spec:
  limits:
    - type: Container
      defaultRequest: { cpu: 100m, memory: 128Mi }
      default: { cpu: 500m, memory: 512Mi }
"@
    if ($PSCmdlet.ShouldProcess($app, "kubectl apply namespace + quota + limitrange")) {
        $nsYaml | & kubectl --kubeconfig $kc apply -f -
        if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed (do you have rights to create namespaces?)" }
    }

    # ------------------------------------------------------------ 2. Namespace access
    Write-Step "Namespace-scoped write access for the deployment identity"
    if ($s.aksAzureRbac) {
        $scope = "$($s.aksId)/namespaces/$app"
        $role = "Azure Kubernetes Service RBAC Writer"
        $existing = @(Invoke-Az role assignment list --assignee $s.principalId --scope $scope --role $role)
        if ($existing.Count) { Write-Host "  [exists] $role @ $scope" }
        elseif ($PSCmdlet.ShouldProcess($scope, "Assign $role")) {
            Invoke-Az role assignment create --assignee-object-id $s.principalId --assignee-principal-type ServicePrincipal `
                --role $role --scope $scope | Out-Null
            Write-Host "  [added]  $role @ $scope"
            Write-Host "  (Azure RBAC for Kubernetes can take up to 5 minutes to apply.)"
        }
    }
    else {
        $rb = @"
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gsl-deploy-identity
  namespace: $app
subjects:
  - kind: User
    apiGroup: rbac.authorization.k8s.io
    name: "$($s.principalId)"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
"@
        if ($PSCmdlet.ShouldProcess($app, "RoleBinding edit -> identity object ID")) {
            $rb | & kubectl --kubeconfig $kc apply -f -
            if ($LASTEXITCODE -ne 0) { throw "RoleBinding apply failed" }
        }
    }
}
finally {
    Remove-Item $kc -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 3-4. GitHub
if (-not $SkipGitHub) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "gh not found (or use -SkipGitHub and do steps 3-4 in the UI)" }
    $full = "$($s.gitHubOrg)/$AppRepo"

    Write-Step "GitHub OIDC subject for $full"
    $current = & gh api "repos/$full/actions/oidc/customization/sub" 2>$null | ConvertFrom-Json
    Write-Host "  Before: use_default=$($current.use_default) keys=$(@($current.include_claim_keys) -join ',')"
    if ($PSCmdlet.ShouldProcess($full, "Set OIDC subject to repository_owner_id + job_workflow_ref")) {
        '{"use_default":false,"include_claim_keys":["repository_owner_id","job_workflow_ref"]}' |
            & gh api -X PUT "repos/$full/actions/oidc/customization/sub" --input - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not set the OIDC subject (need admin on $full)" }
        $after = & gh api "repos/$full/actions/oidc/customization/sub" | ConvertFrom-Json
        Write-Host "  After : use_default=$($after.use_default) keys=$(@($after.include_claim_keys) -join ',')"
    }

    Write-Step "GitHub environment '$Environment' in $full"
    if ($PSCmdlet.ShouldProcess($full, "Create environment $Environment")) {
        & gh api -X PUT "repos/$full/environments/$Environment" | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not create the environment; create it in Settings > Environments." }
        else { Write-Host "  Ready. Add required reviewers in Settings > Environments > $Environment to gate deploys." }
    }
}

if (-not $SkipReminders) {
Write-Step "Remaining manual steps"
Write-Host "  a. PR to $($s.gitHubOrg)/$($s.centralRepo): add '$AppRepo' under ALLOWED_APPS in .github/workflows/$($s.workflowFile)"
Write-Host "  b. In ${AppRepo}: add .github/workflows/deploy.yml (app-template) and manifests using __IMAGE__ / __APP__"
Write-Host "  c. Push to main (or run the workflow manually). Expected: image $($s.acrLoginServer)/$($app):<sha> running in namespace $app"
}
Write-Host "`n  Entra objects created by this onboarding: 0" -ForegroundColor Green
