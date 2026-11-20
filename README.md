# Shared AKS Deployment Identity – POC Kit

Lets many GitHub app repositories deploy to a shared AKS cluster through **one** user-assigned managed identity and **one** federated credential (GitHub OIDC). No client secrets, no Entra app registration per app, and each app is confined to its own Kubernetes namespace.

How it works: only a central reusable workflow (`gsl-deploy/.github/workflows/deploy-to-aks.yml`) is trusted by the identity. App repos call that workflow; it checks the caller against an `ALLOWED_APPS` list and deploys into that app's namespace, where Azure RBAC for Kubernetes limits what the identity can touch.

## What's here

| Path | What it is |
|---|---|
| `platform/New-GslDeployIdentity.ps1` | One-time setup: managed identity, one federated credential, shared roles (AcrPush, Reader on ACR, AKS Cluster User) |
| `platform/Add-GslApp.ps1` | Onboards one app repo: namespace, quota, namespace-scoped RBAC, OIDC subject opt-in. No Entra changes |
| `platform/Remove-GslPoc.ps1` | Rollback: per-app access and OIDC settings, then optionally the identity |
| `github/gsl-deploy/` | Central reusable deploy workflow |
| `github/app-template/` | What each app repo adds: caller workflow + manifests |
| `github/sample-app-gsl-poc-hello/` | Minimal sample app built from the template |
| `github/negative-tests/` | Workflows that should **fail** (direct sign-in, namespace escape) |
| `tests/Get-GslPocEvidence.ps1` | Read-only evidence report against the POC acceptance criteria |
| `lab/` | Builds the whole POC in your own subscription and GitHub account, with four synthetic apps and automated tests |

Files under `github/` contain placeholders (`__AZURE_CLIENT_ID__`, `__AZURE_TENANT_ID__`, `__AZURE_SUBSCRIPTION_ID__`, `__GITHUB_ORG__`, `__ACR_NAME__`, `__AKS_RG__`, `__AKS_NAME__`). The setup script fills them in and writes the result to `rendered/`.

## Prerequisites

PowerShell 7 (5.1 works), Azure CLI 2.60+, GitHub CLI, kubectl and kubelogin. Azure rights: Managed Identity Contributor + Role Based Access Control Administrator (or Owner) on the resource group, registry and cluster. No Entra directory role is needed.

## Try it in a lab

```powershell
az login; az account set --subscription <subscription id>
gh auth login
cd lab
.\New-GslPocLab.ps1 -SubscriptionId <subscription id> -GitHubOwner <github user or org>
.\Publish-GslLabRepos.ps1
.\Invoke-GslLabTests.ps1
.\Remove-GslPocLab.ps1 -DeleteRepos       # teardown (resource group + lab repos)
```

## Use it against an existing cluster

```powershell
cd platform
.\New-GslDeployIdentity.ps1 -SubscriptionId <id> -ResourceGroup <rg> -AksName <cluster> -AcrName <registry> -GitHubOrg <org> -RenderKitTo ..\rendered -WhatIf
.\New-GslDeployIdentity.ps1 -SubscriptionId <id> -ResourceGroup <rg> -AksName <cluster> -AcrName <registry> -GitHubOrg <org> -RenderKitTo ..\rendered
.\Add-GslApp.ps1 -AppRepo <app-repo-name>
```

Then copy `rendered/gsl-deploy` into your central repo and `rendered/app-template` into each app repo.

## Generated files (not committed)

`platform/poc-state.json` and `rendered/` hold the tenant, subscription and client IDs of whoever ran the scripts. Both are in `.gitignore`.

## Disclaimer

Sample code provided as-is, without warranty or support. Review and test before use in any production environment.
