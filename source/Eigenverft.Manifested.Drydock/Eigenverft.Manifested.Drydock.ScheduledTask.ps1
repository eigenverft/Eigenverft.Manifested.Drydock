function New-CompatScheduledTask {
<#
.SYNOPSIS
Create or update a Windows Scheduled Task (Win7/10/11, PS5) via COM with clear scope semantics, minimal prompting, and helpful guidance.

.DESCRIPTION
- Run context (who the task runs as) via -RunAsAccount: CurrentUser (default), SpecificUser 'DOMAIN\User' or 'User@Domain', or System.
- Background mode via -Background ("Run whether user is logged on or not").
  - -DoNotStorePassword (S4U): no stored password, typically needs elevation; local-only resources at runtime.
  - -Credential (PASSWORD): stored credential; allows network access; avoids interactive prompt.
- Triggers: -LogonThisUser, -LogonAnyUser, -Startup, -DailyAtTime.
- Safety: StartWhenAvailable, IgnoreNew (no overlaps), optional -WakeComputer.
- Fast-win improvements:
  * If -DoNotStorePassword set without -Background -> auto-enable -Background (info message).
  * If -LogonAnyUser with interactive principal (not System and not -Background) -> warn about behavior.
  * -DailyAtTime uses invariant TryParseExact "HH:mm" (also accepts [DateTime]).
  * If S4U chosen, warn when arguments imply UNC/SMB use (no false alarms on local drives).
  * ActionPath validation with -ForceRegister escape hatch.
  * Richer HRESULT decoding and remediation hints.
  * Return a useful object; -Quiet suppresses chatter; -Json outputs JSON.

.PARAMETER TaskName
Leaf name of the task.

.PARAMETER TaskFolder
Task folder (e.g. '\MyCompany\MyApp'). Created if missing. Default: '\'.

.PARAMETER ActionPath
Executable to run (e.g., 'powershell.exe' or a full program/script path).

.PARAMETER ActionArguments
Arguments for the action.

.PARAMETER WorkingDirectory
Working directory for the action (prevents relative-path issues).

.PARAMETER RunAsAccount
Run context: 'CurrentUser' (default), 'SpecificUser', or 'System'. (Alias: -RunAs)

.PARAMETER SpecificUser
User for SpecificUser context. Accepts 'DOMAIN\User' or 'User@Domain'.

.PARAMETER Background
Run even when the user is not logged on. (Alias: -RunWhetherUserLoggedOn)

.PARAMETER DoNotStorePassword
Use S4U ("Do not store password"). Implies -Background. Commonly needs elevation. (Alias: -NoStorePassword)

.PARAMETER Credential
PSCredential for PASSWORD mode (avoids prompt; enables network access).

.PARAMETER NoPrompt
If a password is needed and -Credential is not supplied, throw instead of prompting. (Alias: -NonInteractive)

.PARAMETER Highest
Request "Run with highest privileges" for the run context user.

.PARAMETER LogonThisUser
Trigger at logon for the run-as user (CurrentUser or SpecificUser). (Alias: -AtLogon)

.PARAMETER LogonAnyUser
Trigger at logon of ANY user. (Alias: -AtLogonAnyUser)

.PARAMETER Startup
Trigger at system startup/boot. (Alias: -AtStartup)

.PARAMETER DailyAtTime
Daily time ('HH:mm' or [DateTime]). Invariant parsing; no repetition is set for daily mode. (Alias: -DailyAt)

.PARAMETER WakeComputer
Attempt to wake the computer to run (policy/hardware permitting). Opt-in. (Alias: -WakeToRun)

.PARAMETER ForceRegister
Register even if ActionPath or referenced script does not exist (disables path guard).

.PARAMETER Quiet
Suppress Write-Host info/hints (errors still thrown).

.PARAMETER Json
Emit the returned summary object as JSON (also returns the object).

.PARAMETER Description
Optional description.

.EXAMPLE
 Current user at logon (visible; no password; no elevation)
 Use when your script needs the user's interactive desktop.
 New-CompatScheduledTask -TaskName 'MyApp-UserLogon' -ActionPath 'C:\Windows\regedit.exe' -LogonThisUser
 New-CompatScheduledTask -TaskName 'MyDaily-System-0200' `-RunAsAccount System -Highest -DailyAtTime '02:00' -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\job.ps1"' -WorkingDirectory 'C:\Scripts'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TaskName,
        [string]$TaskFolder = '\',

        [Parameter(Mandatory)] [string]$ActionPath,
        [string]$ActionArguments = '',
        [string]$WorkingDirectory,

        [Alias('RunAs')]
        [ValidateSet('CurrentUser','SpecificUser','System')]
        [string]$RunAsAccount = 'CurrentUser',

        [string]$SpecificUser,

        [Alias('RunWhetherUserLoggedOn')]
        [switch]$Background,

        [Alias('NoStorePassword')]
        [switch]$DoNotStorePassword,

        [System.Management.Automation.PSCredential]$Credential,

        [Alias('NonInteractive')]
        [switch]$NoPrompt,

        [switch]$Highest,

        [Alias('AtLogon')]
        [switch]$LogonThisUser,

        [Alias('AtLogonAnyUser')]
        [switch]$LogonAnyUser,

        [Alias('AtStartup')]
        [switch]$Startup,

        [Alias('DailyAt')]
        [object]$DailyAtTime,

        [Alias('WakeToRun')]
        [switch]$WakeComputer,

        [switch]$ForceRegister,

        [switch]$Quiet,

        [switch]$Json,

        [string]$Description
    )

    function _writeInfo($m){ if(-not $Quiet){ Write-Host "[INFO]  $m" } }
    function _writeHint($m){ if(-not $Quiet){ Write-Host "[HINT]  $m" -ForegroundColor Yellow } }
    function _writeErrT($m){ Write-Host "[ERROR] $m" -ForegroundColor Red }
    function _releaseCom($o){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } }

    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = [Security.Principal.WindowsPrincipal]$id
    $IsElevated = $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $CurrentUser = $id.Name

    if([string]::IsNullOrWhiteSpace($TaskName)){
        _writeErrT "TaskName cannot be empty."
        throw "Invalid TaskName."
    }
    if($TaskName -match '[\/:\*\?"<>|]'){
        _writeErrT ("TaskName contains illegal characters: {0}" -f $TaskName)
        _writeHint "Disallowed: / : * ? "" < > |"
        throw "Invalid TaskName."
    }

    if($RunAsAccount -eq 'SpecificUser' -and [string]::IsNullOrWhiteSpace($SpecificUser)){
        _writeErrT "When -RunAsAccount SpecificUser is used, you must provide -SpecificUser."
        _writeHint "Accepted formats: DOMAIN\User or user@domain."
        throw "SpecificUser is required."
    }

    if($RunAsAccount -eq 'SpecificUser' -and -not [string]::IsNullOrWhiteSpace($SpecificUser)){
        if($SpecificUser -notmatch '^(?:[^\\\/:\*\?"<>|]+\@[^\s@]+|[^\\\/:\*\?"<>|]+\\[^\\\/:\*\?"<>|]+)$'){
            _writeHint ("SpecificUser format looks unusual: {0}. Expected DOMAIN\User or user@domain." -f $SpecificUser)
        }
    }

    if($DoNotStorePassword -and -not $Background){
        _writeInfo "-DoNotStorePassword implies background mode; enabling -Background."
        $Background = $true
    }

    if (-not ($LogonThisUser -or $LogonAnyUser -or $Startup -or $DailyAtTime)) {
        _writeErrT "No trigger specified."
        _writeHint "Add -LogonThisUser, -LogonAnyUser, -Startup, or -DailyAtTime 'HH:mm'."
        throw "At least one trigger is required."
    }

    if($RunAsAccount -eq 'System' -and $LogonThisUser){
        _writeErrT "LogonThisUser cannot be used with -RunAsAccount System. Use -LogonAnyUser or -Startup."
        throw "Invalid trigger combination."
    }

    $looksBareExe = ($ActionPath -match '^[^\\/]+\.(?i:exe)$')
    if (-not (Test-Path -LiteralPath $ActionPath)) {
        if (-not $looksBareExe -and -not $ForceRegister) {
            _writeErrT ("ActionPath not found: {0}" -f $ActionPath)
            _writeHint  "Provide a full path or an .exe name on PATH (e.g., powershell.exe), or pass -ForceRegister."
            throw "ActionPath not found."
        } else {
            _writeHint ("Continuing with non-resolved ActionPath '{0}' (command lookup at runtime)." -f $ActionPath)
        }
    }

    if(-not $IsElevated -and $RunAsAccount -eq 'System'){
        _writeErrT "System principal requires an elevated PowerShell."
        _writeHint "Relaunch as Administrator or use -Background with -Credential for user context."
        throw "Elevation required."
    }
    if(-not $IsElevated -and $RunAsAccount -eq 'SpecificUser' -and $SpecificUser -and $SpecificUser -ne $CurrentUser){
        _writeErrT ("Cannot create a task for another user '{0}' from a non-elevated session." -f $SpecificUser)
        _writeHint "Run elevated, or use -RunAsAccount CurrentUser."
        throw "Elevation required."
    }
    if($Background -and $DoNotStorePassword -and -not $IsElevated){
        _writeErrT "S4U (Do not store password) commonly requires elevation."
        _writeHint "Run elevated or switch to PASSWORD mode with -Credential."
        throw "Elevation recommended for S4U."
    }

    if($LogonAnyUser -and $RunAsAccount -ne 'System' -and -not $Background){
        _writeHint "LogonAnyUser + interactive principal runs only when the run-as user logs in. For true 'any user' execution use -Background (PASSWORD/S4U) or -RunAsAccount System."
    }

    $dailyStart = $null
    if($DailyAtTime){
        if($DailyAtTime -is [datetime]){
            $dailyStart = [datetime]$DailyAtTime
        } else {
            $fmt = 'HH:mm'
            $ci  = [System.Globalization.CultureInfo]::InvariantCulture
            $styles = [System.Globalization.DateTimeStyles]::None
            $parsed = [datetime]::MinValue
            $ok = [datetime]::TryParseExact([string]$DailyAtTime,$fmt,$ci,$styles,[ref]$parsed)
            if(-not $ok){
                _writeErrT ("Could not parse -DailyAtTime '{0}'." -f $DailyAtTime)
                _writeHint  "Use 24h format 'HH:mm' (e.g., '09:30') or pass a [DateTime]."
                throw "Invalid DailyAtTime."
            }
            $dailyStart = $parsed
        }
    }

    if($Background -and $DoNotStorePassword){
        $arguments = $ActionArguments
        if($null -eq $arguments){ $arguments = '' }
        if($ActionPath -like '\\*' -or $arguments -match '(?i)(^|[^A-Za-z0-9_])\\\\[A-Za-z0-9._-]+\\|(?i)\bsmb:'){
            _writeHint "S4U selected: background token has no network access. If you need UNC/mapped shares, use -Credential instead."
        }
    }

    function Test-UserMatches($expect, $actual){
        if(-not $actual){ return $false }
        if($expect -eq $actual){ return $true }
        try{
            $a1 = (New-Object System.Security.Principal.NTAccount($actual)).Translate([System.Security.Principal.SecurityIdentifier]).Translate([System.Security.Principal.NTAccount]).Value
            if($a1 -eq $expect){ return $true }
        }catch{}
        return $false
    }

    $svc = $null; $folder = $null; $def=$null; $trigs=$null; $act=$null
    try{
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        function Resolve-TaskFolder([__comobject]$service,[string]$path){
            
            $path = ($path -replace '/','\'); if([string]::IsNullOrWhiteSpace($path)){ $path='\' }
            if($path -eq '\'){ return $service.GetFolder('\') }
            $parts = $path.Trim('\').Split('\'); $cur = $service.GetFolder('\')
            foreach($p in $parts){
                try{ $cur = $cur.GetFolder("\$p") } catch { $cur = $cur.CreateFolder($p) }
            }
            return $cur
        }
        $folder = Resolve-TaskFolder -service $svc -path $TaskFolder
        $def = $svc.NewTask(0)

        $def.RegistrationInfo.Description = $Description
        $def.Settings.Enabled = $true
        $def.Settings.AllowDemandStart = $true
        $def.Settings.MultipleInstances = 0
        $def.Settings.StopIfGoingOnBatteries = $false
        $def.Settings.DisallowStartIfOnBatteries = $false
        $def.Settings.RunOnlyIfNetworkAvailable = $false
        $def.Settings.StartWhenAvailable = $true
        $def.Settings.ExecutionTimeLimit = 'PT24H'
        if($WakeComputer){ $def.Settings.WakeToRun = $true }

        $TaskLogon = @{ Password=1; S4U=2; Interactive=3; Service=5 }
        $p = $def.Principal
        if($Highest){ $p.RunLevel = 1 }

        $RegUser=$null; $RegPwd=$null; $RegLogon=$null

        switch($RunAsAccount){
            'System'{
                $p.UserId='SYSTEM'; $p.LogonType=$TaskLogon.Service
                $RegUser='SYSTEM';  $RegLogon=$TaskLogon.Service
            }
            'CurrentUser'{
                $p.UserId=$CurrentUser
                if($Background){
                    if($DoNotStorePassword){
                        $p.LogonType=$TaskLogon.S4U; $RegUser=$CurrentUser; $RegLogon=$TaskLogon.S4U
                    } else {
                        if(-not $Credential){
                            if($NoPrompt){ throw "Credentials required; supply -Credential or use -DoNotStorePassword (elevated)." }
                            $Credential = Get-Credential -Message "Enter password for $CurrentUser to run when not logged on"
                        } elseif(-not (Test-UserMatches -expect $CurrentUser -actual $Credential.UserName)){
                            _writeHint ("Credential user '{0}' does not match current user '{1}'. This can cause 0x8007052E." -f $Credential.UserName, $CurrentUser)
                        }
                        $p.LogonType=$TaskLogon.Password
                        $RegUser=$Credential.UserName
                        $RegPwd =$Credential.GetNetworkCredential().Password
                        $RegLogon=$TaskLogon.Password
                    }
                } else { $p.LogonType=$TaskLogon.Interactive; $RegLogon=$TaskLogon.Interactive }
            }
            'SpecificUser'{
                $p.UserId=$SpecificUser
                if($Background){
                    if($DoNotStorePassword){
                        $p.LogonType=$TaskLogon.S4U; $RegUser=$SpecificUser; $RegLogon=$TaskLogon.S4U
                    } else {
                        if(-not $Credential -or -not (Test-UserMatches -expect $SpecificUser -actual $Credential.UserName)){
                            if($NoPrompt){ throw "Credentials for $SpecificUser required; username must match the run-as account." }
                            $Credential = Get-Credential -UserName $SpecificUser -Message "Enter password for $SpecificUser to run when not logged on"
                        }
                        $p.LogonType=$TaskLogon.Password
                        $RegUser=$Credential.UserName
                        $RegPwd =$Credential.GetNetworkCredential().Password
                        $RegLogon=$TaskLogon.Password
                    }
                } else { $p.LogonType=$TaskLogon.Interactive; $RegLogon=$TaskLogon.Interactive }
            }
        }

        $act = $def.Actions.Create(0)
        $act.Path = $ActionPath
        if($ActionArguments){ $act.Arguments = $ActionArguments }
        if($WorkingDirectory){ $act.WorkingDirectory = $WorkingDirectory }

        $trigs = $def.Triggers
        if($Startup){ [void]$trigs.Create(8); _writeInfo "Added Startup trigger." }
        if($LogonThisUser){
            $lt = $trigs.Create(9)
            if($RunAsAccount -eq 'CurrentUser'){ $lt.UserId = $CurrentUser }
            elseif($RunAsAccount -eq 'SpecificUser'){ $lt.UserId = $SpecificUser }
            _writeInfo "Added Logon trigger for specific user."
        }
        if($LogonAnyUser){
            $la = $trigs.Create(9); $la.UserId = $null
            _writeInfo "Added Logon trigger for ANY user."
        }

        
        # ----- DAILY: once per day, no repetition -----
        if ($dailyStart) {
            $start = [datetime]::Today.AddHours($dailyStart.Hour).AddMinutes($dailyStart.Minute)
            if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

            $dt = $trigs.Create(2)            # DAILY
            $dt.StartBoundary = $start.ToString('s')
            $dt.DaysInterval  = 1             # once per day
            # Do not set $dt.Repetition.* at all
            _writeInfo ("Added Daily trigger at {0}." -f $start.ToShortTimeString())
        }


        $TASK_CREATE_OR_UPDATE = 6
        $taskPath = ("{0}\{1}" -f $TaskFolder, $TaskName)
        try{
            $null = $folder.RegisterTaskDefinition($TaskName, $def, $TASK_CREATE_OR_UPDATE, $RegUser, $RegPwd, $RegLogon, $null)
            if(-not $Quiet){
                Write-Host ("[OK] Task '{0}' created/updated." -f $taskPath)
                if($WakeComputer){ _writeHint "Wake timers depend on firmware/policy; may be ignored on some devices." }
            }
        } catch {
            $hr = ('0x{0:X8}' -f $_.Exception.HResult)
            _writeErrT ("Task registration failed (HRESULT={0}). {1}" -f $hr, $_.Exception.Message)
            switch($hr){
                '0x80070005' { _writeHint "Access denied. Elevate for System/other-user, or use a delegated -TaskFolder." }
                '0x8007052E' { _writeHint "Logon failure (bad credentials). Verify -Credential username matches the run-as account." }
                '0x80070002' { _writeHint "File not found. Check ActionPath and any script paths in -ActionArguments." }
                '0x80041316' { _writeHint "One or more properties are invalid (e.g., logon type vs. principal). Review S4U/PASSWORD choices." }
                '0x80041314' { _writeHint "Account information not set. PASSWORD mode requires valid -Credential." }
                '0x80041309' { _writeHint "Invalid task name. Avoid special characters." }
                default      { _writeHint "Verify elevation (if needed), credentials, and folder ACLs." }
            }
            throw
        }

        $logonTypeName = switch($RegLogon){
            1 {'Password'} 2 {'S4U'} 3 {'Interactive'} 5 {'Service'} default {"$RegLogon"}
        }
        $bgMode = if($RunAsAccount -eq 'System'){'Service'}
                  elseif($Background -and $DoNotStorePassword){'S4U'}
                  elseif($Background){'Password'}
                  else{'Interactive'}

        $trigList = @()
        if($Startup){ $trigList += 'Startup' }
        if($LogonThisUser){ $trigList += 'Logon-ThisUser' }
        if($LogonAnyUser){ $trigList += 'Logon-AnyUser' }
        if($dailyStart){ $trigList += ('Daily@' + ($dailyStart.ToString('HH:mm'))) }

        $result = [pscustomobject]@{
            TaskPath      = $taskPath
            TaskFolder    = $TaskFolder
            TaskName      = $TaskName
            Principal     = $RunAsAccount
            PrincipalUser = if($RunAsAccount -eq 'CurrentUser'){$CurrentUser} elseif($RunAsAccount -eq 'SpecificUser'){$SpecificUser} else {'SYSTEM'}
            LogonType     = $logonTypeName
            Background    = $bgMode
            Triggers      = $trigList
            ActionPath    = $ActionPath
            ActionArgs    = $ActionArguments
            WorkingDir    = $WorkingDirectory
            Elevated      = $IsElevated
            WakeComputer  = [bool]$WakeComputer
        }

        if($Json){
            $json = $result | ConvertTo-Json -Depth 4
            if(-not $Quiet){ $json }
            return $result
        } else {
            return $result
        }
    }
    finally{
        _releaseCom $act
        _releaseCom $trigs
        _releaseCom $def
        _releaseCom $folder
        _releaseCom $svc
    }
}

