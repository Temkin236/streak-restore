<#
restore-streak.ps1
Create empty git commits with custom author/committer dates (non-interactive).

This script is intentionally non-interactive: Auto/Push/Force default to true.
Usage examples:
  .\scripts\restore-streak.ps1            # auto-detect missing days and push
  .\scripts\restore-streak.ps1 -Date 2025-10-30  # create commit for a single date and push
  .\scripts\restore-streak.ps1 -Dates 2025-10-30,2025-10-31 -Push:$false  # dry-run
#>

param(
    [Parameter(Mandatory=$false, HelpMessage="Single date (YYYY-MM-DD) or full ISO with time")]
    [string]$Date = $null,

    [Parameter(Mandatory=$false, HelpMessage="Array of dates (YYYY-MM-DD) to create commits for")]
    [string[]]$Dates = @(),

    [Parameter(Mandatory=$false, HelpMessage="Start date for a range (YYYY-MM-DD)")]
    [string]$StartDate = $null,

    [Parameter(Mandatory=$false, HelpMessage="End date for a range (YYYY-MM-DD)")]
    [string]$EndDate = $null,

    [Parameter(Mandatory=$false)]
    [string]$Time = "12:00:00",

    [Parameter(Mandatory=$false)]
    [string]$Timezone = "Z",

    [Parameter(Mandatory=$false, HelpMessage="Commit message template. Use {date} to inject the date")]
    [string]$Message = $null,

    [Parameter(Mandatory=$false, HelpMessage="Author email to use for the commits. If omitted, reads from git config")]
    [string]$Email = $null,

    [Parameter(Mandatory=$false, HelpMessage="Author name to use for the commits. If omitted, reads from git config")]
    [string]$Name = $null,

    [Parameter(Mandatory=$false, HelpMessage="Automatically process ranges/array without prompting")]
    [switch]$Auto,

    [Parameter(Mandatory=$false, HelpMessage="Push after creating all commits")]
    [switch]$Push,

    [Parameter(Mandatory=$false, HelpMessage="Skip confirmation prompts")]
    [switch]$Force,

    [Parameter(Mandatory=$false, HelpMessage="If set, try to fetch your primary verified email from the GitHub API using GITHUB_TOKEN environment variable")]
    [switch]$UseGithubToken
)

# default non-interactive behavior
if (-not $PSBoundParameters.ContainsKey('Auto')) { $Auto = $true }
if (-not $PSBoundParameters.ContainsKey('Push')) { $Push = $true }
if (-not $PSBoundParameters.ContainsKey('Force')) { $Force = $true }

