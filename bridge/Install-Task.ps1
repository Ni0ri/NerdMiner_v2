<#
.SYNOPSIS
    Installiert die ClaudeMinerBridge nach C:\Tools\ClaudeMinerBridge und richtet eine geplante Aufgabe (alle 5 min) ein.

.DESCRIPTION
    - Kopiert ClaudeMinerBridge.ps1 und config.example.json in den Zielordner.
    - Legt config.json aus der Vorlage an, falls sie noch fehlt (bestehende config.json bleibt unverändert).
    - Registriert eine geplante Aufgabe für den angemeldeten Benutzer, die das Skript alle n Minuten ausblendet startet.
      Die Aufgabe läuft nur, wenn der Benutzer angemeldet ist (kein Kennwort nötig); das ist auch Voraussetzung dafür,
      dass der per DPAPI verschlüsselte Admin-Key entschlüsselt werden kann.
    - Mit -ConfigureStatusLine wird zusätzlich die Statuszeile von Claude Code auf Write-ClaudeStatusLine.ps1
      gesetzt (in %USERPROFILE%\.claude\settings.json, vorher Sicherungskopie). Darüber kommen die Abo-Limits
      ("Aktuelle Sitzung", "Diese Woche") auf das Display. Eine bereits vorhandene, andere Statuszeile wird nicht
      überschrieben, sondern nur gemeldet.
    - Mit -Uninstall wird nur die geplante Aufgabe entfernt (Ordner, Konfiguration und Logs bleiben).

    Voraussetzungen:
    - Windows 10/11, Windows PowerShell 5.1 oder PowerShell 7.x
    - Module: ScheduledTasks (in Windows enthalten)
    - Rechte: normaler Benutzer (Aufgabe für sich selbst); Schreibrecht auf den Zielordner

.PARAMETER InstallPath
    Zielordner. Standard: C:\Tools\ClaudeMinerBridge

.PARAMETER TaskName
    Name der geplanten Aufgabe. Standard: ClaudeMinerBridge

.PARAMETER IntervalMinutes
    Abstand der Läufe in Minuten (1-60). Standard: 5

.PARAMETER ConfigureStatusLine
    Trägt Write-ClaudeStatusLine.ps1 als Statuszeile in die Claude-Code-Einstellungen ein.

.PARAMETER ClaudeSettingsPath
    Pfad der Claude-Code-Benutzereinstellungen. Standard: %USERPROFILE%\.claude\settings.json

.PARAMETER NoHeadless
    Startet die Aufgabe direkt mit powershell.exe statt über "conhost.exe --headless" (nur für Windows-Versionen
    vor 10 1809 nötig; dann blitzt alle 5 min kurz ein Konsolenfenster auf).

.PARAMETER Uninstall
    Entfernt die geplante Aufgabe.

.PARAMETER LogPath
    Ordner für die Logdatei dieses Installationsskripts. Standard: Ordner des Skripts.

.PARAMETER SelfTest
    Führt die eingebauten Selbsttests aus und beendet das Skript.

.EXAMPLE
    .\Install-Task.ps1 -WhatIf
    Zeigt, welche Dateien kopiert und welche Aufgabe angelegt würden.

.EXAMPLE
    .\Install-Task.ps1
    Installiert nach C:\Tools\ClaudeMinerBridge und legt die Aufgabe "ClaudeMinerBridge" (alle 5 min) an.

.EXAMPLE
    .\Install-Task.ps1 -ConfigureStatusLine -WhatIf
    Zeigt, ob und wie die Claude-Code-Statuszeile eingetragen würde.

.EXAMPLE
    .\Install-Task.ps1 -Uninstall

.NOTES
    Autor:   Artur Warkentin
    Version: 1.2.1
    Datum:   2026-10-12
    Changelog:
      1.2.1  2026-10-12  Statuszeile mit festen Pfaden (PS 5.1 + Schrägstriche), eigener alter Eintrag wird aktualisiert
      1.2.0  2026-10-12  Aufgabe startet über "conhost.exe --headless" (kein aufblitzendes Fenster), -NoHeadless
      1.1.0  2026-10-12  Write-ClaudeStatusLine.ps1 mitkopieren, Schalter -ConfigureStatusLine
      1.0.0  2026-10-12  Erstversion
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallPath = 'C:\Tools\ClaudeMinerBridge',
    [string]$TaskName = 'ClaudeMinerBridge',
    [ValidateRange(1, 60)][int]$IntervalMinutes = 5,
    [switch]$ConfigureStatusLine,
    [switch]$NoHeadless,
    [string]$ClaudeSettingsPath = (Join-Path (Join-Path $HOME '.claude') 'settings.json'),
    [switch]$Uninstall,
    [string]$LogPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Ordner des Skripts selbst bestimmen: Windows PowerShell 5.1 liefert $PSScriptRoot in Parameter-Standardwerten
