<#
.SYNOPSIS
    Install-AVDHybridAgents
    Downloads, installs and configures the Azure Connected Machine (Arc) agent, the
    Azure Virtual Desktop Agent (RDAgent), the AVD Agent Boot Loader and the Hydra Agent
    on a VM that becomes an AVD Hybrid session host.

.DESCRIPTION
    Standalone script: run it elevated (local admin or SYSTEM) in 64-bit Windows PowerShell:
        powershell.exe -ExecutionPolicy Bypass -File .\Install-AVDHybridAgents.ps1

    Order of operations:
      1. Pre-flight: 64-bit host, OS edition, AD / hybrid Entra join state, working folder
      2. Azure Arc: download + install the Connected Machine agent, connect it with a
         service principal (skipped if already connected to the right tenant)
      3. OS prep: RD Session Host role (Windows Server) and RDP enabled
      4. AVD agent state check + registration token (only if registration is needed):
         either the token from the configuration, or retrieved / generated from the
         host pool via the ARM REST API (no Az modules required)
      5. Download, signature check and install of the RDAgent (with token) and the
         Boot Loader, or re-registration if the agent is installed but not registered
      6. Wait for the broker registration
      7. Hydra Agent: download the ZIP from your Hydra instance, copy it to
         C:\Program Files\ITProCloud\HydraAgent, run the install command from
         Tenant Configuration > Hydra Agent (registers a scheduled task) and set the
         Allow-RunScript / Allow-UpdateAgent flags
      Then an optional delayed restart, so the log is complete before Windows goes down.

    Arc is connected BEFORE the AVD agents are installed, so the agent registers as an
    Arc-enabled machine. The token tenant is checked against the Arc tenant (AVD blocks
    cross-tenant registration). Microsoft downloads must be signed by Microsoft Corporation.

    Idempotent: an Arc agent that is already connected, an AVD agent that is already
    registered and a Hydra Agent that is already installed are detected and left alone.
    See $ArcForceReconnect / $ReinstallAvdAgents / $ReinstallHydraAgent.

.NOTES
    Logging (all local, folder restricted to SYSTEM and Administrators):
      %ProgramData%\AVDHybrid\Logs\Install-AVDHybridAgents_<computer>_<timestamp>.log
          every step, warning and error with timestamp and level
      %ProgramData%\AVDHybrid\Logs\..._transcript.log
          full PowerShell transcript, catches anything unexpected
      %ProgramData%\AVDHybrid\*-install.log
          verbose msiexec logs of the Arc agent, RDAgent and Boot Loader
    Secrets (SP secrets, registration token, Hydra Agent keys) are masked in all of them,
    except that msiexec verbose logs may contain the registration token (hence the folder ACL).

    Exit code: 0 = success, 1 = failure (usable by schedulers, Arc Run Command, Intune, GPO).
    Run the domain join BEFORE this script: the session host registers with its FQDN.
#>

#region ===== Configuration =====

# --- Azure Arc onboarding --------------------------------------------------------
# Service principal with "Azure Connected Machine Onboarding" on the Arc resource group.
# The host pool's managed identity needs "Reader" on that same resource group.
$ArcTenantId                 = ''
$ArcSubscriptionId           = ''
$ArcResourceGroup            = ''
$ArcLocation                 = 'germanywestcentral'
$ArcServicePrincipalId       = ''
$ArcServicePrincipalSecret   = ''
$ArcCloud                    = 'AzureCloud'      # Hydra AVD Hybrid: Azure Global only
$ArcResourceName             = ''                # empty = computer name (keep it equal to the VM name)
$ArcTags                     = 'Workload=AVD,ManagedBy=Hydra'                # optional, e.g. 'Workload=AVD,ManagedBy=Hydra'
$ArcForceReconnect           = $false            # $true = local disconnect + reconnect if already connected

# --- AVD registration, option A: paste a registration token ------------------------
$RegistrationToken           = ''

# --- AVD registration, option B: retrieve / generate the token (used if option A is empty)
# SP needs "Desktop Virtualization Host Pool Contributor" on the host pool.
# Leave Id/Secret empty to reuse the Arc onboarding SP.
$HostPoolResourceId          = ''                # /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.DesktopVirtualization/hostPools/<name>
$TokenServicePrincipalId     = ''
$TokenServicePrincipalSecret = ''
$TokenValidityHours          = 4                 # lifetime of a newly generated token (2 - 648)

# --- Hydra Agent ---------------------------------------------------------------------
# Paste the install command from Hydra: Tenant Configuration > Hydra Agent (COPY button), e.g.
#   HydraAgent.exe -u "wss://<instance>.azurewebsites.net/wsx" -s "<key>" ...
# The ZIP is downloaded from the same instance (https://<instance>/helpers/HydraAgent.zip).
$InstallHydraAgent           = $true
$HydraAgentCommandLine       = ''
$HydraAgentZipUrl            = ''                # empty = derived from the -u value of the command
$HydraAgentInstallFolder     = "$env:ProgramFiles\ITProCloud\HydraAgent"
$HydraAgentAllowRunScript    = $true             # HKLM\SOFTWARE\ITProCloud\HydraAgent: Allow-RunScript = 1
$HydraAgentAllowUpdate       = $true             # HKLM\SOFTWARE\ITProCloud\HydraAgent: Allow-UpdateAgent = 1
$ReinstallHydraAgent         = $false            # $true = replace the agent files and re-run the install command

