<#
.SYNOPSIS
    Rolls back the POC: per-app access and OIDC settings, then (optionally) the identity.

.DESCRIPTION
    -AppRepo <names>   : removes the identity's namespace role (or RoleBinding), resets each repo's
                         OIDC subject to GitHub's default, and with -DeleteNamespaces deletes the namespaces.
    -RemoveIdentity    : also removes the identity's shared role assignments and deletes the managed
                         identity (its federated credential goes with it).
    Images in ACR are left in place. Nothing in Entra is touched (nothing was created there).
    Supports -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string[]]$AppRepo = @(),
    [switch]$DeleteNamespaces,
    [switch]$RemoveIdentity,
    [string]$StatePath = (Join-Path $PSScriptRoot "poc-state.json")
)
$ErrorActionPreference = "Stop"

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$AzArgs)
    $out = & { $ErrorActionPreference = 'Continue'; & az @AzArgs -o json 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "az $($AzArgs -join ' ') failed: $(($out | Out-String).Trim())" }
    $text = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}
function ConvertTo-AppName { param([string]$Repo) $n = ($Repo.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-'); if ($n.Length -gt 63) { $n = $n.Substring(0, 63) }; $n }

$s = Get-Content $StatePath -Raw | ConvertFrom-Json
Invoke-Az account set --subscription $s.subscriptionId | Out-Null

$kc = $null
if ($AppRepo.Count -and (-not $s.aksAzureRbac -or $DeleteNamespaces)) {
    $kc = Join-Path ([System.IO.Path]::GetTempPath()) ("gsl-remove-" + [guid]::NewGuid().ToString("N") + ".kubeconfig")
    Invoke-Az aks get-credentials -g $s.aksResourceGroup -n $s.aksName --file $kc --overwrite-existing | Out-Null
    if (Get-Command kubelogin -ErrorAction SilentlyContinue) { & kubelogin convert-kubeconfig -l azurecli --kubeconfig $kc | Out-Null }
}

try {
    foreach ($repo in $AppRepo) {
        $app = ConvertTo-AppName $repo
        Write-Host "`n==> $repo (namespace $app)" -ForegroundColor Cyan
        if ($s.aksAzureRbac) {
            $scope = "$($s.aksId)/namespaces/$app"
            foreach ($ra in @(Invoke-Az role assignment list --assignee $s.principalId --scope $scope)) {
                if ($PSCmdlet.ShouldProcess($scope, "Remove $($ra.roleDefinitionName)")) { Invoke-Az role assignment delete --ids $ra.id | Out-Null; Write-Host "  removed $($ra.roleDefinitionName)" }
            }
        }
        elseif ($PSCmdlet.ShouldProcess($app, "Delete RoleBinding gsl-deploy-identity")) {
            & kubectl --kubeconfig $kc delete rolebinding gsl-deploy-identity -n $app --ignore-not-found
        }
        if ($DeleteNamespaces -and $PSCmdlet.ShouldProcess($app, "Delete namespace and everything in it")) {
            & kubectl --kubeconfig $kc delete namespace $app --ignore-not-found
        }
        if ((Get-Command gh -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess("$($s.gitHubOrg)/$repo", "Reset OIDC subject to default")) {
            '{"use_default":true}' | & gh api -X PUT "repos/$($s.gitHubOrg)/$repo/actions/oidc/customization/sub" --input - | Out-Null
            Write-Host "  OIDC subject reset to default"
        }
        Write-Host "  Also remove '$repo' from ALLOWED_APPS in the central workflow."
    }

    if ($RemoveIdentity) {
        Write-Host "`n==> Identity $($s.identityName)" -ForegroundColor Cyan
        foreach ($ra in @(Invoke-Az role assignment list --assignee $s.principalId --all)) {
            if ($PSCmdlet.ShouldProcess($ra.scope, "Remove $($ra.roleDefinitionName)")) { Invoke-Az role assignment delete --ids $ra.id | Out-Null; Write-Host "  removed $($ra.roleDefinitionName) @ $($ra.scope)" }
        }
        if ($PSCmdlet.ShouldProcess($s.identityName, "Delete managed identity")) {
            Invoke-Az identity delete -g $s.resourceGroup -n $s.identityName | Out-Null
            Write-Host "  identity deleted"
        }
    }
}
finally { if ($kc) { Remove-Item $kc -Force -ErrorAction SilentlyContinue } }
