<#
.SYNOPSIS
    Builds the GSL deployment-identity lab in your own subscription (e.g. a Visual Studio subscription).

.DESCRIPTION
    Creates a small, GSL-shaped environment and then runs the real POC setup script against it:
      - Resource group, Azure Container Registry (Basic), Log Analytics workspace
      - AKS cluster built to the practices the GSL assessment recommends:
          Entra integration + Azure RBAC for Kubernetes, local accounts disabled,
          OIDC issuer + workload identity, Azure CNI Overlay with Cilium, app routing add-on,
          patch auto-upgrade, NodeImage OS upgrades, ACR attached (kubelet AcrPull),
          control-plane audit logs (kube-audit-admin, guard) to Log Analytics
      - You (the signed-in user) get 'Azure Kubernetes Service RBAC Cluster Admin' so you can create namespaces
      - Records how many Entra app registrations you own now (baseline for the "zero new apps" evidence)
      - Runs ..\platform\New-GslDeployIdentity.ps1: managed identity, ONE federated credential, shared roles,
        and renders the GitHub files with your values into ..\rendered

    Cost: one small node pool. Stop the cluster between demos (az aks stop) and delete the resource
    group when finished (Remove-GslPocLab.ps1).

.EXAMPLE
    .\New-GslPocLab.ps1 -SubscriptionId <your VS subscription id> -GitHubOwner <github-owner>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$GitHubOwner,
    [string]$Location = "eastus2",
    [string]$ResourceGroup = "rg-gsl-poc-lab",
    [string]$AksName = "aks-gsl-poc-lab",
    [string]$AcrName,
    [string]$NodeVmSize = "Standard_D4as_v5",
    [int]$NodeCount = 1,
    [string]$IdentityName = "uami-gsl-aks-deploy-dev",
    [string]$CentralRepo = "gsl-deploy",
    [string]$StatePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "platform/poc-state.json")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\LabCommon.ps1"

if (-not $AcrName) { $AcrName = "acrgsllab" + ($SubscriptionId -replace '-', '').Substring(0, 8).ToLowerInvariant() }

Write-Step "Tools and sign-in"
foreach ($t in @("az", "kubectl", "kubelogin", "gh", "git")) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t is not installed or not on PATH (see the lab guide prerequisites)" }
}
Invoke-Az account set --subscription $SubscriptionId | Out-Null
$acct = Invoke-Az account show
Write-Ok "Azure: $($acct.name) ($($acct.id)) as $($acct.user.name)"
$ghUser = Assert-GitHubOwnerUsable -Owner $GitHubOwner

Write-Step "Resource providers"
foreach ($ns in @("Microsoft.ContainerService", "Microsoft.ContainerRegistry", "Microsoft.ManagedIdentity", "Microsoft.OperationalInsights", "Microsoft.Insights")) {
    $state = (Invoke-Az provider show -n $ns).registrationState
    if ($state -ne "Registered") { Write-Info "Registering $ns ..."; Invoke-Az provider register -n $ns --wait | Out-Null }
    Write-Ok "$ns registered"
}

Write-Step "Resource group, registry, Log Analytics"
Invoke-Az group create -n $ResourceGroup -l $Location --tags "purpose=gsl-deploy-identity-poc-lab" | Out-Null
Write-Ok "Resource group $ResourceGroup ($Location)"
$acr = $null
try { $acr = Invoke-Az acr show -g $ResourceGroup -n $AcrName } catch { }
if (-not $acr) { $acr = Invoke-Az acr create -g $ResourceGroup -n $AcrName --sku Basic --admin-enabled false }
Write-Ok "Registry $($acr.loginServer) (admin user disabled)"
$lawName = "law-gsl-poc-lab"
$law = $null
try { $law = Invoke-Az monitor log-analytics workspace show -g $ResourceGroup -n $lawName } catch { }
if (-not $law) { $law = Invoke-Az monitor log-analytics workspace create -g $ResourceGroup -n $lawName -l $Location }
Write-Ok "Log Analytics $lawName"