function IsDateOnly($d) { return $d -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' }

# Resolve email/name from git config if not supplied
if (-not $Email) {
    try { $cfgEmail = (git config --get user.email) -join '' } catch { $cfgEmail = '' }
    if ($cfgEmail) { $Email = $cfgEmail }
}
if (-not $Name) {
    try { $cfgName = (git config --get user.name) -join '' } catch { $cfgName = '' }
    if ($cfgName) { $Name = $cfgName }
}

# Optionally fetch primary verified email from GitHub API (requires GITHUB_TOKEN env var)
if ($UseGithubToken) {
    $token = $env:GITHUB_TOKEN
    if ($token) {
        try {
            Write-Host "Attempting to fetch primary verified email via GitHub API..."
            $headers = @{ Authorization = "token $token"; 'User-Agent' = 'restore-streak' }
            $emails = Invoke-RestMethod -Uri 'https://api.github.com/user/emails' -Headers $headers -ErrorAction Stop
            $primary = $emails | Where-Object { $_.primary -and $_.verified } | Select-Object -First 1
            if (-not $primary) { $primary = $emails | Where-Object { $_.verified } | Select-Object -First 1 }
            if ($primary) { $Email = $primary.email; Write-Host "Using GitHub primary verified email: $Email" }
        } catch {
            Write-Host "GitHub API email lookup failed: $($_.Exception.Message) -- falling back to git config or noreply."
        }
    } else {
        Write-Host "GITHUB_TOKEN not set in environment; cannot use GitHub API. Falling back to git config or noreply."
    }
}

if (-not $Email -or $Email -eq '') { $Email = 'temkin236@users.noreply.github.com' }
if (-not $Name -or $Name -eq '') { $Name = 'temkin236' }
if (-not $Message) { $Message = 'Restore streak for {date}' }

# Build target dates
$targetDates = @()
if ($Dates -and $Dates.Count -gt 0) {
    $targetDates = $Dates
} elseif ($StartDate -and $EndDate) {
    if (-not (IsDateOnly $StartDate) -or -not (IsDateOnly $EndDate)) { Write-Error "StartDate and EndDate must be YYYY-MM-DD"; exit 1 }
    $s = [datetime]::Parse($StartDate)
    $e = [datetime]::Parse($EndDate)
    if ($s -gt $e) { Write-Error "StartDate must be <= EndDate"; exit 1 }
    for ($d = $s; $d -le $e; $d = $d.AddDays(1)) { $targetDates += $d.ToString('yyyy-MM-dd') }
} elseif ($Date) {
    $targetDates += $Date
} else {
    # auto-detect: from last commit date (author date) up to today
    Write-Host "No dates provided - auto-detecting missing days from last commit up to today..."
    try { $lastIso = (git log -1 --pretty=format:'%aI') -join '' } catch { $lastIso = $null }
    $today = (Get-Date).ToUniversalTime().Date
    if ($lastIso) { try { $lastDate = [datetime]::Parse($lastIso).ToUniversalTime().Date } catch { $lastDate = $today.AddDays(-1) } } else { $lastDate = $today.AddDays(-1) }
    for ($d = $lastDate.AddDays(1); $d -le $today; $d = $d.AddDays(1)) { $targetDates += $d.ToString('yyyy-MM-dd') }
    if ($targetDates.Count -eq 0) { Write-Host "No missing days to restore (latest commit is today). Nothing to do."; exit 0 }
}

Write-Host "Using author: $Name <$Email>"
Write-Host "Will create commits for these dates: $($targetDates -join ', ')"

# Create commits
$created = @()
foreach ($d in $targetDates) {
    if ($d -match 'T') { $iso = $d } else {
        if (-not (IsDateOnly $d)) { Write-Error "Date must be YYYY-MM-DD or full ISO containing 'T'. Provided: $d"; continue }
        $iso = "$d`T$Time$Timezone"
    }

    $msg = $Message -replace '\{date\}',$d
    Write-Host "Creating commit for $d with date $iso"

    $env:GIT_AUTHOR_NAME = $Name
    $env:GIT_AUTHOR_EMAIL = $Email
    $env:GIT_AUTHOR_DATE = $iso
    $env:GIT_COMMITTER_NAME = $Name
    $env:GIT_COMMITTER_EMAIL = $Email
    $env:GIT_COMMITTER_DATE = $iso

    $commitResult = git commit --allow-empty -m "$msg" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error ("git commit failed for {0}`n{1}" -f $d, $commitResult)
        Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
        continue
    }
    Write-Host $commitResult
    $created += $true
    Start-Sleep -Milliseconds 200
}

if ($created.Count -gt 0 -and $Push) {
    Write-Host "Pushing $($created.Count) commit(s) to origin/$(git rev-parse --abbrev-ref HEAD)"
    $pushResult = git push origin HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Error "git push failed:`n$pushResult"; Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue; exit $LASTEXITCODE }
    Write-Host $pushResult
}

# Show the latest commit and cleanup
git show --quiet --format=fuller HEAD
Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
Write-Host "Done. Created $($created.Count) commit(s)."
<#
restore-streak.ps1
Create an empty git commit with a custom author/committer date (PowerShell-friendly).

Usage examples:
# Use explicit ISO date/time (UTC)
# .\scripts\restore-streak.ps1 -Date "2025-10-23T12:00:00Z" -Message "Restore streak for Oct 23" -Push

# Use just a date (defaults to 12:00:00Z)
# .\scripts\restore-streak.ps1 -Date "2025-10-23" -Message "Restore streak for 2025-10-23" -Push

