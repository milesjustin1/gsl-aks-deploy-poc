<#
.SYNOPSIS
    Deletes the lab: the Azure resource group (cluster, registry, identity, workspace) and optionally the GitHub repos.
.EXAMPLE
    .\Remove-GslPocLab.ps1 -DeleteRepos      # needs: gh auth refresh -s delete_repo
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [switch]$DeleteRepos,
    [string[]]$Repos = @("gsl-deploy", "hello-web", "forecast-api", "obs-ingest", "station-map", "rogue-app"),
    [string]$StatePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "platform/poc-state.json")
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\LabCommon.ps1"
$s = Get-LabState $StatePath
if (-not $s.PSObject.Properties["lab"]) { throw "The state file is not a lab state file. Refusing to delete $($s.resourceGroup)." }

if ($PSCmdlet.ShouldProcess($s.resourceGroup, "Delete resource group and everything in it")) {
    Invoke-Az account set --subscription $s.subscriptionId | Out-Null
    Invoke-Az group delete -n $s.resourceGroup --yes --no-wait | Out-Null
    Write-Ok "Deleting $($s.resourceGroup) (runs in the background, ~10 minutes)"
}
& { $ErrorActionPreference = 'Continue'; & kubectl config delete-context $s.aksName 2>$null } | Out-Null

if ($DeleteRepos) {
    foreach ($r in $Repos) {
        $full = "$($s.gitHubOrg)/$r"
        if ((Test-GhRepo $full) -and $PSCmdlet.ShouldProcess($full, "Delete GitHub repo")) { Invoke-Gh repo delete $full --yes | Out-Null; Write-Ok "Deleted $full" }
    }
}
Rename-Item $StatePath "$StatePath.removed-$(Get-Date -Format yyyyMMddHHmm)" -ErrorAction SilentlyContinue
Write-Ok "Lab removed. Nothing to clean up in Entra (nothing was created there)."
