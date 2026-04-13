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

function New-CompatScheduledTask2 {
<#
.SYNOPSIS
Create or update a Windows Scheduled Task through late-bound COM with Win7/10/11 compatibility, clear run-context semantics, optional repetition, and optional immediate start.

.DESCRIPTION
Creates or updates a scheduled task by using the Task Scheduler COM API instead of the newer ScheduledTasks module,
so it remains usable on Windows 7 / Windows PowerShell 5.x while still working well on newer Windows versions.

The function is designed to make common task-scheduling scenarios easier and safer:
- clear run-context selection:
  - CurrentUser  -> run as the current user
  - SpecificUser -> run as a named user account
  - System       -> run as LocalSystem
- clear execution mode:
  - interactive / visible session
  - background / "run whether user is logged on or not"
- clear trigger selection:
  - logon of this user
  - logon of any user
  - startup / boot
  - daily at a fixed time
- optional repetition:
  - repeat every N minutes for a configurable duration
  - implemented through COM trigger repetition for broad compatibility
- optional immediate start:
  - register or update the task, then launch it once right away

Behavior and safety defaults:
- StartWhenAvailable is enabled.
- MultipleInstances is set to IgnoreNew.
- WakeToRun is opt-in.
- Daily time parsing uses invariant "HH:mm".
- Action path validation is performed unless -ForceRegister is used.
- Useful hints are emitted for common configuration mistakes.

Run-context notes:
- -RunAsAccount CurrentUser is the default and is the easiest choice for user-desktop automation.
- -RunAsAccount SpecificUser is useful for shared machines and server jobs tied to a known account.
- -RunAsAccount System is useful for machine-level automation, startup tasks, and unattended server jobs.

Background notes:
- -Background means "run whether user is logged on or not".
- -DoNotStorePassword uses S4U:
  - does not store the password
  - commonly requires elevation
  - typically cannot access network resources at runtime
- -Credential uses PASSWORD mode:
  - stores credentials in Task Scheduler
  - supports network resources
  - avoids interactive prompts when supplied up front

Repetition notes:
- -RepeatEveryMinutes can be used with -DailyAtTime, -Startup, -LogonThisUser, or -LogonAnyUser.
- When repetition is used with -DailyAtTime and -RepeatFor is omitted, the function defaults to 23:59.
- When repetition is used with startup or logon triggers and -RepeatFor is omitted, the function defaults to 1 day.

When elevation is usually NOT required to add/register the task:
- Current user + interactive task
- Current user + daily task
- Current user + logon task for the same current user
- Current user + background task using that same account, where Task Scheduler accepts the chosen logon mode
These are the most common "works without admin" desktop automation scenarios.

When elevation IS typically required to add/register the task:
- -RunAsAccount System
- -Startup (boot trigger)
- -RunAsAccount SpecificUser for another account
- -Background with -DoNotStorePassword (S4U), depending on policy and environment
- creating or updating tasks in protected task folders / locations where the current user lacks rights

Important distinction:
- Elevation to ADD the task is about whether the current PowerShell session is allowed to register that task definition.
- -Highest affects how the task RUNS later.
- -Highest does not by itself grant permission to register an otherwise protected task.

Practical guidance for non-admin users:
- Use -RunAsAccount CurrentUser for the smoothest experience.
- Prefer -LogonThisUser or -DailyAtTime for user-space automation.
- Avoid -Startup, -RunAsAccount System, and other-user scenarios unless you are elevated.
- If the task must use network resources in background mode, prefer -Credential over S4U.

Fast-win improvements:
- If -DoNotStorePassword is set without -Background, background mode is enabled automatically.
- If -LogonAnyUser is combined with an interactive non-System principal, the function warns about the real behavior.
- If S4U is used and arguments appear to reference UNC / SMB paths, the function warns about network access limitations.
- HRESULT failures are surfaced with targeted hints where possible.
- A structured summary object is returned; -Json also emits JSON.

.PARAMETER TaskName
Leaf name of the task.

.PARAMETER TaskFolder
Task folder (for example '\MyCompany\MyApp').
The folder is created if it does not already exist.
Default: '\'.

.PARAMETER ActionPath
Executable to run, such as 'powershell.exe' or a full path to a program or script host.

.PARAMETER ActionArguments
Arguments passed to the action.

.PARAMETER WorkingDirectory
Working directory for the action.
Useful to avoid relative-path issues.

.PARAMETER RunAsAccount
Run context:
- 'CurrentUser' (default)
- 'SpecificUser'
- 'System'

Alias: -RunAs

.PARAMETER SpecificUser
User for SpecificUser context.
Accepts 'DOMAIN\User' or 'User@Domain'.

.PARAMETER Background
Run even when the user is not logged on.

Alias: -RunWhetherUserLoggedOn

.PARAMETER DoNotStorePassword
Use S4U ("Do not store password").
Implies -Background.
Commonly requires elevation.
Best for local-only background work that does not require network resources.

Alias: -NoStorePassword

.PARAMETER Credential
PSCredential for PASSWORD mode.
Avoids prompting and supports network access for background execution.

.PARAMETER NoPrompt
If a password is needed and -Credential is not supplied, throw instead of prompting.

Alias: -NonInteractive

.PARAMETER Highest
Request "Run with highest privileges" for the run-context user.

.PARAMETER LogonThisUser
Trigger at logon for the run-as user (CurrentUser or SpecificUser).

Alias: -AtLogon

.PARAMETER LogonAnyUser
Trigger at logon of any user.

Alias: -AtLogonAnyUser

.PARAMETER Startup
Trigger at system startup / boot.

Alias: -AtStartup

.PARAMETER DailyAtTime
Daily time in invariant 24-hour format ('HH:mm') or as a [DateTime].
Can be combined with repetition.

Alias: -DailyAt

.PARAMETER RepeatEveryMinutes
Repeat the fired trigger every N minutes.
Typical example: 15.

Can be used with:
- -DailyAtTime
- -Startup
- -LogonThisUser
- -LogonAnyUser

.PARAMETER RepeatFor
How long the repetition window stays active.

Accepts:
- [TimeSpan]
- 'hh:mm[:ss]'
- 'd.hh:mm:ss'
- integer minutes

Smart defaults:
- with -DailyAtTime: 23:59
- with -Startup / -Logon*: 1 day

.PARAMETER StopAtDurationEnd
When repetition is configured, stop a still-running instance when the repetition window ends.

.PARAMETER WakeComputer
Attempt to wake the computer to run.
Depends on firmware, OS policy, and hardware support.

Alias: -WakeToRun

.PARAMETER ForceRegister
Register even if ActionPath or referenced script does not currently exist.
Disables the action-path guard.

.PARAMETER RunNow
After successful registration, start the task once immediately.

.PARAMETER Quiet
Suppress Write-Host informational and hint output.
Errors still throw.

.PARAMETER Json
Emit the returned summary object as JSON and also return the object.

.PARAMETER Description
Optional task description.

.EXAMPLE
Works without admin: start a visible desktop app when the current user signs in
Use this for user-session automation where the app must appear on the interactive desktop.

New-CompatScheduledTask `
  -TaskName 'RegEdit-AtLogon' `
  -ActionPath 'C:\Windows\regedit.exe' `
  -LogonThisUser

.EXAMPLE
Works without admin: run a PowerShell script every day at 09:30 as the current user
Good for user-profile jobs such as cleanup, exports, tray tools, or report generation.

New-CompatScheduledTask `
  -TaskName 'User-Daily-0930' `
  -DailyAtTime '09:30' `
  -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\DailyUserJob.ps1"' `
  -WorkingDirectory 'C:\Scripts'

.EXAMPLE
Works without admin: run every 15 minutes during the day and also start once immediately
Good for polling jobs, sync jobs, kiosk refresh jobs, or recurring local checks.

New-CompatScheduledTask `
  -TaskName 'User-Every15m' `
  -DailyAtTime '00:00' `
  -RepeatEveryMinutes 15 `
  -RunNow `
  -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\LoopJob.ps1"' `
  -WorkingDirectory 'C:\Scripts'

.EXAMPLE
May work without admin, but depends on policy and credentials: run in the background as the current user with stored credentials
Use this when the job must continue while the user is logged off and still needs network access.

$cred = Get-Credential
New-CompatScheduledTask `
  -TaskName 'User-Background-Network' `
  -RunAsAccount CurrentUser `
  -Background `
  -Credential $cred `
  -DailyAtTime '18:00' `
  -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "\\server\share\job.ps1"'

.EXAMPLE
Requires admin in most environments: run for a specific named account at that account's logon
Useful when one managed account owns the task behavior.

New-CompatScheduledTask `
  -TaskName 'OpsUser-AtLogon' `
  -RunAsAccount SpecificUser `
  -SpecificUser 'CONTOSO\OpsUser' `
  -LogonThisUser `
  -ActionPath "$env:WINDIR\System32\notepad.exe"

.EXAMPLE
Requires admin: run a nightly maintenance job under a specific service-style account in the background
Use this for account-scoped unattended work such as backups, imports, file processing, or scheduled admin tasks.

$cred = Get-Credential 'CONTOSO\svc_batch'
New-CompatScheduledTask `
  -TaskName 'SvcBatch-Nightly' `
  -TaskFolder '\Company\ServerJobs' `
  -RunAsAccount SpecificUser `
  -SpecificUser 'CONTOSO\svc_batch' `
  -Background `
  -Credential $cred `
  -Highest `
  -DailyAtTime '02:00' `
  -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "D:\Jobs\nightly.ps1"' `
  -WorkingDirectory 'D:\Jobs'

.EXAMPLE
Requires admin: run every 15 minutes all day as LocalSystem
Useful for machine-level health checks, queue processing, local service orchestration, and other unattended server automation.

New-CompatScheduledTask `
  -TaskName 'System-Every15m' `
  -TaskFolder '\Company\ServerJobs' `
  -RunAsAccount System `
  -Highest `
  -DailyAtTime '00:00' `
  -RepeatEveryMinutes 15 `
  -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "D:\Jobs\heartbeat.ps1"' `
  -WorkingDirectory 'D:\Jobs'

.EXAMPLE
Requires admin: start at boot as LocalSystem and keep repeating
Useful for startup initialization, bootstrapping agents, warming caches, or delayed post-boot orchestration.

New-CompatScheduledTask `
  -TaskName 'System-Startup-Repeating' `
  -TaskFolder '\Company\ServerJobs' `
  -RunAsAccount System `
  -Highest `
  -Startup `
  -RepeatEveryMinutes 30 `
  -RepeatFor '1.00:00:00' `
  -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "D:\Jobs\startup-loop.ps1"' `
  -WorkingDirectory 'D:\Jobs'

.EXAMPLE
Usually requires admin: background local-only task with S4U
Good for unattended local jobs that do not need UNC paths, mapped drives, or SMB/network resources.

New-CompatScheduledTask `
  -TaskName 'User-Background-S4U' `
  -RunAsAccount CurrentUser `
  -Background `
  -DoNotStorePassword `
  -DailyAtTime '12:00' `
  -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\LocalOnlyJob.ps1"' `
  -WorkingDirectory 'C:\Scripts'
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

        [ValidateRange(1,1439)]
        [int]$RepeatEveryMinutes,

        [object]$RepeatFor,

        [switch]$StopAtDurationEnd,

        [Alias('WakeToRun')]
        [switch]$WakeComputer,

        [switch]$ForceRegister,

        [switch]$RunNow,

        [switch]$Quiet,

        [switch]$Json,

        [string]$Description
    )

    function _writeInfo($m){ if(-not $Quiet){ Write-Host "[INFO]  $m" } }
    function _writeHint($m){ if(-not $Quiet){ Write-Host "[HINT]  $m" -ForegroundColor Yellow } }
    function _writeErrT($m){ Write-Host "[ERROR] $m" -ForegroundColor Red }
    function _releaseCom($o){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } }

    function Test-UserMatches($expect, $actual){
        if(-not $actual){ return $false }
        if($expect -eq $actual){ return $true }
        try{
            $a1 = (New-Object System.Security.Principal.NTAccount($actual)).Translate([System.Security.Principal.SecurityIdentifier]).Translate([System.Security.Principal.NTAccount]).Value
            if($a1 -eq $expect){ return $true }
        } catch {}
        return $false
    }

    function Resolve-ActionPath([string]$PathText){
        if([string]::IsNullOrWhiteSpace($PathText)){ return $null }

        if(Test-Path -LiteralPath $PathText){
            try { return (Resolve-Path -LiteralPath $PathText -ErrorAction Stop).Path } catch { return $PathText }
        }

        try{
            $cmd = Get-Command -Name $PathText -ErrorAction Stop | Select-Object -First 1
            if($cmd.CommandType -in @('Application','ExternalScript') -and $cmd.Path){
                return $cmd.Path
            }
        } catch {}

        return $null
    }

    function Normalize-TaskFolderPath([string]$path){
        $path = ($path -replace '/','\')
        if([string]::IsNullOrWhiteSpace($path)){ return '\' }
        if($path -eq '\'){ return '\' }
        return '\' + $path.Trim('\')
    }

    function ConvertTo-TaskIsoDuration([TimeSpan]$ts){
        if($ts -lt [TimeSpan]::FromMinutes(1)){
            throw "Repetition duration must be at least 1 minute."
        }

        $out = 'P'
        if($ts.Days -gt 0){ $out += "$($ts.Days)D" }

        $timePart = ''
        if($ts.Hours   -gt 0){ $timePart += "$($ts.Hours)H" }
        if($ts.Minutes -gt 0){ $timePart += "$($ts.Minutes)M" }
        if($ts.Seconds -gt 0){ $timePart += "$($ts.Seconds)S" }

        if([string]::IsNullOrEmpty($timePart)){
            $timePart = '0S'
        }

        return $out + 'T' + $timePart
    }

    function Resolve-RepeatTimeSpan([object]$value){
        if($null -eq $value){ return $null }

        if($value -is [TimeSpan]){ return [TimeSpan]$value }

        if($value -is [int] -or $value -is [long]){
            return [TimeSpan]::FromMinutes([double]$value)
        }

        $s = [string]$value
        $ts = [TimeSpan]::Zero
        if([TimeSpan]::TryParse($s, [ref]$ts)){
            return $ts
        }

        throw "Invalid -RepeatFor. Use [TimeSpan], 'hh:mm[:ss]', 'd.hh:mm:ss', or integer minutes."
    }

    function Set-TriggerRepetition($trigger, [string]$intervalIso, [string]$durationIso, [bool]$stopAtDurationEnd){
        if(-not $trigger -or [string]::IsNullOrWhiteSpace($intervalIso)){ return }
        $rp = $trigger.Repetition
        $rp.Interval = $intervalIso
        $rp.Duration = $durationIso
        $rp.StopAtDurationEnd = $stopAtDurationEnd
    }

    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = [Security.Principal.WindowsPrincipal]$id
    $IsElevated = $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $CurrentUser = $id.Name
    $TaskFolder = Normalize-TaskFolderPath $TaskFolder

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

    $resolvedActionPath = Resolve-ActionPath $ActionPath
    if($resolvedActionPath){
        $ActionPath = $resolvedActionPath
    } elseif(-not $ForceRegister) {
        _writeErrT ("ActionPath not found: {0}" -f $ActionPath)
        _writeHint  "Provide a full path, something resolvable by Get-Command, or pass -ForceRegister."
        throw "ActionPath not found."
    } else {
        _writeHint ("Continuing with non-resolved ActionPath '{0}' (command lookup at runtime)." -f $ActionPath)
    }

    if(-not $IsElevated -and $RunAsAccount -eq 'System'){
        _writeErrT "System principal requires an elevated PowerShell."
        _writeHint "Relaunch as Administrator or use -Background with -Credential for user context."
        throw "Elevation required."
    }
    if(-not $IsElevated -and $RunAsAccount -eq 'SpecificUser' -and $SpecificUser -and -not (Test-UserMatches -expect $CurrentUser -actual $SpecificUser)){
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

    if($PSBoundParameters.ContainsKey('RepeatFor') -and -not $PSBoundParameters.ContainsKey('RepeatEveryMinutes')){
        _writeErrT "-RepeatFor requires -RepeatEveryMinutes."
        throw "Invalid repetition configuration."
    }

    $repeatIntervalIso = $null
    $repeatDurationIso = $null
    $repeatForTs = $null

    if($PSBoundParameters.ContainsKey('RepeatEveryMinutes')){
        $repeatIntervalIso = ('PT{0}M' -f $RepeatEveryMinutes)

        if($PSBoundParameters.ContainsKey('RepeatFor')){
            $repeatForTs = Resolve-RepeatTimeSpan $RepeatFor
        }
        elseif($DailyAtTime){
            $repeatForTs = [TimeSpan]::FromHours(23) + [TimeSpan]::FromMinutes(59)
            _writeInfo "-RepeatEveryMinutes with -DailyAtTime and no -RepeatFor -> defaulting to 23:59."
        }
        elseif($Startup -or $LogonThisUser -or $LogonAnyUser){
            $repeatForTs = [TimeSpan]::FromDays(1)
            _writeHint "-RepeatEveryMinutes with Startup/Logon and no -RepeatFor defaults to 1 day. Set -RepeatFor explicitly to change that."
        } else {
            _writeErrT "-RepeatEveryMinutes needs a base trigger such as -DailyAtTime, -Startup, -LogonThisUser, or -LogonAnyUser."
            throw "Invalid repetition configuration."
        }

        if($repeatForTs -lt [TimeSpan]::FromMinutes($RepeatEveryMinutes)){
            _writeHint "-RepeatFor is shorter than -RepeatEveryMinutes, so the task may only run once per trigger."
        }

        $repeatDurationIso = ConvertTo-TaskIsoDuration $repeatForTs
    }

    if($Background -and $DoNotStorePassword){
        $arguments = [string]$ActionArguments
        if($ActionPath -like '\\*' -or $arguments -match '(?i)(^|[^A-Za-z0-9_])(\\\\[^\\]+\\|smb:)'){
            _writeHint "S4U selected: background token has no network access. If you need UNC/mapped shares, use -Credential instead."
        }
    }

    $svc = $null
    $folder = $null
    $def = $null
    $trigs = $null
    $act = $null
    $registeredTask = $null
    $runningTask = $null

    try{
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()

        function Resolve-TaskFolder([__comobject]$service,[string]$path){
            $path = ($path -replace '/','\')
            if([string]::IsNullOrWhiteSpace($path)){ $path='\' }
            if($path -eq '\'){ return $service.GetFolder('\') }

            $parts = $path.Trim('\').Split('\')
            $cur = $service.GetFolder('\')
            foreach($p in $parts){
                try { $cur = $cur.GetFolder("\$p") }
                catch { $cur = $cur.CreateFolder($p) }
            }
            return $cur
        }

        $folder = Resolve-TaskFolder -service $svc -path $TaskFolder
        $def = $svc.NewTask(0)

        $def.RegistrationInfo.Description = $Description
        $def.Settings.Enabled = $true
        $def.Settings.AllowDemandStart = $true
        $def.Settings.MultipleInstances = 0   # TASK_INSTANCES_IGNORE_NEW
        $def.Settings.StopIfGoingOnBatteries = $false
        $def.Settings.DisallowStartIfOnBatteries = $false
        $def.Settings.RunOnlyIfNetworkAvailable = $false
        $def.Settings.StartWhenAvailable = $true
        $def.Settings.ExecutionTimeLimit = 'PT24H'
        if($WakeComputer){ $def.Settings.WakeToRun = $true }

        $TaskLogon = @{ Password=1; S4U=2; Interactive=3; Service=5 }
        $p = $def.Principal
        if($Highest){ $p.RunLevel = 1 }

        $RegUser = $null
        $RegPwd = $null
        $RegLogon = $null

        switch($RunAsAccount){
            'System'{
                $p.UserId = 'SYSTEM'
                $p.LogonType = $TaskLogon.Service
                $RegUser = 'SYSTEM'
                $RegLogon = $TaskLogon.Service
            }
            'CurrentUser'{
                $p.UserId = $CurrentUser
                if($Background){
                    if($DoNotStorePassword){
                        $p.LogonType = $TaskLogon.S4U
                        $RegUser = $CurrentUser
                        $RegLogon = $TaskLogon.S4U
                    } else {
                        if(-not $Credential){
                            if($NoPrompt){ throw "Credentials required; supply -Credential or use -DoNotStorePassword (elevated)." }
                            $Credential = Get-Credential -Message "Enter password for $CurrentUser to run when not logged on"
                        } elseif(-not (Test-UserMatches -expect $CurrentUser -actual $Credential.UserName)){
                            _writeHint ("Credential user '{0}' does not match current user '{1}'. This can cause 0x8007052E." -f $Credential.UserName, $CurrentUser)
                        }

                        $p.LogonType = $TaskLogon.Password
                        $RegUser = $Credential.UserName
                        $RegPwd = $Credential.GetNetworkCredential().Password
                        $RegLogon = $TaskLogon.Password
                    }
                } else {
                    $p.LogonType = $TaskLogon.Interactive
                    $RegLogon = $TaskLogon.Interactive
                }
            }
            'SpecificUser'{
                $p.UserId = $SpecificUser
                if($Background){
                    if($DoNotStorePassword){
                        $p.LogonType = $TaskLogon.S4U
                        $RegUser = $SpecificUser
                        $RegLogon = $TaskLogon.S4U
                    } else {
                        if(-not $Credential -or -not (Test-UserMatches -expect $SpecificUser -actual $Credential.UserName)){
                            if($NoPrompt){ throw "Credentials for $SpecificUser required; username must match the run-as account." }
                            $Credential = Get-Credential -UserName $SpecificUser -Message "Enter password for $SpecificUser to run when not logged on"
                        }

                        $p.LogonType = $TaskLogon.Password
                        $RegUser = $Credential.UserName
                        $RegPwd = $Credential.GetNetworkCredential().Password
                        $RegLogon = $TaskLogon.Password
                    }
                } else {
                    $p.LogonType = $TaskLogon.Interactive
                    $RegLogon = $TaskLogon.Interactive
                }
            }
        }

        $act = $def.Actions.Create(0)
        $act.Path = $ActionPath
        if($ActionArguments){ $act.Arguments = $ActionArguments }
        if($WorkingDirectory){ $act.WorkingDirectory = $WorkingDirectory }

        $trigs = $def.Triggers

        if($Startup){
            $bt = $trigs.Create(8)
            Set-TriggerRepetition $bt $repeatIntervalIso $repeatDurationIso ([bool]$StopAtDurationEnd)
            _writeInfo "Added Startup trigger."
        }

        if($LogonThisUser){
            $lt = $trigs.Create(9)
            if($RunAsAccount -eq 'CurrentUser'){ $lt.UserId = $CurrentUser }
            elseif($RunAsAccount -eq 'SpecificUser'){ $lt.UserId = $SpecificUser }
            Set-TriggerRepetition $lt $repeatIntervalIso $repeatDurationIso ([bool]$StopAtDurationEnd)
            _writeInfo "Added Logon trigger for specific user."
        }

        if($LogonAnyUser){
            $la = $trigs.Create(9)
            $la.UserId = $null
            Set-TriggerRepetition $la $repeatIntervalIso $repeatDurationIso ([bool]$StopAtDurationEnd)
            _writeInfo "Added Logon trigger for ANY user."
        }

        if($dailyStart){
            $start = [datetime]::Today.AddHours($dailyStart.Hour).AddMinutes($dailyStart.Minute)
            if($start -lt (Get-Date)) { $start = $start.AddDays(1) }

            $dt = $trigs.Create(2)  # DAILY
            $dt.StartBoundary = $start.ToString('s')
            $dt.DaysInterval  = 1
            Set-TriggerRepetition $dt $repeatIntervalIso $repeatDurationIso ([bool]$StopAtDurationEnd)

            if($repeatIntervalIso){
                _writeInfo ("Added Daily trigger at {0} with repetition every {1} minute(s)." -f $start.ToShortTimeString(), $RepeatEveryMinutes)
            } else {
                _writeInfo ("Added Daily trigger at {0}." -f $start.ToShortTimeString())
            }
        }

        $TASK_CREATE_OR_UPDATE = 6
        $taskPath = if($TaskFolder -eq '\'){ "\$TaskName" } else { "$TaskFolder\$TaskName" }

        try{
            $registeredTask = $folder.RegisterTaskDefinition($TaskName, $def, $TASK_CREATE_OR_UPDATE, $RegUser, $RegPwd, $RegLogon, $null)
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
                default      { _writeHint "Verify elevation (if needed), credentials, action paths, and folder ACLs." }
            }
            throw
        }

        $startedNow = $false
        if($RunNow){
            try{
                $runningTask = $registeredTask.Run($null)
                $startedNow = $true
                _writeInfo "Started task immediately (-RunNow)."
            } catch {
                $hr = ('0x{0:X8}' -f $_.Exception.HResult)
                _writeErrT ("Task was registered, but immediate start failed (HRESULT={0}). {1}" -f $hr, $_.Exception.Message)
                switch($hr){
                    '0x80041326' { _writeHint "The task is disabled. Enable it first." }
                    '0x80070534' { _writeHint "No mapping between account names and security IDs. Re-check the run-as account." }
                    default      { _writeHint "The task exists, but RunNow failed. Try starting it manually once from Task Scheduler to inspect the runtime context." }
                }
                throw
            }
        }

        $logonTypeName = switch($RegLogon){
            1 {'Password'}
            2 {'S4U'}
            3 {'Interactive'}
            5 {'Service'}
            default {"$RegLogon"}
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
            TaskPath           = $taskPath
            TaskFolder         = $TaskFolder
            TaskName           = $TaskName
            Principal          = $RunAsAccount
            PrincipalUser      = if($RunAsAccount -eq 'CurrentUser'){$CurrentUser} elseif($RunAsAccount -eq 'SpecificUser'){$SpecificUser} else {'SYSTEM'}
            LogonType          = $logonTypeName
            Background         = $bgMode
            Triggers           = $trigList
            RepeatEveryMinutes = if($repeatIntervalIso){ $RepeatEveryMinutes } else { $null }
            RepeatFor          = if($repeatDurationIso){ $repeatDurationIso } else { $null }
            StopAtDurationEnd  = [bool]$StopAtDurationEnd
            ActionPath         = $ActionPath
            ActionArgs         = $ActionArguments
            WorkingDir         = $WorkingDirectory
            Elevated           = $IsElevated
            WakeComputer       = [bool]$WakeComputer
            StartedNow         = $startedNow
        }

        if($Json){
            Write-Host ($result | ConvertTo-Json -Depth 4)
        }

        return $result
    }
    finally{
        _releaseCom $runningTask
        _releaseCom $registeredTask
        _releaseCom $act
        _releaseCom $trigs
        _releaseCom $def
        _releaseCom $folder
        _releaseCom $svc
    }
}
