<#
.SYNOPSIS
    Installiert die ClaudeMinerBridge nach C:\Tools\ClaudeMinerBridge und richtet eine geplante Aufgabe (alle 5 min) ein.

.DESCRIPTION
    - Kopiert ClaudeMinerBridge.ps1 und config.example.json in den Zielordner.
    - Legt config.json aus der Vorlage an, falls sie noch fehlt (bestehende config.json bleibt unverändert).
    - Registriert eine geplante Aufgabe für den angemeldeten Benutzer, die das Skript alle n Minuten ausblendet startet.
      Die Aufgabe läuft nur, wenn der Benutzer angemeldet ist (kein Kennwort nötig); das ist auch Voraussetzung dafür,
      dass der per DPAPI verschlüsselte Admin-Key entschlüsselt werden kann.
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
    .\Install-Task.ps1 -Uninstall

.NOTES
    Autor:   Artur Warkentin
    Version: 1.0.0
    Datum:   2026-10-12
    Changelog:
      1.0.0  2026-10-12  Erstversion
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallPath = 'C:\Tools\ClaudeMinerBridge',
    [string]$TaskName = 'ClaudeMinerBridge',
    [ValidateRange(1, 60)][int]$IntervalMinutes = 5,
    [switch]$Uninstall,
    [string]$LogPath = $PSScriptRoot,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
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

function Get-InstallPlan {
    <# Liefert die Kopieraktionen (Quelle -> Ziel); config.json nur, wenn sie noch fehlt. #>
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$TargetFolder,
        [bool]$ConfigExists
    )
    $plan = @(
        [pscustomobject]@{ Source = (Join-Path $SourceFolder 'ClaudeMinerBridge.ps1'); Target = (Join-Path $TargetFolder 'ClaudeMinerBridge.ps1') }
        [pscustomobject]@{ Source = (Join-Path $SourceFolder 'config.example.json'); Target = (Join-Path $TargetFolder 'config.example.json') }
    )
    if (-not $ConfigExists) {
        $plan += [pscustomobject]@{ Source = (Join-Path $SourceFolder 'config.example.json'); Target = (Join-Path $TargetFolder 'config.json') }
    }
    return $plan
}

# --- Selbsttest ----------------------------------------------------------------
function Invoke-SelfTest {
    $a = Get-TaskArgument -ScriptPath 'C:\Tools\ClaudeMinerBridge\ClaudeMinerBridge.ps1'
    $p1 = @(Get-InstallPlan -SourceFolder 'src' -TargetFolder 'dst' -ConfigExists $false)
    $p2 = @(Get-InstallPlan -SourceFolder 'src' -TargetFolder 'dst' -ConfigExists $true)
    $tests = @(
        @{ Name = 'Argumente ausgeblendet und ohne Profil'; Ok = ($a -match '-WindowStyle Hidden' -and $a -match '-NoProfile' -and $a -match '-File "C:\\Tools\\ClaudeMinerBridge\\ClaudeMinerBridge\.ps1"') }
        @{ Name = 'Neuinstallation legt config.json an'; Ok = ($p1.Count -eq 3 -and $p1[2].Target -match 'config\.json$') }
        @{ Name = 'Bestehende config.json bleibt'; Ok = ($p2.Count -eq 2 -and -not ($p2.Target -match '[\\/]config\.json$')) }
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
        foreach ($step in (Get-InstallPlan -SourceFolder $PSScriptRoot -TargetFolder $InstallPath -ConfigExists $configExists)) {
            if ($PSCmdlet.ShouldProcess($step.Target, "Kopieren von $($step.Source)")) {
                Copy-Item -LiteralPath $step.Source -Destination $step.Target -Force
                Write-Log "Kopiert: $($step.Target)"
                $count++
            }
        }
        if ($configExists) { Write-Log 'config.json existiert bereits und wurde nicht verändert.' }

        $scriptPath = Join-Path $InstallPath 'ClaudeMinerBridge.ps1'
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-TaskArgument -ScriptPath $scriptPath) -WorkingDirectory $InstallPath
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
        Write-Log "Nächste Schritte: $InstallPath\config.json anpassen, dann '$scriptPath -Test' ausführen."
    }
    Write-Log ("Fertig: {0} Objekt(e) in {1:n1} s" -f $count, $sw.Elapsed.TotalSeconds)
}
catch {
    Write-Log "Fehler: $($_.Exception.Message)" -Level ERROR
    throw
}
