<#
.SYNOPSIS
    Statuszeile für Claude Code: zeigt Kontext und Abo-Limits an und merkt sich die Limits für die ClaudeMinerBridge.

.DESCRIPTION
    Claude Code ruft dieses Skript als "statusLine"-Befehl auf und übergibt die Sitzungsdaten als JSON über stdin
    (offiziell dokumentiert: https://code.claude.com/docs/en/statusline). Bei Pro/Max-Abos enthält das JSON
    rate_limits.five_hour und rate_limits.seven_day (used_percentage, resets_at) - das sind die Werte
    "Aktuelle Sitzung" und "Diese Woche" aus den claude.ai-Einstellungen.

    Das Skript
    - schreibt diese Werte in eine kleine Cache-Datei (Standard: ratelimits.json neben dem Skript),
      die ClaudeMinerBridge.ps1 an den NerdMiner weitergibt,
    - gibt eine Zeile für die Statusleiste aus, z. B. "Opus | Kontext 23 % | Sitzung 6 % | Woche 42 %".

    Es bricht nie mit Fehler ab (sonst bliebe die Statusleiste leer); Fehler landen im Log.
    Die Werte werden nur aktualisiert, solange Claude Code lokal läuft (nach jeder Antwort).

    Voraussetzungen:
    - Windows PowerShell 5.1 oder PowerShell 7.x
    - Claude Code mit claude.ai Pro/Max-Anmeldung (sonst enthält das JSON keine rate_limits)
    - Module: (keine); Rechte: normaler Benutzer

    Einrichtung (macht Install-Task.ps1 -ConfigureStatusLine), in %USERPROFILE%\.claude\settings.json:
      "statusLine": { "type": "command",
        "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Tools/ClaudeMinerBridge/Write-ClaudeStatusLine.ps1" }

.PARAMETER CachePath
    Datei für die zuletzt gesehenen Limits. Standard: ratelimits.json neben dem Skript.

.PARAMETER InputJson
    JSON direkt übergeben statt über stdin (zum Testen).

.PARAMETER LogPath
    Ordner für die Logdatei (nur Fehler). Standard: Ordner des Skripts.

.PARAMETER SelfTest
    Führt die eingebauten Selbsttests aus und beendet das Skript.

.EXAMPLE
    '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":6,"resets_at":1760288400}}}' | .\Write-ClaudeStatusLine.ps1
    Gibt die Statuszeile aus und schreibt ratelimits.json.

.EXAMPLE
    .\Write-ClaudeStatusLine.ps1 -InputJson '{"rate_limits":{}}' -WhatIf
    Zeigt nur, dass die Cache-Datei geschrieben würde.

.EXAMPLE
    .\Write-ClaudeStatusLine.ps1 -SelfTest

.NOTES
    Autor:   Artur Warkentin
    Version: 1.0.0
    Datum:   2026-10-12
    Changelog:
      1.0.0  2026-10-12  Erstversion
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CachePath = (Join-Path $PSScriptRoot 'ratelimits.json'),
    [string]$InputJson,
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
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] [StatusLine] {2}' -f (Get-Date), $Level, $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false } catch { Write-Verbose $line }
    Write-Verbose $line
}

# --- Kernfunktionen (rein, gut testbar) ---------------------------------------

function Get-JsonValue {
    param($Object, [Parameter(Mandatory)][string[]]$Path)
    $cur = $Object
    foreach ($name in $Path) {
        if ($null -eq $cur) { return $null }
        $p = $cur.PSObject.Properties[$name]
        if ($null -eq $p) { return $null }
        $cur = $p.Value
    }
    return $cur
}

function Get-RateLimitWindow {
    <# Liest ein Limit-Fenster (five_hour/seven_day) aus dem Statuszeilen-JSON; $null wenn nicht vorhanden. #>
    param($Status, [Parameter(Mandatory)][string]$Name)
    $pct = Get-JsonValue $Status @('rate_limits', $Name, 'used_percentage')
    $reset = Get-JsonValue $Status @('rate_limits', $Name, 'resets_at')
    if ($null -eq $pct) { return $null }
    $d = 0.0
    if (-not [double]::TryParse([string]$pct, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $null }
    $r = [int64]0
    if ($null -ne $reset) { [void][int64]::TryParse([string]$reset, [ref]$r) }
    [ordered]@{ used_percentage = [math]::Round($d, 1); resets_at = $r }
}

function Merge-RateLimitCache {
    <# Übernimmt neue Fenster, behält fehlende aus dem alten Cache (die Bridge erkennt abgelaufene am resets_at). #>
    param($OldCache, $Status, [Parameter(Mandatory)][datetime]$UtcNow)
    $result = [ordered]@{ captured_utc = $UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) }
    $changed = $false
    foreach ($name in @('five_hour', 'seven_day')) {
        $w = Get-RateLimitWindow -Status $Status -Name $name
        if ($null -ne $w) { $result[$name] = $w; $changed = $true }
        else {
            $old = Get-JsonValue $OldCache @($name)
            if ($null -ne $old) {
                $result[$name] = [ordered]@{ used_percentage = (Get-JsonValue $old @('used_percentage')); resets_at = (Get-JsonValue $old @('resets_at')) }
            }
        }
    }
    if (-not $changed) { return $null }
    return $result
}