# --- Behaviour ---------------------------------------------------------------------
$RequireDomainJoin           = $true             # stop if the VM is not AD joined yet
$InstallRdshRole             = $false            # Windows Server only
$ReinstallAvdAgents          = $false            # $true = remove existing AVD agent components first
$RegistrationTimeoutMinutes  = 10
$RebootAfterInstall          = $true             # Microsoft recommends a restart after registration
$RebootDelaySeconds          = 120               # time to finish logging (and to read the console) before the restart
$ProxyUrl                    = ''                # optional, e.g. 'http://proxy.contoso.local:8080'
$WorkingFolder               = "$env:ProgramData\AVDHybrid"
$CleanupInstallers           = $true             # delete MSIs/ZIP afterwards (logs are kept)

# --- Logging -----------------------------------------------------------------------
$LogFolder                   = "$env:ProgramData\AVDHybrid\Logs"
$EnableTranscript            = $true             # additional full PowerShell transcript next to the log
$LogRetentionCount           = 0                # keep the newest N log files per type, 0 = keep all

# --- Download sources (Microsoft) ------------------------------------------------------
$ArcAgentUrl                 = 'https://aka.ms/AzureConnectedMachineAgent'
$AvdAgentUrl                 = 'https://go.microsoft.com/fwlink/?linkid=2310011'
$AvdBootLoaderUrl            = 'https://go.microsoft.com/fwlink/?linkid=2311028'
$ArmApiVersion               = '2025-10-10'

#endregion

#region ===== Helper functions =====
# Functions that return data never log; functions that log never return data.

function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console output for interactive runs; the log file is the record.')]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'DETAIL', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.PadRight(6), (Hide-SecretValue -Text $Message)
    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # The log folder may not exist yet during the first lines; the console still gets them
            $null = $_
        }
    }
    $color = switch ($Level) {
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        'DETAIL' { 'Gray' }
        default  { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    # Windows PowerShell 5.1 turns redirected stderr into terminating errors under
    # ErrorActionPreference 'Stop', so native tools run with 'Continue'.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = "$output".Trim() }
}

function Hide-SecretValue {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $secrets = @($ArcServicePrincipalSecret, $TokenServicePrincipalSecret, $RegistrationToken, $State.RegistrationToken)
    # Key values (-s / -t) from the Hydra Agent install command
    foreach ($keyMatch in [regex]::Matches("$HydraAgentCommandLine", '(?:^|\s)-[st]\s+"?([^"\s]+)"?')) {
        $secrets += $keyMatch.Groups[1].Value
    }
    foreach ($secret in $secrets) {
        if (-not [string]::IsNullOrWhiteSpace($secret) -and $secret.Length -ge 6) {
            $Text = $Text.Replace($secret, '***')
        }
    }
    return $Text
}

function ConvertFrom-JwtPayload {
    param([string]$Jwt)
    $parts = "$Jwt".Split('.')
    if ($parts.Count -lt 3) { return $null }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }
    try {
        return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-ArcAgentState {
    param([Parameter(Mandatory)][string]$AzcmagentPath)
    $state = [pscustomobject]@{
        Installed     = $false
        Status        = ''
        TenantId      = ''
        ResourceName  = ''
        ResourceGroup = ''
        AgentVersion  = ''
    }
    if (-not (Test-Path -Path $AzcmagentPath)) { return $state }
    $state.Installed = $true

    $result = Invoke-NativeCommand -FilePath $AzcmagentPath -Arguments @('show')
    $fieldMap = @{
        Status        = 'Agent Status'
        TenantId      = 'Tenant ID'
        ResourceName  = 'Resource Name'
        ResourceGroup = 'Resource Group Name'
        AgentVersion  = 'Agent Version'
    }
    foreach ($property in $fieldMap.Keys) {
        # [ \t] instead of \s: an empty field must not capture the next line
        $pattern = '(?m)^[ \t]*' + [regex]::Escape($fieldMap[$property]) + '[ \t]*:[ \t]*(\S+)'
        $match = [regex]::Match($result.Output, $pattern)
        if ($match.Success) { $state.$property = $match.Groups[1].Value.Trim() }
    }
    return $state
}

function Get-AvdAgentState {
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $components = @(Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -like 'Remote Desktop Agent Boot Loader*' -or
            $_.DisplayName -like 'Remote Desktop Services Infrastructure Agent*' -or
            $_.DisplayName -like 'Remote Desktop Services Infrastructure Geneva Agent*' -or
            $_.DisplayName -like 'Remote Desktop Services SxS Network Stack*'
        } |
        ForEach-Object {
            [pscustomobject]@{
                DisplayName    = $_.DisplayName
                DisplayVersion = $_.DisplayVersion
                ProductCode    = $_.PSChildName
            }
        })

    $agent = $components | Where-Object { $_.DisplayName -like 'Remote Desktop Services Infrastructure Agent*' } |
        Sort-Object -Property DisplayVersion -Descending | Select-Object -First 1
    $bootLoader = $components | Where-Object { $_.DisplayName -like 'Remote Desktop Agent Boot Loader*' } |
        Select-Object -First 1
    $isRegistered = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name 'IsRegistered' -ErrorAction SilentlyContinue).IsRegistered -eq 1

    [pscustomobject]@{
        AgentInstalled      = [bool]$agent
        AgentVersion        = if ($agent) { $agent.DisplayVersion } else { '' }
        BootLoaderInstalled = [bool]$bootLoader
        Registered          = ([bool]$agent -and $isRegistered)
        Components          = $components
    }
}

function Get-ArmAccessToken {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )
    $request = @{
        Method          = 'Post'
        Uri             = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        ContentType     = 'application/x-www-form-urlencoded'
        UseBasicParsing = $true
        Body            = @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = 'https://management.azure.com/.default'
            grant_type    = 'client_credentials'
        }
    }
    if ($ProxyUrl) { $request['Proxy'] = $ProxyUrl; $request['ProxyUseDefaultCredentials'] = $true }
    return (Invoke-RestMethod @request).access_token
}