# leer, wenn das Skript mit Schrägstrichen aufgerufen wird (C:/Tools/...), wie es Claude Code für die Statuszeile tut.
$script:ScriptDir = $PSScriptRoot
foreach ($candidate in @($PSCommandPath, $MyInvocation.MyCommand.Path, $MyInvocation.MyCommand.Definition)) {
    if (-not $script:ScriptDir -and $candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $script:ScriptDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($candidate))
    }
}
if (-not $script:ScriptDir) { $script:ScriptDir = (Get-Location).Path }
if (-not $LogPath) { $LogPath = $script:ScriptDir }
$script:LogFile = Join-Path $LogPath ("Log_{0:yyyy-MM-dd}.log" -f (Get-Date))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

# --- Kernfunktionen (rein, gut testbar) ---------------------------------------
function Get-TaskArgument {
    <# Argumente für powershell.exe: ausgeblendet, ohne Profil, Skript per -File. #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    return '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ScriptPath
}

function Get-TaskCommand {
    <# Programm und Argumente der geplanten Aufgabe. -WindowStyle Hidden allein lässt kurz ein Konsolenfenster
       aufblitzen; "conhost.exe --headless" (ab Windows 10 1809) startet PowerShell ganz ohne Fenster,
       auch für Kindprozesse wie npx/node. #>
    param([Parameter(Mandatory)][string]$ScriptPath, [switch]$NoHeadless)
    $psArgs = Get-TaskArgument -ScriptPath $ScriptPath
    if ($NoHeadless) { return [pscustomobject]@{ Execute = 'powershell.exe'; Argument = $psArgs } }
    return [pscustomobject]@{ Execute = 'conhost.exe'; Argument = '--headless powershell.exe ' + $psArgs }
}

function Get-InstallPlan {
    <# Liefert die Kopieraktionen (Quelle -> Ziel); config.json nur, wenn sie noch fehlt. #>
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$TargetFolder,
        [bool]$ConfigExists
    )
    $plan = @(
        [pscustomobject]@{ Source = (Join-Path $SourceFolder 'ClaudeMinerBridge.ps1'); Target = (Join-Path $TargetFolder 'ClaudeMinerBridge.ps1') }
        [pscustomobject]@{ Source = (Join-Path $SourceFolder 'Write-ClaudeStatusLine.ps1'); Target = (Join-Path $TargetFolder 'Write-ClaudeStatusLine.ps1') }
        [pscustomobject]@{ Source = (Join-Path $SourceFolder 'config.example.json'); Target = (Join-Path $TargetFolder 'config.example.json') }
    )
    if (-not $ConfigExists) {
        $plan += [pscustomobject]@{ Source = (Join-Path $SourceFolder 'config.example.json'); Target = (Join-Path $TargetFolder 'config.json') }
    }
    return $plan
}

function Get-StatusLineCommand {
    <# Befehl für settings.json; Claude Code führt ihn unter Windows ggf. über Git Bash aus -> Schrägstriche. #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    $dir = (Split-Path -Parent $ScriptPath) -replace '\\', '/'
    # Cache- und Log-Pfad ausdrücklich mitgeben, damit sie nicht vom Arbeitsordner von Claude Code abhängen
    return 'powershell -NoProfile -ExecutionPolicy Bypass -File {0} -CachePath {1}/ratelimits.json -LogPath {1}' -f ($ScriptPath -replace '\\', '/'), $dir
}

function Get-StatusLineChange {
    <# Prüft die Claude-Code-Einstellungen: Action = add | update | same | conflict.
       Bei add/update enthält Settings das geänderte Objekt; eine fremde Statuszeile bleibt unangetastet. #>
    param($Settings, [Parameter(Mandatory)][string]$Command)
    if ($null -eq $Settings) { $Settings = [pscustomobject]@{} }
    $existing = $Settings.PSObject.Properties['statusLine']
    if ($null -ne $existing -and $null -ne $existing.Value) {
        $cmdProp = $existing.Value.PSObject.Properties['command']
        $current = $null
        if ($null -ne $cmdProp) { $current = [string]$cmdProp.Value }
        if ($current -eq $Command) { return [pscustomobject]@{ Action = 'same'; Settings = $Settings; Current = $current } }
        if ($current -match 'Write-ClaudeStatusLine\.ps1') {
            # Eigener, älterer Eintrag: aktualisieren statt als fremd zu melden
            $existing.Value | Add-Member -NotePropertyName 'command' -NotePropertyValue $Command -Force
            return [pscustomobject]@{ Action = 'update'; Settings = $Settings; Current = $current }
        }
        return [pscustomobject]@{ Action = 'conflict'; Settings = $Settings; Current = $current }
    }
    $Settings | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue ([pscustomobject]@{ type = 'command'; command = $Command }) -Force
    return [pscustomobject]@{ Action = 'add'; Settings = $Settings; Current = $null }
}