function Format-StatusLineText {
    param($Status)
    $parts = New-Object System.Collections.Generic.List[string]
    $model = Get-JsonValue $Status @('model', 'display_name')
    if ($model) { $parts.Add([string]$model) }
    $ctx = Get-JsonValue $Status @('context_window', 'used_percentage')
    if ($null -ne $ctx) { $parts.Add(('Kontext {0:0} %' -f [double]$ctx)) }
    $s = Get-RateLimitWindow -Status $Status -Name 'five_hour'
    if ($null -ne $s) { $parts.Add(('Sitzung {0:0} %' -f $s.used_percentage)) }
    $w = Get-RateLimitWindow -Status $Status -Name 'seven_day'
    if ($null -ne $w) { $parts.Add(('Woche {0:0} %' -f $w.used_percentage)) }
    return ($parts -join ' | ')
}

# --- Selbsttest ----------------------------------------------------------------
function Invoke-SelfTest {
    $full = ConvertFrom-Json '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":23.4},"rate_limits":{"five_hour":{"used_percentage":6,"resets_at":1760288400},"seven_day":{"used_percentage":41.96,"resets_at":1760652000}}}'
    $onlyWeek = ConvertFrom-Json '{"rate_limits":{"seven_day":{"used_percentage":43,"resets_at":1760652000}}}'
    $none = ConvertFrom-Json '{"model":{"display_name":"Opus"}}'
    $now = [datetime]::SpecifyKind([datetime]'2026-10-12T14:00:00', 'Utc')
    $c1 = Merge-RateLimitCache -OldCache $null -Status $full -UtcNow $now
    $c2 = Merge-RateLimitCache -OldCache ([pscustomobject]@{ five_hour = [pscustomobject]@{ used_percentage = 6; resets_at = 1760288400 } }) -Status $onlyWeek -UtcNow $now
    $tests = @(
        @{ Name = 'Statuszeile mit Modell, Kontext und Limits'; Ok = ((Format-StatusLineText $full) -eq 'Opus | Kontext 23 % | Sitzung 6 % | Woche 42 %') }
        @{ Name = 'Statuszeile ohne Limits'; Ok = ((Format-StatusLineText $none) -eq 'Opus') }
        @{ Name = 'Cache übernimmt beide Fenster'; Ok = ($c1.five_hour.used_percentage -eq 6 -and $c1.seven_day.resets_at -eq 1760652000 -and $c1.captured_utc -eq '2026-10-12T14:00:00Z') }
        @{ Name = 'fehlendes Fenster bleibt aus altem Cache'; Ok = ($c2.five_hour.used_percentage -eq 6 -and $c2.seven_day.used_percentage -eq 43) }
        @{ Name = 'ohne rate_limits wird nichts geschrieben'; Ok = ($null -eq (Merge-RateLimitCache -OldCache $null -Status $none -UtcNow $now)) }
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
    $raw = $InputJson
    if (-not $raw) { $raw = [Console]::In.ReadToEnd() }
    $status = $null
    if ($raw) { $status = ConvertFrom-Json -InputObject $raw }

    $old = $null
    if (Test-Path -LiteralPath $CachePath) {
        try { $old = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8) }
        catch { Write-Log "Cache unlesbar, wird neu geschrieben: $($_.Exception.Message)" -Level WARN }
    }
    $cache = Merge-RateLimitCache -OldCache $old -Status $status -UtcNow ([datetime]::UtcNow)
    if ($null -ne $cache -and $PSCmdlet.ShouldProcess($CachePath, 'Abo-Limits speichern')) {
        $tmp = "$CachePath.tmp"
        ($cache | ConvertTo-Json -Depth 4 -Compress) | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $CachePath -Force
        $count++
    }
    Write-Output (Format-StatusLineText $status)
    Write-Verbose ("Fertig: {0} Objekt(e) in {1:n1} s" -f $count, $sw.Elapsed.TotalSeconds)
}
catch {
    # Nie mit Fehler enden: Claude Code zeigt sonst eine leere Statuszeile.
    Write-Log "Fehler: $($_.Exception.Message)" -Level ERROR
    Write-Output 'Statuszeile: Fehler (siehe Log)'
}