function Get-HostPoolRegistrationToken {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][int]$ValidityHours
    )
    $baseUri = "https://management.azure.com$ResourceId"
    $request = @{
        Headers         = @{ Authorization = "Bearer $AccessToken" }
        ContentType     = 'application/json'
        UseBasicParsing = $true
    }
    if ($ProxyUrl) { $request['Proxy'] = $ProxyUrl; $request['ProxyUseDefaultCredentials'] = $true }

    $retrieveUri = "$baseUri/retrieveRegistrationToken?api-version=$ArmApiVersion"
    $info = Invoke-RestMethod @request -Method Post -Uri $retrieveUri
    $generated = $false

    # Generate a new token if none exists or the current one expires within the next hour
    $needsNewToken = [string]::IsNullOrWhiteSpace($info.token)
    if (-not $needsNewToken) {
        $needsNewToken = ([datetime]$info.expirationTime).ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddHours(1)
    }
    if ($needsNewToken) {
        $expiration = (Get-Date).ToUniversalTime().AddHours($ValidityHours).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $body = @{
            properties = @{
                registrationInfo = @{
                    expirationTime             = $expiration
                    registrationTokenOperation = 'Update'
                }
            }
        } | ConvertTo-Json -Depth 5
        $null = Invoke-RestMethod @request -Method Patch -Uri "${baseUri}?api-version=$ArmApiVersion" -Body $body
        $info = Invoke-RestMethod @request -Method Post -Uri $retrieveUri
        $generated = $true
    }
    if ([string]::IsNullOrWhiteSpace($info.token)) { throw 'The host pool returned an empty registration token.' }

    [pscustomobject]@{
        Token          = $info.token
        ExpirationTime = $info.expirationTime
        Generated      = $generated
    }
}

function ConvertFrom-HydraAgentCommand {
    param([string]$CommandLine)
    # Accepts the full command from the Hydra portal or only its arguments
    $arguments = "$CommandLine".Trim() -replace '^(?:"[^"]*HydraAgent\.exe"|\S*HydraAgent\.exe)\s*', ''
    $uriMatch  = [regex]::Match($arguments, '(?:^|\s)-u\s+"?(wss://[^"\s]+)"?')
    $hasKey    = $arguments -match '(?:^|\s)-s\s+\S'
    $addedInstallSwitch = $false
    if ($arguments -and $arguments -notmatch '(?:^|\s)-i(?:\s|$)') {
        # Without -i the agent runs in the foreground instead of installing its scheduled task
        $arguments = "$arguments -i"
        $addedInstallSwitch = $true
    }
    [pscustomobject]@{
        Arguments          = $arguments
        WebSocketUri       = if ($uriMatch.Success) { $uriMatch.Groups[1].Value } else { '' }
        InstanceHost       = if ($uriMatch.Success) { ([uri]$uriMatch.Groups[1].Value).Authority } else { '' }
        HasKey             = $hasKey
        AddedInstallSwitch = $addedInstallSwitch
    }
}

function Get-HydraAgentState {
    param([Parameter(Mandatory)][string]$InstallFolder)
    $exePath = Join-Path -Path $InstallFolder -ChildPath 'HydraAgent.exe'
    $task = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { @($_.Actions | ForEach-Object { "$($_.Execute)" }) -match 'HydraAgent\.exe' } |
        Select-Object -First 1
    $process = Get-Process -Name 'HydraAgent' -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject]@{
        ExeInstalled = Test-Path -Path $exePath
        Version      = if (Test-Path -Path $exePath) { (Get-Item -Path $exePath).VersionInfo.FileVersion } else { '' }
        TaskName     = if ($task) { $task.TaskName } else { '' }
        TaskPath     = if ($task) { $task.TaskPath } else { '' }
        Running      = [bool]$process
    }
}

function Save-Installer {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Name,
        [string]$RequiredSigner = 'O=Microsoft Corporation'   # empty = no signature check
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $request = @{ Uri = $Url; OutFile = $Destination; UseBasicParsing = $true; TimeoutSec = 300 }
            if ($ProxyUrl) { $request['Proxy'] = $ProxyUrl; $request['ProxyUseDefaultCredentials'] = $true }
            Invoke-WebRequest @request
            break
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            if ($attempt -ge 3) { throw "Download of $Name failed after $attempt attempts. $ErrorMessage" }
            Write-Log "Download of $Name failed (attempt $attempt). $ErrorMessage Retrying in 15 seconds." -Level DETAIL
            Start-Sleep -Seconds 15
        }
    }

    $sizeMb = [math]::Round((Get-Item -Path $Destination).Length / 1MB, 1)
    if ([string]::IsNullOrEmpty($RequiredSigner)) {
        Write-Log "Downloaded $Name ($sizeMb MB)." -Level DETAIL
        return
    }
    $signature = Get-AuthenticodeSignature -FilePath $Destination
    $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { 'none' }
    if ($signature.Status -ne 'Valid' -or $signer -notmatch [regex]::Escape($RequiredSigner)) {
        throw "$Name failed the signature check (status '$($signature.Status)', signer '$signer'). A TLS-inspecting proxy may be altering the download."
    }
    Write-Log "Downloaded $Name ($sizeMb MB), signature valid ($RequiredSigner)." -Level DETAIL
}

