# Shared helpers for the GSL deployment-identity lab scripts. Dot-source: . "$PSScriptRoot\LabCommon.ps1"

$script:KitRoot = Split-Path $PSScriptRoot -Parent

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Info { param([string]$Text) Write-Host "    $Text" -ForegroundColor Gray }

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$AzArgs)
    $out = & az @AzArgs -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($AzArgs[0..([Math]::Min(3, $AzArgs.Count - 1))] -join ' ') failed: $((($out | Out-String).Trim()) -replace '\s+', ' ')" }
    $text = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Invoke-Gh {
    param([Parameter(ValueFromRemainingArguments)][string[]]$GhArgs)
    $out = & gh @GhArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs -join ' ') failed: $((($out | Out-String).Trim()) -replace '\s+', ' ')" }
    return (($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n")
}

function Invoke-Git {
    param([string]$Dir, [Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $out = & git -C $Dir @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $((($out | Out-String).Trim()) -replace '\s+', ' ')" }
    return (($out | ForEach-Object { "$_" }) -join "`n")
}

function Get-LabState {
    param([string]$StatePath)
    if (-not (Test-Path $StatePath)) { throw "State file not found: $StatePath. Run New-GslPocLab.ps1 first." }
    return (Get-Content $StatePath -Raw | ConvertFrom-Json)
}

function Set-LabStateValue {
    param([string]$StatePath, [hashtable]$Values)
    $s = Get-Content $StatePath -Raw | ConvertFrom-Json
    foreach ($k in $Values.Keys) {
        if ($s.PSObject.Properties[$k]) { $s.$k = $Values[$k] }
        else { $s | Add-Member -NotePropertyName $k -NotePropertyValue $Values[$k] }
    }
    $s | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
}

function Get-GitIdentity {
    $login = (Invoke-Gh api user --jq .login).Trim()
    $id = (Invoke-Gh api user --jq .id).Trim()
    return [pscustomobject]@{ Name = $login; Email = "$id+$login@users.noreply.github.com" }
}

function Test-GhRepo {
    param([string]$Full)
    & gh repo view $Full --json name 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function New-GhRepo {
    param([string]$Full, [string]$Visibility, [string]$Description)
    if (Test-GhRepo $Full) { Write-Info "Repo exists: $Full"; return }
    $flag = if ($Visibility -eq "private") { "--private" } else { "--public" }
    Invoke-Gh repo create $Full $flag --description $Description | Out-Null
    Write-Ok "Created repo $Full ($Visibility)"
}

function New-TempDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("gsl-lab-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

function Get-RepoWorkingCopy {
    # Clones the repo (or initializes an empty one) into a temp folder and returns the path.
    param([string]$Full)
    $dir = New-TempDir
    $remote = "https://github.com/$Full.git"
    $heads = & git ls-remote --heads $remote 2>$null
    if ($heads) { Invoke-Git $dir clone --quiet $remote . | Out-Null }
    else {
        Invoke-Git $dir init --quiet | Out-Null
        Invoke-Git $dir checkout --quiet -b main | Out-Null
        Invoke-Git $dir remote add origin $remote | Out-Null
    }
    return $dir
}

function Copy-FolderContent {
    param([string]$From, [string]$To)
    Get-ChildItem -Path $From -Force | ForEach-Object { Copy-Item $_.FullName -Destination $To -Recurse -Force }
}

function Save-RepoChanges {
    # Commits everything in $Dir and pushes to $Branch. Returns $true if something was pushed.
    param([string]$Dir, [string]$Message, [string]$Branch = "main", $Identity)
    Invoke-Git $Dir add -A | Out-Null
    $status = Invoke-Git $Dir status --porcelain
    if (-not $status) { Write-Info "No changes to push"; return $false }
    Invoke-Git $Dir -c "user.name=$($Identity.Name)" -c "user.email=$($Identity.Email)" commit --quiet -m $Message | Out-Null
    Invoke-Git $Dir push --quiet origin "HEAD:refs/heads/$Branch" | Out-Null
    return $true
}

function Wait-GhRun {
    # Finds the first run of $Workflow created after $After and waits for it to finish.
    param([string]$Full, [string]$Workflow, [datetime]$After, [int]$TimeoutMinutes = 25)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $run = $null
    while (-not $run -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 6
        $list = & gh run list -R $Full --workflow $Workflow --limit 10 --json databaseId,createdAt,url 2>$null | ConvertFrom-Json
        $run = @($list) | Where-Object { ([datetime]$_.createdAt).ToUniversalTime() -gt $After } | Sort-Object createdAt | Select-Object -First 1
    }
    if (-not $run) { throw "No run of $Workflow appeared in $Full" }
    Write-Info "Run started: $($run.url)"
    $last = ""
    while ((Get-Date) -lt $deadline) {
        $v = & gh run view $run.databaseId -R $Full --json status,conclusion,jobs 2>$null | ConvertFrom-Json
        $step = @($v.jobs | ForEach-Object { $_.steps } | Where-Object { $_.status -eq "in_progress" } | Select-Object -First 1).name
        $line = "$($v.status)$(if ($step) { ': ' + $step })"
        if ($line -ne $last) { Write-Info "  $line"; $last = $line }
        if ($v.status -eq "completed") {
            return [pscustomobject]@{ Repo = $Full; Id = $run.databaseId; Url = $run.url; Conclusion = $v.conclusion }
        }
        Start-Sleep -Seconds 10
    }
    throw "Timed out waiting for $($run.url)"
}

function Get-RunFailureLine {
    # Returns the real error from a run's log. Uses ##[error] lines only: the log also echoes each step's
    # script source, so a plain text search would match error messages that were never printed.
    param([string]$Full, [long]$RunId, [switch]$AllLogs)
    $log = if ($AllLogs) { & gh run view $RunId -R $Full --log 2>$null } else { & gh run view $RunId -R $Full --log-failed 2>$null }
    $errs = @($log | Select-String -Pattern '##\[error\](.*)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^Process completed with exit code' })
    $aad = @($errs | Where-Object { $_ -match 'AADSTS\d+' }) | Select-Object -First 1
    if ($aad) { return ($aad -replace '^.*?(AADSTS\d+)', '$1') }
    if ($errs.Count) { return $errs[0] }
    $any = @($log | Select-String -Pattern '(AADSTS\d+[^.]*)' | Select-Object -First 1)
    if ($any) { return $any[0].Matches[0].Groups[1].Value }
    return "(no ##[error] line found; run: gh run view $RunId -R $Full --log-failed)"
}

function Start-GhWorkflow {
    # Dispatches a workflow, retrying while GitHub registers a just-pushed workflow file.
    param([string]$Full, [string]$Workflow, [string]$Ref)
    for ($i = 1; $i -le 12; $i++) {
        $a = @("workflow", "run", $Workflow, "-R", $Full)
        if ($Ref) { $a += @("--ref", $Ref) }
        & gh @a 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 5
    }
    throw "Could not dispatch $Workflow in $Full"
}

function Get-OwnedAppCount {
    # No JMESPath here on purpose: on Windows az is az.cmd, and cmd.exe mangles arguments such as length(@).
    $out = & az ad app list --show-mine -o json 2>$null
    if ($LASTEXITCODE -ne 0) { throw "az ad app list --show-mine failed (are you signed in with az login?)" }
    $j = ($out -join "`n") | ConvertFrom-Json
    if ($null -eq $j) { return 0 }
    return @($j).Count
}

function Assert-GitHubOwnerUsable {
    # Stops early when the GitHub owner cannot run this lab:
    #  - a personal-account owner must be the account gh is signed in as;
    #  - Enterprise Managed User (EMU) accounts (login ends in _<shortcode>, e.g. name_microsoft) can only own
    #    private repos, and GitHub-hosted runners are not available in EMU personal repos.
    param([string]$Owner)
    $login = (Invoke-Gh api user --jq .login).Trim()
    try { $type = (Invoke-Gh api "users/$Owner" --jq .type).Trim() }
    catch {
        throw ("GitHub owner '$Owner' is not visible to '$login' (managed accounts are hidden from personal accounts). " +
               "If you changed accounts, re-run New-GslPocLab.ps1 -GitHubOwner $login first: the owner is stored in platform\poc-state.json.")
    }
    if ($login -match '_[A-Za-z0-9]+$') {
        throw ("gh is signed in as '$login', which looks like an Enterprise Managed User account. EMU accounts can only own private repos and " +
               "cannot use GitHub-hosted runners in personal repos, so the lab deployments would never run. Sign in with a personal account: " +
               "gh auth login (as the repo owner), then gh auth switch -u <login>, then gh auth setup-git.")
    }
    if ($type -eq "User" -and $Owner -ne $login) {
        throw "The GitHub owner is '$Owner' but gh is signed in as '$login'. Run: gh auth switch -u $Owner   (or gh auth login as $Owner), then gh auth setup-git."
    }
    Write-Ok "GitHub: signed in as $login; owner $Owner ($type)"
    return $login
}