# Dry-run (no push):
# .\scripts\restore-streak.ps1 -Date "2025-10-23" -Message "Restore streak for Oct 23" -Push:$false
#>

param(
    [Parameter(Mandatory=$false, HelpMessage="Single date (YYYY-MM-DD) or full ISO with time")]
    [string]$Date = $null,

    [Parameter(Mandatory=$false, HelpMessage="Array of dates (YYYY-MM-DD) to create commits for")]
    [string[]]$Dates = @(),

    [Parameter(Mandatory=$false, HelpMessage="Start date for a range (YYYY-MM-DD)")]
    [string]$StartDate = $null,

    [Parameter(Mandatory=$false, HelpMessage="End date for a range (YYYY-MM-DD)")]
    [string]$EndDate = $null,

    <#
    restore-streak.ps1
    Create an empty git commit with a custom author/committer date (PowerShell-friendly).

    Usage examples:
    # Use explicit ISO date/time (UTC)
    # .\scripts\restore-streak.ps1 -Date "2025-10-23T12:00:00Z" -Message "Restore streak for Oct 23" -Push

    # Use just a date (defaults to 12:00:00Z)
    # .\scripts\restore-streak.ps1 -Date "2025-10-23" -Message "Restore streak for 2025-10-23" -Push

    # Dry-run (no push):
    # .\scripts\restore-streak.ps1 -Date "2025-10-23" -Message "Restore streak for Oct 23" -Push:$false
    #>

    param(
        [Parameter(Mandatory=$false, HelpMessage="Single date (YYYY-MM-DD) or full ISO with time")]
        [string]$Date = $null,

        [Parameter(Mandatory=$false, HelpMessage="Array of dates (YYYY-MM-DD) to create commits for")]
        [string[]]$Dates = @(),

        [Parameter(Mandatory=$false, HelpMessage="Start date for a range (YYYY-MM-DD)")]
        [string]$StartDate = $null,

        [Parameter(Mandatory=$false, HelpMessage="End date for a range (YYYY-MM-DD)")]
        [string]$EndDate = $null,

        [Parameter(Mandatory=$false)]
        [string]$Time = "12:00:00",

        [Parameter(Mandatory=$false)]
        [string]$Timezone = "Z",

        [Parameter(Mandatory=$false, HelpMessage="Commit message template. Use {date} to inject the date")]
        [string]$Message = $null,

        [Parameter(Mandatory=$false, HelpMessage="Author email to use for the commits. If omitted, reads from git config")]
        [string]$Email = $null,

        [Parameter(Mandatory=$false, HelpMessage="Author name to use for the commits. If omitted, reads from git config")]
        [string]$Name = $null,

        [Parameter(Mandatory=$false, HelpMessage="Automatically process ranges/array without prompting")]
        [switch]$Auto,

        [Parameter(Mandatory=$false, HelpMessage="Push after creating all commits")]
        [switch]$Push,

        [Parameter(Mandatory=$false, HelpMessage="Skip confirmation prompts")]
        [switch]$Force,

        [Parameter(Mandatory=$false, HelpMessage="If set, try to fetch your primary verified email from the GitHub API using GITHUB_TOKEN environment variable")]
        [switch]$UseGithubToken
    )

    # Implement default behavior: if not explicitly provided, enable Auto and Push and Force
    if (-not $PSBoundParameters.ContainsKey('Auto')) { $Auto = $true }
    if (-not $PSBoundParameters.ContainsKey('Push')) { $Push = $true }
    if (-not $PSBoundParameters.ContainsKey('Force')) { $Force = $true }

    function IsDateOnly($d) {
        return $d -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    }

    # Resolve email/name from git config if not supplied
    if (-not $Email) {
        try { $cfgEmail = (git config --get user.email) -join '' } catch { $cfgEmail = '' }
        if ($cfgEmail) { $Email = $cfgEmail }
    }

    # If requested, try to fetch primary verified email from GitHub API using GITHUB_TOKEN
    if ($UseGithubToken) {
        $token = $env:GITHUB_TOKEN
        if ($token) {
            try {
                Write-Host "Attempting to fetch primary verified email via GitHub API..."
                $headers = @{ Authorization = "token $token"; 'User-Agent' = 'restore-streak-script' }
                $emails = Invoke-RestMethod -Uri 'https://api.github.com/user/emails' -Headers $headers -ErrorAction Stop
                $primary = $emails | Where-Object { $_.primary -and $_.verified } | Select-Object -First 1
                if (-not $primary) { $primary = $emails | Where-Object { $_.verified } | Select-Object -First 1 }
                if ($primary) {
                    $Email = $primary.email
                    Write-Host "Using GitHub primary verified email: $Email"
                } else {
                    Write-Host "No verified email returned by GitHub API; falling back to git config or noreply."
                }
            } catch {
                Write-Host "GitHub API email lookup failed: $($_.Exception.Message) -- falling back to git config or noreply."
            }
        } else {
            Write-Host "GITHUB_TOKEN not set in environment; cannot use GitHub API. Falling back to git config or noreply."
        }
    }

    if (-not $Email -or $Email -eq '') {
        # fallback to noreply if nothing configured
        $Email = 'temkin236@users.noreply.github.com'
    }
    if (-not $Name) {
        try { $cfgName = (git config --get user.name) -join '' } catch { $cfgName = '' }
        if ($cfgName) { $Name = $cfgName }
    }
    if (-not $Name -or $Name -eq '') { $Name = 'temkin236' }

    # Build the list of target dates
    $targetDates = @()
    if ($Dates -and $Dates.Count -gt 0) {
        $targetDates = $Dates
    } elseif ($StartDate -and $EndDate) {
        if (-not (IsDateOnly $StartDate) -or -not (IsDateOnly $EndDate)) {
            Write-Error "StartDate and EndDate must be YYYY-MM-DD"
            exit 1
        }
        $s = [datetime]::Parse($StartDate)
        $e = [datetime]::Parse($EndDate)
        if ($s -gt $e) { Write-Error "StartDate must be <= EndDate"; exit 1 }
        for ($d = $s; $d -le $e; $d = $d.AddDays(1)) { $targetDates += $d.ToString('yyyy-MM-dd') }
    } elseif ($Date) {
        # explicit single date parameter
        if ($Date -match 'T') { $targetDates += $Date } else { $targetDates += $Date }
    } else {
        # No explicit dates; auto-detect missing days from the last commit up to today.
        Write-Host "No dates provided - auto-detecting missing days from last commit up to today..."
        try {
            $lastIso = (git log -1 --pretty=format:'%aI') -join ''
        } catch {
            $lastIso = $null
        }
        $today = (Get-Date).ToUniversalTime().Date
        if ($lastIso) {
            try { $lastDate = [datetime]::Parse($lastIso).ToUniversalTime().Date } catch { $lastDate = $today.AddDays(-1) }
        } else {
            $lastDate = $today.AddDays(-1)
        }

        for ($d = $lastDate.AddDays(1); $d -le $today; $d = $d.AddDays(1)) {
            $targetDates += $d.ToString('yyyy-MM-dd')
        }

        if ($targetDates.Count -eq 0) {
            Write-Host "No missing days to restore (latest commit is today). Nothing to do."
            exit 0
        }
    }

    if ($targetDates.Count -eq 0) { Write-Error "No target dates resolved."; exit 1 }

    if (-not $Message) { $Message = 'Restore streak for {date}' }

    Write-Host "Using author: $Name <$Email>"
    Write-Host "Will create commits for these dates: $($targetDates -join ', ')"

    # Non-interactive by default (Auto and Force default to true). No confirmation prompt.

    $created = @()
    foreach ($d in $targetDates) {
        # Build ISO for this date
        if ($d -match 'T') {
            $iso = $d
        } else {
            if (-not (IsDateOnly $d)) {
                Write-Error "Date must be YYYY-MM-DD or full ISO containing 'T'. Provided: $d"
                continue
            }
            $iso = "$d`T$Time$Timezone"
        }

        $msg = $Message -replace '\{date\}',$d
        Write-Host "Creating commit for $d with date $iso"

        # set env vars
        $env:GIT_AUTHOR_NAME = $Name
        $env:GIT_AUTHOR_EMAIL = $Email
        $env:GIT_AUTHOR_DATE = $iso
        $env:GIT_COMMITTER_NAME = $Name
        $env:GIT_COMMITTER_EMAIL = $Email
        $env:GIT_COMMITTER_DATE = $iso

        $commitResult = git commit --allow-empty -m "$msg" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error ("git commit failed for {0}`n{1}" -f $d, $commitResult)
            # cleanup the env for this iteration
            Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
            continue
        }
        Write-Host $commitResult
        $created += $true
        # small pause to avoid timestamp races
        Start-Sleep -Milliseconds 200
    }

    if ($created.Count -gt 0 -and $Push) {
        Write-Host "Pushing $($created.Count) commit(s) to origin/$(git rev-parse --abbrev-ref HEAD)"
        $pushResult = git push origin HEAD 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "git push failed:`n$pushResult"
            Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
            exit $LASTEXITCODE
        }
        Write-Host $pushResult
    }

    # Show the latest commit
    git show --quiet --format=fuller HEAD

    # Cleanup env vars
    Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue

    Write-Host "Done. Created $($created.Count) commit(s)."
        $lastDate = $today.AddDays(-1)
    }

    for ($d = $lastDate.AddDays(1); $d -le $today; $d = $d.AddDays(1)) {
        $targetDates += $d.ToString('yyyy-MM-dd')
    }

    if ($targetDates.Count -eq 0) {
        Write-Host "No missing days to restore (latest commit is today). Nothing to do."
        exit 0
    }
}