function Install-MsiPackage {
    param(
        [Parameter(Mandatory)][string]$MsiPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LogPath,
        [string[]]$Properties = @()
    )
    # Arguments are never logged: they can contain the registration token.
    $arguments = @('/i', "`"$MsiPath`"", '/qn', '/norestart', '/l*v', "`"$LogPath`"") + $Properties
    $attempt = 0
    while ($true) {
        $attempt++
        $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        $exitCode = $process.ExitCode
        if ($exitCode -eq 1618 -and $attempt -lt 6) {
            Write-Log "Another installation is in progress (1618). Retrying $Name in 30 seconds." -Level DETAIL
            Start-Sleep -Seconds 30
            continue
        }
        break
    }
    switch ($exitCode) {
        0       { Write-Log "$Name installed." }
        3010    { Write-Log "$Name installed, restart required."; $State.RebootRequired = $true }
        default { throw "$Name installation failed with exit code $exitCode. MSI log: $LogPath" }
    }
}

#endregion

#region ===== Main =====

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$State = @{
    RebootRequired    = $false
    Changed           = $false
    RegistrationToken = ''
}
$azcmagentPath  = Join-Path -Path $env:ProgramW6432 -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
$rdInfraKey     = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
$runStamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile        = Join-Path -Path $LogFolder -ChildPath "Install-AVDHybridAgents_$($env:COMPUTERNAME)_$runStamp.log"
$TranscriptFile = Join-Path -Path $LogFolder -ChildPath "Install-AVDHybridAgents_$($env:COMPUTERNAME)_$($runStamp)_transcript.log"
$transcriptOn   = $false
$scriptExitCode = 0

try {
    #----- Logging setup ------------------------------------------------------------------
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated (local administrator or SYSTEM).'
    }

    # Working and log folders: SYSTEM and Administrators only (MSI verbose logs can contain the registration token)
    foreach ($folder in @($WorkingFolder, $LogFolder)) {
        if (-not (Test-Path -Path $folder)) {
            $null = New-Item -Path $folder -ItemType Directory -Force
        }
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $sidObject = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sidObject, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -Path $folder -AclObject $acl
    }

    if ($EnableTranscript) {
        $null = Start-Transcript -Path $TranscriptFile -Force
        $transcriptOn = $true
    }

    if ($LogRetentionCount -gt 0) {
        $oldLogs = @(Get-ChildItem -Path $LogFolder -Filter 'Install-AVDHybridAgents_*.log' -File -ErrorAction SilentlyContinue)
        $oldLogs | Where-Object { $_.Name -notlike '*_transcript.log' } |
            Sort-Object -Property LastWriteTime -Descending | Select-Object -Skip $LogRetentionCount |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $oldLogs | Where-Object { $_.Name -like '*_transcript.log' } |
            Sort-Object -Property LastWriteTime -Descending | Select-Object -Skip $LogRetentionCount |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Starting AVD Hybrid agent deployment on $env:COMPUTERNAME."
    Write-Log "Run as $($identity.Name), PowerShell $($PSVersionTable.PSVersion), script '$PSCommandPath'." -Level DETAIL
    Write-Log "Log file: $LogFile" -Level DETAIL
    if ($transcriptOn) { Write-Log "Transcript: $TranscriptFile" -Level DETAIL }
    Write-Log "Working folder: $WorkingFolder (SYSTEM and Administrators only)." -Level DETAIL

    #----- Step 1: Pre-flight ------------------------------------------------------------
    Write-Log "Step 1/7: Pre-flight checks."

    if (-not [Environment]::Is64BitProcess) {
        throw 'This script must run in 64-bit PowerShell (Arc agent and Server Manager cmdlets require it).'
    }

    $os        = Get-CimInstance -ClassName Win32_OperatingSystem
    $computer  = Get-CimInstance -ClassName Win32_ComputerSystem
    $editionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    $isServer  = $os.ProductType -ne 1
    Write-Log "OS: $($os.Caption) $($os.Version) (EditionID $editionId)."

    if ($editionId -eq 'ServerRdsh') {
        Write-Log "Windows Enterprise multi-session is not supported on AVD Hybrid. Use Windows 11 Enterprise single-session or Windows Server." -Level WARN
    }

    if ($computer.PartOfDomain) {
        $sessionHostFqdn = "$env:COMPUTERNAME.$($computer.Domain)".ToLower()
        Write-Log "AD domain joined ($($computer.Domain)). Session host name will be $sessionHostFqdn."
    }
    elseif ($RequireDomainJoin) {
        throw 'The VM is not joined to an AD domain. Run the domain join first: registering before the join registers the wrong session host name.'
    }
    else {
        $sessionHostFqdn = $env:COMPUTERNAME.ToLower()
        Write-Log "The VM is not AD joined. Windows Server session hosts on AVD Hybrid must be AD or hybrid joined." -Level WARN
    }

    $dsreg = Invoke-NativeCommand -FilePath "$env:SystemRoot\System32\dsregcmd.exe" -Arguments @('/status')
    $entraJoined = if ($dsreg.Output -match 'AzureAdJoined\s*:\s*(YES|NO)') { $Matches[1] } else { 'unknown' }
    Write-Log "Entra state: AzureAdJoined = $entraJoined. Hybrid join completes after the next Entra Connect sync and is not required for registration." -Level DETAIL

    if ($ArcResourceName -and $ArcResourceName -ne $env:COMPUTERNAME) {
        Write-Log "Arc resource name '$ArcResourceName' differs from the computer name '$env:COMPUTERNAME'." -Level WARN
    }

    # Validate the Hydra Agent command now, so a missing value fails before the long steps
    $hydraAgent = $null
    $hydraCommand = $null
    if ($InstallHydraAgent) {
        $hydraAgent = Get-HydraAgentState -InstallFolder $HydraAgentInstallFolder
        if ($ReinstallHydraAgent -or -not $hydraAgent.TaskName) {
            $hydraCommand = ConvertFrom-HydraAgentCommand -CommandLine $HydraAgentCommandLine
            if (-not $hydraCommand.WebSocketUri -or -not $hydraCommand.HasKey) {
                throw 'The Hydra Agent install command is missing or incomplete (needs -u "wss://..." and -s). Paste it from Tenant Configuration > Hydra Agent into $HydraAgentCommandLine, or set $InstallHydraAgent = $false.'
            }
            Write-Log "Hydra Agent will be installed against $($hydraCommand.InstanceHost)." -Level DETAIL
        }
    }

    #----- Step 2: Azure Arc ----------------------------------------------------------
    Write-Log "Step 2/7: Azure Connected Machine (Arc) agent."

    $arc = Get-ArcAgentState -AzcmagentPath $azcmagentPath
    if (-not $arc.Installed) {
        $arcMsi = Join-Path -Path $WorkingFolder -ChildPath 'AzureConnectedMachineAgent.msi'
        Save-Installer -Url $ArcAgentUrl -Destination $arcMsi -Name 'Azure Connected Machine agent'
        Install-MsiPackage -MsiPath $arcMsi -Name 'Azure Connected Machine agent' -LogPath (Join-Path -Path $WorkingFolder -ChildPath 'ArcAgent-install.log')
        $arc = Get-ArcAgentState -AzcmagentPath $azcmagentPath
        if (-not $arc.Installed) { throw "azcmagent.exe not found after installation ($azcmagentPath)." }
    }
    else {
        Write-Log "Arc agent already installed (version $($arc.AgentVersion), status $($arc.Status))." -Level DETAIL
    }

    $connectNeeded = $true
    if ($arc.Status -eq 'Connected') {
        if ($arc.TenantId -and $arc.TenantId -ne $ArcTenantId -and -not $ArcForceReconnect) {
            throw "The Arc agent is connected to tenant $($arc.TenantId), expected $ArcTenantId. Set `$ArcForceReconnect = `$true to reconnect it."
        }
        if (-not $ArcForceReconnect) {
            $connectNeeded = $false
            Write-Log "Arc agent already connected as '$($arc.ResourceName)' in '$($arc.ResourceGroup)'. Skipping connect."
        }
    }

    if ($connectNeeded) {
        if ($arc.Status -in @('Connected', 'Expired')) {
            Write-Log "Local disconnect of the Arc agent (status $($arc.Status)). The previous Arc resource in Azure is not deleted."
            $result = Invoke-NativeCommand -FilePath $azcmagentPath -Arguments @('disconnect', '--force-local-only')
            if ($result.ExitCode -ne 0) {
                throw "azcmagent disconnect failed (exit code $($result.ExitCode)). $(Hide-SecretValue -Text $result.Output)"
            }
        }

        if ($ProxyUrl) {
            $result = Invoke-NativeCommand -FilePath $azcmagentPath -Arguments @('config', 'set', 'proxy.url', $ProxyUrl)
            if ($result.ExitCode -ne 0) { throw "azcmagent proxy configuration failed. $($result.Output)" }
            Write-Log "Arc agent proxy set to $ProxyUrl." -Level DETAIL
        }

        $connectArguments = @(
            'connect',
            '--service-principal-id', $ArcServicePrincipalId,
            '--service-principal-secret', $ArcServicePrincipalSecret,
            '--tenant-id', $ArcTenantId,
            '--subscription-id', $ArcSubscriptionId,
            '--resource-group', $ArcResourceGroup,
            '--location', $ArcLocation,
            '--cloud', $ArcCloud,
            '--correlation-id', [guid]::NewGuid().Guid
        )
        if ($ArcResourceName) { $connectArguments += @('--resource-name', $ArcResourceName) }
        if ($ArcTags)         { $connectArguments += @('--tags', $ArcTags) }

        Write-Log "Connecting to Azure Arc (RG '$ArcResourceGroup', region '$ArcLocation')."
        $result = Invoke-NativeCommand -FilePath $azcmagentPath -Arguments $connectArguments
        Write-Log "azcmagent connect output: $(Hide-SecretValue -Text $result.Output)" -Level DETAIL
        if ($result.ExitCode -ne 0) {
            throw "azcmagent connect failed (exit code $($result.ExitCode)). Details in %ProgramData%\AzureConnectedMachineAgent\Log\azcmagent.log."
        }

        $arc = Get-ArcAgentState -AzcmagentPath $azcmagentPath
        if ($arc.Status -ne 'Connected') { throw "Arc agent status after connect is '$($arc.Status)', expected 'Connected'." }
        Write-Log "Arc agent connected as '$($arc.ResourceName)' (agent $($arc.AgentVersion))."
    }

    $himds = Get-Service -Name 'himds' -ErrorAction SilentlyContinue
    if ($himds -and $himds.Status -ne 'Running') {
        Start-Service -Name 'himds'
        Write-Log "Started the himds service." -Level DETAIL
    }

    #----- Step 3: OS prep --------------------------------------------------------------
    Write-Log "Step 3/7: OS preparation."

    if ($isServer) {
        $rdsh = Get-WindowsFeature -Name 'RDS-RD-Server'
        if ($rdsh.InstallState -eq 'Installed') {
            Write-Log "RD Session Host role already installed." -Level DETAIL
        }
        elseif ($rdsh.InstallState -eq 'InstallPending') {
            $State.RebootRequired = $true
            Write-Log "RD Session Host role is pending a restart."
        }
        elseif ($InstallRdshRole) {
            Write-Log "Installing the RD Session Host role."
            $featureResult = Install-WindowsFeature -Name 'RDS-RD-Server'
            if (-not $featureResult.Success) { throw "Installing RDS-RD-Server failed (exit code $($featureResult.ExitCode))." }
            if ("$($featureResult.RestartNeeded)" -ne 'No') { $State.RebootRequired = $true }
            Write-Log "RD Session Host role installed (restart needed: $($featureResult.RestartNeeded))."
        }
        else {
            Write-Log "RD Session Host role is missing and `$InstallRdshRole is `$false." -Level WARN
        }
    }

    $tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    if ((Get-ItemProperty -Path $tsKey -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections -ne 0) {
        $null = New-ItemProperty -Path $tsKey -Name 'fDenyTSConnections' -Value 0 -PropertyType DWord -Force
        Write-Log "Remote Desktop connections enabled (fDenyTSConnections = 0)." -Level DETAIL
    }
    $policyDeny = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($policyDeny -eq 1) {
        Write-Log "A Group Policy denies Remote Desktop connections (fDenyTSConnections = 1). AVD connections will fail until it is changed." -Level WARN
    }

    #----- Step 4: AVD agent state + registration token ------------------------------------------
    Write-Log "Step 4/7: AVD agent state and registration token."

    $avd = Get-AvdAgentState
    $registrationNeeded = $ReinstallAvdAgents -or -not $avd.Registered
    Write-Log "AVD agent installed: $($avd.AgentInstalled), Boot Loader installed: $($avd.BootLoaderInstalled), registered: $($avd.Registered)." -Level DETAIL

    if ($registrationNeeded) {
        if (-not [string]::IsNullOrWhiteSpace($RegistrationToken)) {
            $State.RegistrationToken = $RegistrationToken.Trim()
            Write-Log "Using the registration token from the script configuration." -Level DETAIL
        }
        elseif (-not [string]::IsNullOrWhiteSpace($HostPoolResourceId)) {
            if ($HostPoolResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.DesktopVirtualization/hostPools/[^/]+$') {
                throw "HostPoolResourceId has an unexpected format: $HostPoolResourceId"
            }
            $hostPoolName  = $HostPoolResourceId.Split('/')[-1]
            $tokenSpId     = if ($TokenServicePrincipalId) { $TokenServicePrincipalId } else { $ArcServicePrincipalId }
            $tokenSpSecret = if ($TokenServicePrincipalSecret) { $TokenServicePrincipalSecret } else { $ArcServicePrincipalSecret }
            $validityHours = [int][math]::Min([math]::Max($TokenValidityHours, 2), 648)

            $armToken  = Get-ArmAccessToken -TenantId $ArcTenantId -ClientId $tokenSpId -ClientSecret $tokenSpSecret
            $tokenInfo = Get-HostPoolRegistrationToken -ResourceId $HostPoolResourceId -AccessToken $armToken -ValidityHours $validityHours
            $State.RegistrationToken = $tokenInfo.Token
            if ($tokenInfo.Generated) {
                Write-Log "Generated a new registration token for host pool '$hostPoolName' (valid until $($tokenInfo.ExpirationTime))."
            }
            else {
                Write-Log "Retrieved the existing registration token of host pool '$hostPoolName' (valid until $($tokenInfo.ExpirationTime))."
            }
        }
        else {
            throw 'No registration token available. Set $RegistrationToken or $HostPoolResourceId in the configuration block.'
        }

        $claims = ConvertFrom-JwtPayload -Jwt $State.RegistrationToken
        if (-not $claims) { throw 'The registration token is not a valid JWT. Copy it again from the host pool.' }
        if ($claims.exp) {
            $expiresUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp).UtcDateTime
            if ($expiresUtc -lt (Get-Date).ToUniversalTime()) {
                throw "The registration token expired at $($expiresUtc.ToString('yyyy-MM-dd HH:mm')) UTC. Generate a new one."
            }
            Write-Log "Registration token valid until $($expiresUtc.ToString('yyyy-MM-dd HH:mm')) UTC." -Level DETAIL
        }
        if ($claims.AADTenantId -and $arc.TenantId -and $claims.AADTenantId -ne $arc.TenantId) {
            throw "Tenant mismatch: the token belongs to tenant $($claims.AADTenantId), the Arc agent to tenant $($arc.TenantId). AVD blocks cross-tenant registration."
        }
    }

    #----- Step 5: AVD Agent + Boot Loader --------------------------------------------------
    Write-Log "Step 5/7: AVD Agent and Boot Loader."

    $agentMsi      = Join-Path -Path $WorkingFolder -ChildPath 'RDAgent.msi'
    $bootLoaderMsi = Join-Path -Path $WorkingFolder -ChildPath 'RDAgentBootLoader.msi'

    if ($ReinstallAvdAgents -and $avd.Components.Count -gt 0) {
        Write-Log "Reinstall requested: removing $($avd.Components.Count) AVD agent component(s). Remove the old session host object from the host pool first, otherwise registration fails with NAME_ALREADY_REGISTERED."
        Stop-Service -Name 'RDAgentBootLoader' -Force -ErrorAction SilentlyContinue
        foreach ($component in $avd.Components) {
            if ($component.ProductCode -notmatch '^\{[0-9A-Fa-f\-]{36}\}$') {
                Write-Log "Skipping '$($component.DisplayName)': no MSI product code." -Level DETAIL
                continue
            }
            $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @('/x', $component.ProductCode, '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
            Write-Log "Removed '$($component.DisplayName)' (exit code $($process.ExitCode))." -Level DETAIL
        }
        $avd = Get-AvdAgentState
    }

    if (-not $registrationNeeded) {
        Write-Log "AVD Agent $($avd.AgentVersion) is already installed and registered. Nothing to do."
    }
    elseif ($avd.AgentInstalled) {
        # Installed but not registered: Microsoft's fix is a new token + IsRegistered = 0
        Write-Log "AVD Agent $($avd.AgentVersion) is installed but not registered. Re-registering with the registration token."
        if (-not $avd.BootLoaderInstalled) {
            Save-Installer -Url $AvdBootLoaderUrl -Destination $bootLoaderMsi -Name 'AVD Agent Boot Loader'
            Install-MsiPackage -MsiPath $bootLoaderMsi -Name 'AVD Agent Boot Loader' -LogPath (Join-Path -Path $WorkingFolder -ChildPath 'RDAgentBootLoader-install.log')
        }
        Stop-Service -Name 'RDAgentBootLoader' -Force -ErrorAction SilentlyContinue
        $null = New-ItemProperty -Path $rdInfraKey -Name 'RegistrationToken' -Value $State.RegistrationToken -PropertyType String -Force
        $null = New-ItemProperty -Path $rdInfraKey -Name 'IsRegistered' -Value 0 -PropertyType DWord -Force
        Start-Service -Name 'RDAgentBootLoader'
        $State.Changed = $true
    }
    else {
        # Fresh install; clear a stale IsRegistered flag so the wait below is reliable
        Remove-ItemProperty -Path $rdInfraKey -Name 'IsRegistered' -ErrorAction SilentlyContinue

        Save-Installer -Url $AvdAgentUrl -Destination $agentMsi -Name 'AVD Agent'
        Save-Installer -Url $AvdBootLoaderUrl -Destination $bootLoaderMsi -Name 'AVD Agent Boot Loader'

        Install-MsiPackage -MsiPath $agentMsi -Name 'AVD Agent' -LogPath (Join-Path -Path $WorkingFolder -ChildPath 'RDAgent-install.log') -Properties @("REGISTRATIONTOKEN=$($State.RegistrationToken)")
        Install-MsiPackage -MsiPath $bootLoaderMsi -Name 'AVD Agent Boot Loader' -LogPath (Join-Path -Path $WorkingFolder -ChildPath 'RDAgentBootLoader-install.log')
        $State.Changed = $true
    }

    #----- Step 6: Registration check ----------------------------------------------------
    Write-Log "Step 6/7: Registration check."

    if ($State.Changed) {
        $bootLoaderService = Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue
        if (-not $bootLoaderService) { throw 'The RDAgentBootLoader service does not exist after installation.' }
        if ($bootLoaderService.Status -ne 'Running') { Start-Service -Name 'RDAgentBootLoader' }

        Write-Log "Waiting up to $RegistrationTimeoutMinutes minutes for the AVD broker registration."
        $deadline = (Get-Date).AddMinutes($RegistrationTimeoutMinutes)
        do {
            Start-Sleep -Seconds 15
            $registered = (Get-ItemProperty -Path $rdInfraKey -Name 'IsRegistered' -ErrorAction SilentlyContinue).IsRegistered -eq 1
        } until ($registered -or (Get-Date) -gt $deadline)

        if (-not $registered) {
            $hint = ''
            try {
                $lastError = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'RDAgent'; Level = 2 } -MaxEvents 1 -ErrorAction Stop
                $eventText = "$($lastError.Message)"
                if ($eventText.Length -gt 400) { $eventText = $eventText.Substring(0, 400) + '...' }
                $hint = " Last RDAgent error (event $($lastError.Id)): $eventText"
            }
            catch {
                $hint = ''
            }
            throw "The session host did not register within $RegistrationTimeoutMinutes minutes.$hint See '$env:ProgramFiles\Microsoft RDInfra\AgentInstall.txt'. NAME_ALREADY_REGISTERED means a session host object with this name still exists in the host pool."
        }
        Write-Log "Session host $sessionHostFqdn registered with the AVD broker. It can take a few minutes to show as Available."
    }

    #----- Step 7: Hydra Agent ------------------------------------------------------------
    Write-Log "Step 7/7: Hydra Agent."
    $hydraAgentSummary = 'not installed by this script'

    if ($InstallHydraAgent) {
        # Remote action flags, set before the agent (re)starts so they are picked up
        $hydraKey = 'HKLM:\SOFTWARE\ITProCloud\HydraAgent'
        if (-not (Test-Path -Path $hydraKey)) { $null = New-Item -Path $hydraKey -Force }
        if ($HydraAgentAllowRunScript) { $null = New-ItemProperty -Path $hydraKey -Name 'Allow-RunScript' -Value 1 -PropertyType DWord -Force }
        if ($HydraAgentAllowUpdate)    { $null = New-ItemProperty -Path $hydraKey -Name 'Allow-UpdateAgent' -Value 1 -PropertyType DWord -Force }
        Write-Log "Hydra Agent flags set (Allow-RunScript: $HydraAgentAllowRunScript, Allow-UpdateAgent: $HydraAgentAllowUpdate)." -Level DETAIL

        if ($hydraAgent.TaskName -and -not $ReinstallHydraAgent) {
            # An installed agent is left alone (no restart); use $ReinstallHydraAgent to replace it
            Write-Log "Hydra Agent $($hydraAgent.Version) already installed (task '$($hydraAgent.TaskName)', running: $($hydraAgent.Running)). Skipping installation."
            if (-not $hydraAgent.Running) {
                Start-ScheduledTask -TaskName $hydraAgent.TaskName -TaskPath $hydraAgent.TaskPath
                Write-Log "Started the Hydra Agent task." -Level DETAIL
            }
            $hydraAgentSummary = "already installed ($($hydraAgent.Version))"
        }
        else {
            $zipUrl      = if ($HydraAgentZipUrl) { $HydraAgentZipUrl } else { "https://$($hydraCommand.InstanceHost)/helpers/HydraAgent.zip" }
            $zipPath     = Join-Path -Path $WorkingFolder -ChildPath 'HydraAgent.zip'
            $extractPath = Join-Path -Path $WorkingFolder -ChildPath 'HydraAgent'

            # The ZIP comes from your own Hydra instance over HTTPS; the EXE signer is logged
            Save-Installer -Url $zipUrl -Destination $zipPath -Name 'Hydra Agent' -RequiredSigner ''
            if (Test-Path -Path $extractPath) { Remove-Item -Path $extractPath -Recurse -Force }
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
            $exeSource = Get-ChildItem -Path $extractPath -Filter 'HydraAgent.exe' -Recurse | Select-Object -First 1
            if (-not $exeSource) { throw 'HydraAgent.exe was not found in the downloaded ZIP.' }
            $exeSignature = Get-AuthenticodeSignature -FilePath $exeSource.FullName
            $exeSigner = if ($exeSignature.SignerCertificate) { $exeSignature.SignerCertificate.Subject } else { 'none' }
            Write-Log "HydraAgent.exe $($exeSource.VersionInfo.FileVersion), signature '$($exeSignature.Status)', signer '$exeSigner'." -Level DETAIL

            if ($hydraAgent.TaskName) {
                Stop-ScheduledTask -TaskName $hydraAgent.TaskName -TaskPath $hydraAgent.TaskPath -ErrorAction SilentlyContinue
            }
            Get-Process -Name 'HydraAgent' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

            if (-not (Test-Path -Path $HydraAgentInstallFolder)) {
                $null = New-Item -Path $HydraAgentInstallFolder -ItemType Directory -Force
            }
            Copy-Item -Path (Join-Path -Path $exeSource.DirectoryName -ChildPath '*') -Destination $HydraAgentInstallFolder -Recurse -Force
            $hydraExe = Join-Path -Path $HydraAgentInstallFolder -ChildPath 'HydraAgent.exe'

            if ($hydraCommand.AddedInstallSwitch) {
                Write-Log "Added the install switch -i to the Hydra Agent command." -Level DETAIL
            }
            # Arguments are never logged: they contain the agent keys
            Write-Log "Installing the Hydra Agent (instance $($hydraCommand.InstanceHost))."
            $process = Start-Process -FilePath $hydraExe -ArgumentList $hydraCommand.Arguments -WorkingDirectory $HydraAgentInstallFolder -PassThru -WindowStyle Hidden
            $null = $process.Handle   # keeps ExitCode readable after WaitForExit
            if (-not $process.WaitForExit(180000)) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                throw 'HydraAgent.exe did not finish within 3 minutes. Check that the command from Hydra includes the install switch -i.'
            }
            if ($process.ExitCode -ne 0) {
                Write-Log "HydraAgent.exe exited with code $($process.ExitCode). Checking the scheduled task." -Level DETAIL
            }

            $hydraAgent = Get-HydraAgentState -InstallFolder $HydraAgentInstallFolder
            if (-not $hydraAgent.TaskName) {
                throw "The Hydra Agent scheduled task was not created (HydraAgent.exe exit code $($process.ExitCode)). Check the command and that WebSockets are enabled on the Hydra App Service."
            }
            if (-not $hydraAgent.Running) {
                Start-ScheduledTask -TaskName $hydraAgent.TaskName -TaskPath $hydraAgent.TaskPath
                Start-Sleep -Seconds 10
                $hydraAgent = Get-HydraAgentState -InstallFolder $HydraAgentInstallFolder
            }
            Write-Log "Hydra Agent $($hydraAgent.Version) installed as scheduled task '$($hydraAgent.TaskName)' (running: $($hydraAgent.Running))."
            $hydraAgentSummary = "installed ($($hydraAgent.Version))"
        }
    }
    else {
        Write-Log "Hydra Agent step skipped (`$InstallHydraAgent = `$false)." -Level DETAIL
    }

    #----- Restart ------------------------------------------------------------------------
    if ($RebootAfterInstall -and ($State.Changed -or $State.RebootRequired)) {
        $result = Invoke-NativeCommand -FilePath "$env:SystemRoot\System32\shutdown.exe" -Arguments @('/r', '/t', "$RebootDelaySeconds", '/c', 'Restart after AVD Hybrid agent installation', '/d', 'p:4:2')
        if ($result.ExitCode -eq 0) {
            Write-Log "Restart scheduled in $RebootDelaySeconds seconds."
        }
        else {
            Write-Log "Could not schedule the restart (exit code $($result.ExitCode)). $($result.Output)" -Level WARN
        }
    }
    elseif ($State.RebootRequired) {
        Write-Log "A restart is required but `$RebootAfterInstall is `$false. Restart the host manually." -Level WARN
    }

    Write-Log "Completed. Arc: $($arc.Status) as '$($arc.ResourceName)'. AVD: registered as $sessionHostFqdn. Hydra Agent: $hydraAgentSummary."
}
#catch {
   # $ErrorMessage = Hide-SecretValue -Text $_.Exception.Message
   # Write-Log "FAILED: $ErrorMessage" -Level ERROR
   # throw "[$global:Hydra_Script_Name] $ErrorMessage"
#}
finally {
    if ($CleanupInstallers -and (Test-Path -Path $WorkingFolder)) {
        Get-ChildItem -Path $WorkingFolder -Include '*.msi', '*.zip' -File -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path -Path $WorkingFolder -ChildPath 'HydraAgent') -Recurse -Force -ErrorAction SilentlyContinue
    }
    $ArcServicePrincipalSecret   = $null
    $TokenServicePrincipalSecret = $null
    $RegistrationToken           = $null
    $tokenSpSecret               = $null
    $armToken                    = $null
    $HydraAgentCommandLine       = $null
    $hydraCommand                = $null
    $State.RegistrationToken     = $null
}

#endregion