# --- Selbsttest ----------------------------------------------------------------
function Invoke-SelfTest {
    $a = Get-TaskArgument -ScriptPath 'C:\Tools\ClaudeMinerBridge\ClaudeMinerBridge.ps1'
    $p1 = @(Get-InstallPlan -SourceFolder 'src' -TargetFolder 'dst' -ConfigExists $false)
    $p2 = @(Get-InstallPlan -SourceFolder 'src' -TargetFolder 'dst' -ConfigExists $true)
    $cmd = Get-StatusLineCommand -ScriptPath 'C:\Tools\ClaudeMinerBridge\Write-ClaudeStatusLine.ps1'
    $add = Get-StatusLineChange -Settings ([pscustomobject]@{ model = 'opus' }) -Command $cmd
    $same = Get-StatusLineChange -Settings $add.Settings -Command $cmd
    $conflict = Get-StatusLineChange -Settings ([pscustomobject]@{ statusLine = [pscustomobject]@{ type = 'command'; command = 'x' } }) -Command $cmd
    $tests = @(
        @{ Name = 'Statuszeilen-Befehl mit Schrägstrichen und festen Pfaden'; Ok = ($cmd -eq 'powershell -NoProfile -ExecutionPolicy Bypass -File C:/Tools/ClaudeMinerBridge/Write-ClaudeStatusLine.ps1 -CachePath C:/Tools/ClaudeMinerBridge/ratelimits.json -LogPath C:/Tools/ClaudeMinerBridge') }
        @{ Name = 'Älterer eigener Eintrag wird aktualisiert'; Ok = ((Get-StatusLineChange -Settings ([pscustomobject]@{ statusLine = [pscustomobject]@{ type = 'command'; command = 'powershell -File C:/Tools/ClaudeMinerBridge/Write-ClaudeStatusLine.ps1' } }) -Command $cmd).Action -eq 'update') }
        @{ Name = 'Statuszeile wird ergänzt, andere Einstellungen bleiben'; Ok = ($add.Action -eq 'add' -and $add.Settings.model -eq 'opus' -and $add.Settings.statusLine.command -eq $cmd) }
        @{ Name = 'Gleiche Statuszeile wird erkannt'; Ok = ($same.Action -eq 'same') }
        @{ Name = 'Fremde Statuszeile wird nicht überschrieben'; Ok = ($conflict.Action -eq 'conflict' -and $conflict.Settings.statusLine.command -eq 'x') }
        @{ Name = 'Aufgabe startet über conhost --headless'; Ok = ((Get-TaskCommand -ScriptPath 'C:\x.ps1').Execute -eq 'conhost.exe' -and (Get-TaskCommand -ScriptPath 'C:\x.ps1').Argument -like '--headless powershell.exe -NoProfile *-File "C:\x.ps1"') }
        @{ Name = '-NoHeadless startet powershell.exe direkt'; Ok = ((Get-TaskCommand -ScriptPath 'C:\x.ps1' -NoHeadless).Execute -eq 'powershell.exe') }
        @{ Name = 'Argumente ausgeblendet und ohne Profil'; Ok = ($a -match '-WindowStyle Hidden' -and $a -match '-NoProfile' -and $a -match '-File "C:\\Tools\\ClaudeMinerBridge\\ClaudeMinerBridge\.ps1"') }
        @{ Name = 'Neuinstallation legt config.json an'; Ok = ($p1.Count -eq 4 -and $p1[3].Target -match 'config\.json$') }
        @{ Name = 'Bestehende config.json bleibt'; Ok = ($p2.Count -eq 3 -and -not ($p2.Target -match '[\\/]config\.json$')) }
    )
    $ok = @($tests | Where-Object { $_.Ok }).Count
    foreach ($t in $tests) { Write-Host ('{0} {1}' -f ($(if ($t.Ok) { '[OK]  ' } else { '[FAIL]' })), $t.Name) }
    Write-Host "$ok/$($tests.Count) Tests grün"
    if ($ok -ne $tests.Count) { exit 1 }
}