if ($targetDates.Count -eq 0) { Write-Error "No target dates resolved."; exit 1 }

if (-not $Message) { $Message = 'Restore streak for {date}' }

Write-Host "Using author: $Name <$Email>"
Write-Host "Will create commits for these dates: $($targetDates -join ', ')"

# Non-interactive by default (Auto and Force default to true). No confirmation prompt.

$created = @()
foreach ($d in $targetDates) {
    # Build ISO for this date
    if ($d -match 'T') {
        $iso = $d
    } else {
    if (-not (IsDateOnly $d)) {
            Write-Error "Date must be YYYY-MM-DD or full ISO containing 'T'. Provided: $d"
            continue
        }
        $iso = "$d`T$Time$Timezone"
    }

    $msg = $Message -replace '\{date\}',$d
    Write-Host "Creating commit for $d with date $iso"

    # set env vars
    $env:GIT_AUTHOR_NAME = $Name
    $env:GIT_AUTHOR_EMAIL = $Email
    $env:GIT_AUTHOR_DATE = $iso
    $env:GIT_COMMITTER_NAME = $Name
    $env:GIT_COMMITTER_EMAIL = $Email
    $env:GIT_COMMITTER_DATE = $iso

    $commitResult = git commit --allow-empty -m "$msg" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error ("git commit failed for {0}`n{1}" -f $d, $commitResult)
        # cleanup the env for this iteration
        Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
        continue
    }
    Write-Host $commitResult
    $created += $true
    # small pause to avoid timestamp races
    Start-Sleep -Milliseconds 200
}

if ($created.Count -gt 0 -and $Push) {
    Write-Host "Pushing $($created.Count) commit(s) to origin/$(git rev-parse --abbrev-ref HEAD)"
    $pushResult = git push origin HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git push failed:`n$pushResult"
        Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
        exit $LASTEXITCODE
    }
    Write-Host $pushResult
}

# Show the latest commit
git show --quiet --format=fuller HEAD

# Cleanup env vars
Remove-Item Env:GIT_AUTHOR_NAME,Env:GIT_AUTHOR_EMAIL,Env:GIT_AUTHOR_DATE,Env:GIT_COMMITTER_NAME,Env:GIT_COMMITTER_EMAIL,Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue

Write-Host "Done. Created $($created.Count) commit(s)."