Write-Step "AKS cluster $AksName (about 10 minutes on first run)"
$aks = $null
try { $aks = Invoke-Az aks show -g $ResourceGroup -n $AksName } catch { }
if (-not $aks) {
    $aks = Invoke-Az aks create -g $ResourceGroup -n $AksName -l $Location `
        --tier free --node-count "$NodeCount" --node-vm-size $NodeVmSize `
        --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium `
        --enable-aad --enable-azure-rbac --disable-local-accounts `
        --enable-oidc-issuer --enable-workload-identity `
        --enable-app-routing `
        --attach-acr $acr.id `
        --auto-upgrade-channel patch --node-os-upgrade-channel NodeImage `
        --generate-ssh-keys --tags "purpose=gsl-deploy-identity-poc-lab"
    Write-Ok "Created $AksName (Kubernetes $($aks.currentKubernetesVersion))"
}
else {
    if ($aks.powerState.code -eq "Stopped") { Write-Info "Cluster is stopped; starting..."; Invoke-Az aks start -g $ResourceGroup -n $AksName | Out-Null }
    Write-Ok "Exists: $AksName (Kubernetes $($aks.currentKubernetesVersion))"
}
if (-not $aks.aadProfile.enableAzureRbac) { throw "$AksName exists but does not use Azure RBAC for Kubernetes. Delete it or use a new -AksName." }

Write-Step "Control-plane audit logs -> $lawName"
$logsFile = Join-Path ([System.IO.Path]::GetTempPath()) "gsl-lab-logs.json"
'[{"category":"kube-audit-admin","enabled":true},{"category":"guard","enabled":true}]' | Set-Content -Path $logsFile -Encoding ASCII
$existingDiag = @(Invoke-Az monitor diagnostic-settings list --resource $aks.id)
if (-not ($existingDiag | Where-Object { $_.name -eq "aks-audit-to-law" })) {
    Invoke-Az monitor diagnostic-settings create --name aks-audit-to-law --resource $aks.id --workspace $law.id `
        --export-to-resource-specific true --logs "@$logsFile" | Out-Null
}
Write-Ok "kube-audit-admin and guard -> $lawName (table AKSAuditAdmin)"

Write-Step "Your cluster access (namespace creation needs cluster admin)"
$me = Invoke-Az ad signed-in-user show
$ra = @(Invoke-Az role assignment list --assignee $me.id --scope $aks.id --role "Azure Kubernetes Service RBAC Cluster Admin")
if (-not $ra.Count) {
    Invoke-Az role assignment create --assignee-object-id $me.id --assignee-principal-type User `
        --role "Azure Kubernetes Service RBAC Cluster Admin" --scope $aks.id | Out-Null
}
Write-Ok "Azure Kubernetes Service RBAC Cluster Admin -> $($me.userPrincipalName)"
Invoke-Az aks get-credentials -g $ResourceGroup -n $AksName --overwrite-existing | Out-Null
& kubelogin convert-kubeconfig -l azurecli | Out-Null
$ok = $false
for ($i = 1; $i -le 20 -and -not $ok; $i++) {
    & { $ErrorActionPreference = 'Continue'; & kubectl get namespaces --request-timeout=20s *> $null }
    if ($LASTEXITCODE -eq 0) { $ok = $true } else { Write-Info "Waiting for Azure RBAC to apply ($i/20)..."; Start-Sleep -Seconds 30 }
}
if (-not $ok) { throw "kubectl still cannot list namespaces. Check 'az login' and the role assignment, then re-run." }
Write-Ok "kubectl works (context $AksName)"

Write-Step "Baseline: Entra app registrations you own"
$baseline = Get-OwnedAppCount
Write-Ok "$baseline app registration(s) owned by $($me.userPrincipalName) before the POC"

Write-Step "POC identity setup (the same script GSL will run)"
& (Join-Path $KitRoot "platform/New-GslDeployIdentity.ps1") `
    -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -IdentityName $IdentityName `
    -AksName $AksName -AcrName $AcrName -GitHubOrg $GitHubOwner -CentralRepo $CentralRepo `
    -RenderKitTo (Join-Path $KitRoot "rendered") -StatePath $StatePath

Set-LabStateValue -StatePath $StatePath -Values @{
    lab                 = $true
    ownedAppsBaseline   = $baseline
    workspaceId         = $law.id
    workspaceCustomerId = $law.customerId
    location            = $Location
}

Write-Step "Lab ready"
Write-Host "  Next: .\Publish-GslLabRepos.ps1     (creates $GitHubOwner/$CentralRepo + 3 app repos and deploys them)"
Write-Host "  Pause costs between demos: az aks stop -g $ResourceGroup -n $AksName"