# --- Hauptteil -----------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }
if ($SelfTest) { Invoke-SelfTest; return }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$count = 0
try {
    Write-Log "Start (InstallPath=$InstallPath, TaskName=$TaskName, Intervall=$IntervalMinutes min, Uninstall=$Uninstall)"
    $prevWhatIf = $WhatIfPreference
    $WhatIfPreference = $false
    Import-Module ScheduledTasks
    $WhatIfPreference = $prevWhatIf

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($Uninstall) {
        if (-not $existing) { Write-Log "Aufgabe '$TaskName' ist nicht vorhanden." -Level WARN }
        elseif ($PSCmdlet.ShouldProcess($TaskName, 'Geplante Aufgabe entfernen')) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log "Aufgabe '$TaskName' entfernt. Ordner $InstallPath bleibt erhalten."
            $count++
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $InstallPath)) {
            if ($PSCmdlet.ShouldProcess($InstallPath, 'Ordner anlegen')) {
                New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
                $count++
            }
        }
        $configExists = Test-Path -LiteralPath (Join-Path $InstallPath 'config.json')
        foreach ($step in (Get-InstallPlan -SourceFolder $script:ScriptDir -TargetFolder $InstallPath -ConfigExists $configExists)) {
            if ($PSCmdlet.ShouldProcess($step.Target, "Kopieren von $($step.Source)")) {
                Copy-Item -LiteralPath $step.Source -Destination $step.Target -Force
                Write-Log "Kopiert: $($step.Target)"
                $count++
            }
        }
        if ($configExists) { Write-Log 'config.json existiert bereits und wurde nicht verändert.' }

        $scriptPath = Join-Path $InstallPath 'ClaudeMinerBridge.ps1'
        $taskCmd = Get-TaskCommand -ScriptPath $scriptPath -NoHeadless:$NoHeadless
        $action = New-ScheduledTaskAction -Execute $taskCmd.Execute -Argument $taskCmd.Argument -WorkingDirectory $InstallPath
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $verb = 'Geplante Aufgabe anlegen'
        if ($existing) { $verb = 'Geplante Aufgabe ersetzen' }
        if ($PSCmdlet.ShouldProcess("$TaskName (alle $IntervalMinutes min als $user)", $verb)) {
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -Description 'Sendet die Claude-Nutzung an den NerdMiner (POST /claude).' -Force | Out-Null
            Write-Log "Aufgabe '$TaskName' registriert (alle $IntervalMinutes min)."
            $count++
        }
        if ($ConfigureStatusLine) {
            $statusCmd = Get-StatusLineCommand -ScriptPath (Join-Path $InstallPath 'Write-ClaudeStatusLine.ps1')
            $settings = $null
            if (Test-Path -LiteralPath $ClaudeSettingsPath) {
                $settings = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ClaudeSettingsPath -Raw -Encoding UTF8)
            }
            $change = Get-StatusLineChange -Settings $settings -Command $statusCmd
            switch ($change.Action) {
                'same' { Write-Log 'Claude-Code-Statuszeile ist bereits eingerichtet.' }
                'conflict' {
                    Write-Log ("Claude Code hat schon eine andere Statuszeile ('{0}'). Nicht geändert. Zum Umstellen in {1} " -f $change.Current, $ClaudeSettingsPath) -Level WARN
                    Write-Log "  statusLine.command auf '$statusCmd' setzen." -Level WARN
                }
                { $_ -in @('add', 'update') } {
                    if ($PSCmdlet.ShouldProcess($ClaudeSettingsPath, 'Claude-Code-Statuszeile eintragen')) {
                        $dir = Split-Path -Parent $ClaudeSettingsPath
                        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                        if (Test-Path -LiteralPath $ClaudeSettingsPath) {
                            $backup = '{0}.bak-{1:yyyyMMdd-HHmmss}' -f $ClaudeSettingsPath, (Get-Date)
                            Copy-Item -LiteralPath $ClaudeSettingsPath -Destination $backup
                            Write-Log "Sicherung: $backup"
                        }
                        # Ohne BOM schreiben: Claude Code (Node.js) liest die Datei als reines JSON.
                        $json = $change.Settings | ConvertTo-Json -Depth 32
                        [System.IO.File]::WriteAllText($ClaudeSettingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
                        Write-Log "Claude-Code-Statuszeile eingetragen: $statusCmd"
                        $count++
                    }
                }
            }
        }
        Write-Log "Nächste Schritte: $InstallPath\config.json anpassen, dann '$scriptPath -Test' ausführen."
    }
    Write-Log ("Fertig: {0} Objekt(e) in {1:n1} s" -f $count, $sw.Elapsed.TotalSeconds)
}
catch {
    Write-Log "Fehler: $($_.Exception.Message)" -Level ERROR
    throw
}
