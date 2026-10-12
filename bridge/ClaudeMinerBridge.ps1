<#
.SYNOPSIS
    Holt die Claude-Nutzung (Tokens/Kosten) und sendet sie als kleines JSON an den NerdMiner (POST /claude).

.DESCRIPTION
    Bridge zwischen Anthropic bzw. lokalen Claude-Code-Logs und dem ESP32-NerdMiner mit Claude-Screen.
    Der ESP32 macht kein HTTPS und kennt keinen API-Key; alle Internet-Zugriffe macht dieses Skript auf dem PC,
    der ESP bekommt nur fertige Zahlen im LAN.

    Datenquellen (config.json -> source):
    - admin_api: Anthropic Usage & Cost Admin API (Console-/API-Nutzung, echte Kosten).
        * Tokens heute: Stunden-Buckets ab Mitternacht Europe/Berlin.
        * Tokens Monat: Tages-Buckets ab dem 1. des Monats (Tage in UTC, die API kennt nur UTC-Tage).
        * Kosten heute/Monat: Cost-Report, nur Tages-Buckets in UTC (Abweichung zur Berliner Zeit 1-2 h).
        * Input-Tokens = uncached + cache_read + cache_creation (5m + 1h), Output-Tokens = output_tokens.
    - ccusage: lokale Claude-Code-Logs über das Community-Tool ccusage (npm), Zeitzone Europe/Berlin.
        * Kosten sind rechnerische API-Preise, keine echten Abo-Kosten (Display beschriftet das).
    Abo-Limits (claude.ai Pro/Max, "Aktuelle Sitzung" und "Diese Woche"):
    - kommen aus der offiziell dokumentierten Statuszeilen-Schnittstelle von Claude Code
      (rate_limits.five_hour / seven_day). Write-ClaudeStatusLine.ps1 merkt sie sich in ratelimits.json,
      dieses Skript schickt sie als "limits" mit. Kein Scraping, keine inoffiziellen Endpunkte.
    - Aktuell nur, solange Claude Code lokal läuft; das Alter wird mitgeschickt und am Display angezeigt.

    Voraussetzungen:
    - Windows PowerShell 5.1 oder PowerShell 7.x
    - Module: (keine)
    - admin_api: Admin-API-Key (sk-ant-admin...), einmalig mit -SetAdminKey per DPAPI verschlüsselt ablegen
    - ccusage: Node.js mit npx (oder global installiertes ccusage)
    - Rechte: normaler Benutzer; die DPAPI-Datei kann nur derselbe Benutzer auf demselben PC entschlüsseln

.PARAMETER ConfigPath
    Pfad zur Konfiguration. Standard: config.json neben dem Skript.

.PARAMETER Test
    Sendet feste Beispieldaten (source = "test") an den ESP, ohne eine Datenquelle abzufragen.

.PARAMETER SetAdminKey
    Fragt den Admin-API-Key verdeckt ab und speichert ihn per DPAPI (ConvertFrom-SecureString) in die Datei
    aus config.json -> admin_key_file. Danach Ende.

.PARAMETER LogPath
    Ordner für die Logdatei (Log_yyyy-MM-dd.log). Standard: Ordner des Skripts.

.PARAMETER SelfTest
    Führt die eingebauten Selbsttests (ohne Netzwerk) aus und beendet das Skript.

.EXAMPLE
    .\ClaudeMinerBridge.ps1 -Test
    Sendet Beispieldaten an den ESP. Der Claude-Screen sollte sie sofort zeigen.

.EXAMPLE
    .\ClaudeMinerBridge.ps1 -SetAdminKey
    Legt den Admin-API-Key verschlüsselt ab (nur für source = admin_api nötig).

.EXAMPLE
    .\ClaudeMinerBridge.ps1 -WhatIf -Verbose
    Fragt die Datenquelle ab und zeigt das JSON, sendet aber nichts an den ESP.

.EXAMPLE
    .\ClaudeMinerBridge.ps1 -SelfTest

.NOTES
    Autor:   Artur Warkentin
    Version: 1.1.0
    Datum:   2026-10-12
    Changelog:
      1.1.0  2026-10-12  Abo-Limits (Sitzung/Woche) aus der Claude-Code-Statuszeile mitsenden
      1.0.1  2026-10-12  ccusage: stderr-Hinweise von npm brechen unter Windows PowerShell 5.1 nicht mehr ab
      1.0.0  2026-10-12  Erstversion: Quellen admin_api und ccusage, -Test, DPAPI-Key, Log-Rotation
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Test,
    [switch]$SetAdminKey,
    [string]$LogPath = $PSScriptRoot,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:LogFile = Join-Path $LogPath ("Log_{0:yyyy-MM-dd}.log" -f (Get-Date))
$script:AnthropicBaseUri = 'https://api.anthropic.com/v1/organizations'
$script:AnthropicVersion = '2023-06-01'

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
        default { Write-Verbose $line }
    }
}

# --- Kernfunktionen (rein, gut testbar) ---------------------------------------

function Get-BerlinTimeZone {
    # Windows kennt "W. Europe Standard Time", Linux/macOS (pwsh 7) die IANA-ID.
    foreach ($id in @('W. Europe Standard Time', 'Europe/Berlin')) {
        try { return [System.TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { Write-Verbose "Zeitzone $id nicht gefunden" }
    }
    throw 'Zeitzone Europe/Berlin wurde auf diesem System nicht gefunden.'
}

function Get-PeriodBound {
    <# Liefert die Zeitgrenzen für "heute" und "Monat" (Europe/Berlin) als UTC-Zeitpunkte. #>
    param(
        [Parameter(Mandatory)][datetime]$UtcNow,
        [Parameter(Mandatory)][System.TimeZoneInfo]$TimeZone
    )
    $utc = [datetime]::SpecifyKind($UtcNow, [System.DateTimeKind]::Utc)
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $TimeZone)
    $dayStartLocal = [datetime]::SpecifyKind($local.Date, [System.DateTimeKind]::Unspecified)
    $monthStartLocal = [datetime]::SpecifyKind((New-Object datetime $local.Year, $local.Month, 1), [System.DateTimeKind]::Unspecified)
    $offset = $TimeZone.GetUtcOffset($utc)
    $sign = '+'
    if ($offset -lt [TimeSpan]::Zero) { $sign = '-' }
    [pscustomobject]@{
        LocalNow          = $local
        TodayStartUtc     = [System.TimeZoneInfo]::ConvertTimeToUtc($dayStartLocal, $TimeZone)
        MonthStartUtcDay  = [datetime]::SpecifyKind((New-Object datetime $local.Year, $local.Month, 1), [System.DateTimeKind]::Utc)
        MonthStartUtc     = [System.TimeZoneInfo]::ConvertTimeToUtc($monthStartLocal, $TimeZone)
        TodayUtcDay       = $utc.Date
        LocalDateText     = $local.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
        MonthSinceText    = $monthStartLocal.ToString('yyyyMMdd', [cultureinfo]::InvariantCulture)
        UpdatedIso        = $local.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture) + $sign + $offset.Duration().ToString('hh\:mm')
    }
}

function ConvertTo-IsoUtc {
    param([Parameter(Mandatory)][datetime]$Utc)
    return $Utc.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
}

function ConvertTo-UtcDateTime {
    # pwsh 7 macht aus ISO-Strings bei ConvertFrom-Json bereits DateTime, Windows PowerShell 5.1 nicht.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    $d = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, $styles, [ref]$d)) { return $d }
    return $null
}

function Get-NumberOrZero {
    param($Value)
    if ($null -eq $Value) { return [double]0 }
    $d = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
    return [double]0
}

function Get-PropertyValue {
    # Liest eine Eigenschaft tolerant (fehlend -> $null), auch unter Set-StrictMode.
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-UsageTokenSum {
    <# Summiert Input-/Output-Tokens aus Usage-Report-Buckets (Seiten bereits zusammengeführt). #>
    param([object[]]$Buckets)
    $in = [double]0
    $out = [double]0
    foreach ($b in @($Buckets)) {
        foreach ($r in @(Get-PropertyValue $b 'results')) {
            if ($null -eq $r) { continue }
            $cc = Get-PropertyValue $r 'cache_creation'
            $in += (Get-NumberOrZero (Get-PropertyValue $r 'uncached_input_tokens')) +
                   (Get-NumberOrZero (Get-PropertyValue $r 'cache_read_input_tokens')) +
                   (Get-NumberOrZero (Get-PropertyValue $cc 'ephemeral_5m_input_tokens')) +
                   (Get-NumberOrZero (Get-PropertyValue $cc 'ephemeral_1h_input_tokens'))
            $out += Get-NumberOrZero (Get-PropertyValue $r 'output_tokens')
        }
    }
    [pscustomobject]@{ InputTokens = [int64]$in; OutputTokens = [int64]$out }
}

function Get-CostSum {
    <# Summiert Kosten aus Cost-Report-Buckets. amount ist ein Dezimal-String in Cent ("123.45" = 1,2345 USD).
       Mit -OnlyBucketStartUtc wird nur der Bucket mit diesem Start (UTC-Tag) gezählt. #>
    param(
        [object[]]$Buckets,
        [Nullable[datetime]]$OnlyBucketStartUtc = $null
    )
    $cents = [double]0
    foreach ($b in @($Buckets)) {
        if ($null -ne $OnlyBucketStartUtc) {
            $start = ConvertTo-UtcDateTime (Get-PropertyValue $b 'starting_at')
            if ($null -eq $start -or $start.Date -ne ([datetime]$OnlyBucketStartUtc).Date) { continue }
        }
        foreach ($r in @(Get-PropertyValue $b 'results')) {
            if ($null -eq $r) { continue }
            $currency = Get-PropertyValue $r 'currency'
            if ($currency -and $currency -ne 'USD') { continue }
            $cents += Get-NumberOrZero (Get-PropertyValue $r 'amount')
        }
    }
    return [math]::Round($cents / 100.0, 2, [System.MidpointRounding]::AwayFromZero)
}

function ConvertFrom-CcusageJson {
    <# Wertet "ccusage daily --json" aus (ccusage >= 16: Feld "period", ältere Versionen: "date"). #>
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$TodayText,
        [Parameter(Mandatory)][string]$MonthPrefix
    )
    $parsed = ConvertFrom-Json -InputObject $Json
    $days = @(foreach ($d in @(Get-PropertyValue $parsed 'daily')) { $d })
    $result = [ordered]@{
        today = [ordered]@{ input_tokens = [int64]0; output_tokens = [int64]0; cost_usd = 0.0 }
        month = [ordered]@{ input_tokens = [int64]0; output_tokens = [int64]0; cost_usd = 0.0 }
    }
    foreach ($d in $days) {
        if ($null -eq $d) { continue }
        $day = Get-PropertyValue $d 'period'
        if (-not $day) { $day = Get-PropertyValue $d 'date' }
        $day = [string]$day
        if (-not $day.StartsWith($MonthPrefix)) { continue }
        $in = (Get-NumberOrZero (Get-PropertyValue $d 'inputTokens')) +
              (Get-NumberOrZero (Get-PropertyValue $d 'cacheCreationTokens')) +
              (Get-NumberOrZero (Get-PropertyValue $d 'cacheReadTokens'))
        $out = Get-NumberOrZero (Get-PropertyValue $d 'outputTokens')
        $cost = Get-NumberOrZero (Get-PropertyValue $d 'totalCost')
        $targets = @('month')
        if ($day -eq $TodayText) { $targets += 'today' }
        foreach ($t in $targets) {
            $result[$t].input_tokens += [int64]$in
            $result[$t].output_tokens += [int64]$out
            $result[$t].cost_usd += $cost
        }
    }
    foreach ($t in @('today', 'month')) { $result[$t].cost_usd = [math]::Round($result[$t].cost_usd, 2, [System.MidpointRounding]::AwayFromZero) }
    return $result
}

function Format-ResetText {
    <# Reset-Zeitpunkt (Unix-Sekunden) als kurze Berliner Zeit: heute "19:10", sonst "Fr 00:00". #>
    param([int64]$ResetsAt, [Parameter(Mandatory)][datetime]$UtcNow, [Parameter(Mandatory)][System.TimeZoneInfo]$TimeZone)
    if ($ResetsAt -le 0) { return '' }
    $utc = ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime().AddSeconds($ResetsAt)
    $utc = [datetime]::SpecifyKind($utc, [System.DateTimeKind]::Utc)
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $TimeZone)
    $today = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::SpecifyKind($UtcNow, [System.DateTimeKind]::Utc), $TimeZone).Date
    $time = $local.ToString('HH:mm', [cultureinfo]::InvariantCulture)
    if ($local.Date -eq $today) { return $time }
    $days = @('So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa')
    return '{0} {1}' -f $days[[int]$local.DayOfWeek], $time
}

function ConvertTo-LimitPayload {
    <# Wandelt ratelimits.json (von Write-ClaudeStatusLine.ps1) in den "limits"-Block für den ESP.
       Abgelaufene Fenster (resets_at vorbei) zählen als 0 %, weil das Limit inzwischen zurückgesetzt ist. #>
    param($Cache, [Parameter(Mandatory)][datetime]$UtcNow, [Parameter(Mandatory)][System.TimeZoneInfo]$TimeZone)
    if ($null -eq $Cache) { return $null }
    $nowUtc = [datetime]::SpecifyKind($UtcNow, [System.DateTimeKind]::Utc)
    $nowEpoch = [int64]($nowUtc - [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc')).TotalSeconds
    $result = [ordered]@{}
    foreach ($pair in @(@('session', 'five_hour'), @('week', 'seven_day'))) {
        $w = Get-PropertyValue $Cache $pair[1]
        if ($null -eq $w) { continue }
        $pct = Get-PropertyValue $w 'used_percentage'
        if ($null -eq $pct) { continue }
        $resets = [int64](Get-NumberOrZero (Get-PropertyValue $w 'resets_at'))
        if ($resets -gt 0 -and $resets -le $nowEpoch) {
            $result[$pair[0]] = [ordered]@{ used_pct = 0; resets = '' }
        }
        else {
            $result[$pair[0]] = [ordered]@{
                used_pct = [math]::Round((Get-NumberOrZero $pct), 1, [System.MidpointRounding]::AwayFromZero)
                resets   = (Format-ResetText -ResetsAt $resets -UtcNow $nowUtc -TimeZone $TimeZone)
            }
        }
    }
    if ($result.Count -eq 0) { return $null }
    $captured = ConvertTo-UtcDateTime (Get-PropertyValue $Cache 'captured_utc')
    if ($null -ne $captured) {
        $age = [int][math]::Floor(($nowUtc - $captured).TotalMinutes)
        if ($age -lt 0) { $age = 0 }
        $result['age_min'] = $age
    }
    return $result
}

function Read-LimitCache {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) }
    catch { Write-Log "Abo-Limits ($Path) unlesbar: $($_.Exception.Message)" -Level WARN; return $null }
}

function ConvertTo-ClaudePayload {
    <# Baut das JSON für POST /claude (max. ~1 KB). Fehlende Werte werden weggelassen. #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Updated,
        $Today,
        $Month,
        [Nullable[double]]$BudgetUsd = $null,
        $Limits = $null
    )
    $p = [ordered]@{ source = $Source; updated = $Updated }
    foreach ($name in @('today', 'month')) {
        $v = $Today
        if ($name -eq 'month') { $v = $Month }
        if ($null -eq $v) { continue }
        $o = [ordered]@{}
        foreach ($k in @('input_tokens', 'output_tokens')) { if ($null -ne $v[$k]) { $o[$k] = [int64]$v[$k] } }
        if ($null -ne $v['cost_usd']) { $o['cost_usd'] = [math]::Round([double]$v['cost_usd'], 2, [System.MidpointRounding]::AwayFromZero) }
        $p[$name] = $o
    }
    if ($null -ne $BudgetUsd -and $BudgetUsd -gt 0) { $p['budget_usd'] = [double]$BudgetUsd }
    if ($null -ne $Limits) { $p['limits'] = $Limits }
    $json = $p | ConvertTo-Json -Depth 4 -Compress
    if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt 1024) { throw "Payload zu groß ($($json.Length) Zeichen, max. 1024)." }
    return $json
}

function Get-TestPayload {
    param([Parameter(Mandatory)][string]$Updated, [Nullable[double]]$BudgetUsd = 100.0)
    ConvertTo-ClaudePayload -Source 'test' -Updated $Updated `
        -Today ([ordered]@{ input_tokens = 120000; output_tokens = 45000; cost_usd = 1.84 }) `
        -Month ([ordered]@{ input_tokens = 3100000; output_tokens = 980000; cost_usd = 41.20 }) -BudgetUsd $BudgetUsd `
        -Limits ([ordered]@{ session = [ordered]@{ used_pct = 6; resets = '19:10' }; week = [ordered]@{ used_pct = 42; resets = 'Fr 00:00' }; age_min = 3 })
}

function Read-BridgeConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Konfiguration '$Path' fehlt. config.example.json nach config.json kopieren und anpassen."
    }
    $cfg = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    $espHost = [string](Get-PropertyValue $cfg 'esp_host')
    if ([string]::IsNullOrWhiteSpace($espHost) -or $espHost -match '[/\s]') {
        throw "config.json: 'esp_host' fehlt oder ist ungültig (nur IP oder Hostname, z. B. nerdminer.local)."
    }
    $source = [string](Get-PropertyValue $cfg 'source')
    if ($source -notin @('admin_api', 'ccusage')) { throw "config.json: 'source' muss 'admin_api' oder 'ccusage' sein (ist: '$source')." }
    $budget = $null
    $b = Get-PropertyValue $cfg 'budget_usd'
    if ($null -ne $b -and "$b" -ne '') { $budget = [double](Get-NumberOrZero $b) }
    $keyFile = [string](Get-PropertyValue $cfg 'admin_key_file')
    if (-not $keyFile) { $keyFile = 'adminkey.dpapi' }
    if (-not [System.IO.Path]::IsPathRooted($keyFile)) { $keyFile = Join-Path (Split-Path -Parent $Path) $keyFile }
    $retention = [int](Get-NumberOrZero (Get-PropertyValue $cfg 'log_retention_days'))
    if ($retention -le 0) { $retention = 14 }
    $ccCmd = [string](Get-PropertyValue $cfg 'ccusage_command')
    if (-not $ccCmd) { $ccCmd = 'npx' }
    $limitsCache = [string](Get-PropertyValue $cfg 'limits_cache')
    if (-not $limitsCache) { $limitsCache = 'ratelimits.json' }
    if (-not [System.IO.Path]::IsPathRooted($limitsCache)) { $limitsCache = Join-Path (Split-Path -Parent $Path) $limitsCache }
    $ccArgs = @(foreach ($a in @(Get-PropertyValue $cfg 'ccusage_args')) { if ($null -ne $a) { [string]$a } })
    if ($ccArgs.Count -eq 0) { $ccArgs = @('--yes', 'ccusage@latest') }
    [pscustomobject]@{
        EspHost          = $espHost
        EspToken         = [string](Get-PropertyValue $cfg 'esp_token')
        Source           = $source
        BudgetUsd        = $budget
        AdminKeyFile     = $keyFile
        LogRetentionDays = $retention
        CcusageCommand   = $ccCmd
        CcusageArgs      = $ccArgs
        LimitsCache      = $limitsCache
    }
}

# --- Ein-/Ausgabe (in Tests gemockt) -------------------------------------------

function Read-AdminKey {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Admin-Key-Datei '$Path' fehlt. Einmalig '.\ClaudeMinerBridge.ps1 -SetAdminKey' ausführen."
    }
    $secure = ConvertTo-SecureString -String ((Get-Content -LiteralPath $Path -Raw).Trim())
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-AnthropicReport {
    <# Ruft einen Admin-API-Report ab und folgt der Paginierung (has_more/next_page). Liefert alle Buckets. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Query,
        [Parameter(Mandatory)][string]$ApiKey
    )
    $headers = @{ 'x-api-key' = $ApiKey; 'anthropic-version' = $script:AnthropicVersion; 'User-Agent' = 'ClaudeMinerBridge/1.1.0' }
    $buckets = New-Object System.Collections.Generic.List[object]
    $page = $null
    for ($i = 0; $i -lt 20; $i++) {
        $pairs = @(foreach ($k in ($Query.Keys | Sort-Object)) { '{0}={1}' -f $k, [uri]::EscapeDataString([string]$Query[$k]) })
        if ($page) { $pairs += 'page=' + [uri]::EscapeDataString($page) }
        $uri = '{0}/{1}?{2}' -f $script:AnthropicBaseUri, $Path, ($pairs -join '&')
        try {
            $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 30
        }
        catch {
            $code = $null
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            $hint = ''
            if ($code -eq 401 -or $code -eq 403) { $hint = ' Admin-Key ungültig oder ohne Berechtigung (sk-ant-admin... nötig).' }
            elseif ($code -eq 429) { $hint = ' Rate-Limit erreicht, später erneut.' }
            throw "Anthropic-API '$Path' fehlgeschlagen (HTTP $code): $($_.Exception.Message.TrimEnd('.')).$hint"
        }
        foreach ($b in @(Get-PropertyValue $resp 'data')) { if ($null -ne $b) { $buckets.Add($b) } }
        if (-not (Get-PropertyValue $resp 'has_more')) { break }
        $page = [string](Get-PropertyValue $resp 'next_page')
        if (-not $page) { break }
    }
    return , $buckets.ToArray()
}

function Get-AdminApiUsage {
    param(
        [Parameter(Mandatory)]$Bounds,
        [Parameter(Mandatory)][string]$ApiKey
    )
    $todayBuckets = Invoke-AnthropicReport -Path 'usage_report/messages' -ApiKey $ApiKey -Query @{
        starting_at = (ConvertTo-IsoUtc $Bounds.TodayStartUtc); bucket_width = '1h'; limit = 48 }
    $monthBuckets = Invoke-AnthropicReport -Path 'usage_report/messages' -ApiKey $ApiKey -Query @{
        starting_at = (ConvertTo-IsoUtc $Bounds.MonthStartUtcDay); bucket_width = '1d'; limit = 31 }
    $costBuckets = Invoke-AnthropicReport -Path 'cost_report' -ApiKey $ApiKey -Query @{
        starting_at = (ConvertTo-IsoUtc $Bounds.MonthStartUtcDay); bucket_width = '1d'; limit = 31 }

    $t = Get-UsageTokenSum -Buckets $todayBuckets
    $m = Get-UsageTokenSum -Buckets $monthBuckets
    [ordered]@{
        today = [ordered]@{ input_tokens = $t.InputTokens; output_tokens = $t.OutputTokens
            cost_usd = (Get-CostSum -Buckets $costBuckets -OnlyBucketStartUtc $Bounds.TodayUtcDay) }
        month = [ordered]@{ input_tokens = $m.InputTokens; output_tokens = $m.OutputTokens
            cost_usd = (Get-CostSum -Buckets $costBuckets) }
    }
}

function Invoke-CcusageCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments
    )
    # Bevorzugt npx.cmd statt npx.ps1 (unabhängig von der Ausführungsrichtlinie)
    $cmd = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { $cmd = Get-Command -Name $Command -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $cmd) { throw "ccusage: Befehl '$Command' nicht gefunden. Node.js installieren (npx) oder 'npm i -g ccusage'." }

    # Windows PowerShell 5.1 macht aus jeder stderr-Zeile eines externen Programms (z. B. "npm notice")
    # einen Fehler, der mit ErrorActionPreference = 'Stop' abbricht. Deshalb hier lokal 'Continue',
    # stderr getrennt sammeln und nur den Exitcode bewerten.
    $prevPref = $ErrorActionPreference
    $prevNotifier = $env:NPM_CONFIG_UPDATE_NOTIFIER
    $ErrorActionPreference = 'Continue'
    $env:NPM_CONFIG_UPDATE_NOTIFIER = 'false'
    try {
        $all = @(& $cmd.Source @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevPref
        $env:NPM_CONFIG_UPDATE_NOTIFIER = $prevNotifier
    }
    $stdout = @(foreach ($line in $all) { if ($line -isnot [System.Management.Automation.ErrorRecord]) { [string]$line } })
    $stderr = @(foreach ($line in $all) { if ($line -is [System.Management.Automation.ErrorRecord]) { $line.ToString() } })
    if ($stderr.Count -gt 0) { Write-Verbose ("ccusage stderr: " + ($stderr -join ' | ')) }
    if ($exitCode -ne 0) { throw "ccusage wurde mit Exitcode $exitCode beendet: $(($stderr | Select-Object -Last 3) -join ' ')" }
    return ($stdout -join "`n")
}

function Get-CcusageUsage {
    param(
        [Parameter(Mandatory)]$Bounds,
        [Parameter(Mandatory)]$Config
    )
    $ccArgs = @($Config.CcusageArgs) + @('daily', '--json', '--since', $Bounds.MonthSinceText, '--timezone', 'Europe/Berlin')
    $json = Invoke-CcusageCommand -Command $Config.CcusageCommand -Arguments $ccArgs
    $start = $json.IndexOf('{')
    if ($start -lt 0) { throw 'ccusage lieferte kein JSON. Aufruf manuell testen: npx ccusage@latest daily --json' }
    return ConvertFrom-CcusageJson -Json $json.Substring($start) -TodayText $Bounds.LocalDateText -MonthPrefix $Bounds.LocalDateText.Substring(0, 7)
}

function Send-ClaudePayload {
    param(
        [Parameter(Mandatory)][string]$EspHost,
        [string]$Token,
        [Parameter(Mandatory)][string]$Json
    )
    $headers = @{}
    if ($Token) { $headers['X-Token'] = $Token }
    $uri = "http://$EspHost/claude"
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($Json)) -TimeoutSec 10
    }
    catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        $hint = ' ESP erreichbar? IP/Hostname in config.json prüfen.'
        if ($code -eq 401) { $hint = ' X-Token in config.json passt nicht zur Einstellung im NerdMiner-Portal.' }
        elseif ($code -eq 400) { $hint = ' ESP hat das JSON abgelehnt.' }
        throw "Senden an $uri fehlgeschlagen (HTTP $code): $($_.Exception.Message.TrimEnd('.')).$hint"
    }
    if (-not (Get-PropertyValue $resp 'ok')) { throw "ESP antwortete ohne ok=true: $($resp | ConvertTo-Json -Compress)" }
}

function Remove-OldLog {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Folder, [int]$RetentionDays = 14)
    $limit = (Get-Date).Date.AddDays(-$RetentionDays)
    $old = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^Log_\d{4}-\d{2}-\d{2}\.log$' -and $_.LastWriteTime -lt $limit })
    foreach ($f in $old) {
        if ($PSCmdlet.ShouldProcess($f.FullName, 'Alte Logdatei löschen')) { Remove-Item -LiteralPath $f.FullName -Force }
    }
    return $old.Count
}

# --- Selbsttest ----------------------------------------------------------------
function Invoke-SelfTest {
    $tz = Get-BerlinTimeZone
    $summer = Get-PeriodBound -UtcNow ([datetime]'2026-10-12T10:55:00') -TimeZone $tz
    $winter = Get-PeriodBound -UtcNow ([datetime]'2026-01-01T00:30:00') -TimeZone $tz
    $usageJson = '{"data":[{"starting_at":"2026-10-12T00:00:00Z","results":[{"uncached_input_tokens":100,"cache_read_input_tokens":20,' +
                 '"cache_creation":{"ephemeral_5m_input_tokens":3,"ephemeral_1h_input_tokens":4},"output_tokens":50}]},' +
                 '{"starting_at":"2026-10-12T01:00:00Z","results":[]}],"has_more":false,"next_page":null}'
    $usage = Get-UsageTokenSum -Buckets @((ConvertFrom-Json $usageJson).data)
    $costJson = '{"data":[{"starting_at":"2026-10-11T00:00:00Z","results":[{"amount":"100.0","currency":"USD"}]},' +
                '{"starting_at":"2026-10-12T00:00:00Z","results":[{"amount":"123.78912","currency":"USD"},{"amount":"60","currency":"USD"}]}]}'
    $costBuckets = @((ConvertFrom-Json $costJson).data)
    $ccJson = '{"daily":[{"period":"2026-10-11","inputTokens":10,"cacheCreationTokens":5,"cacheReadTokens":100,"outputTokens":7,"totalCost":0.5},' +
              '{"date":"2026-10-12","inputTokens":1,"cacheCreationTokens":2,"cacheReadTokens":3,"outputTokens":4,"totalCost":1.234},' +
              '{"period":"2026-09-30","inputTokens":999,"outputTokens":999,"totalCost":9}]}'
    $cc = ConvertFrom-CcusageJson -Json $ccJson -TodayText '2026-10-12' -MonthPrefix '2026-10'
    $single = ConvertFrom-CcusageJson -Json '{"daily":[{"period":"2026-10-12","inputTokens":1,"outputTokens":2,"totalCost":3}]}' -TodayText '2026-10-12' -MonthPrefix '2026-10'
    $payload = Get-TestPayload -Updated '2026-10-12T12:55:00+02:00'
    $limCache = ConvertFrom-Json '{"captured_utc":"2026-10-12T09:55:00Z","five_hour":{"used_percentage":80,"resets_at":1791795600},"seven_day":{"used_percentage":42,"resets_at":1792101600}}'
    $lim = ConvertTo-LimitPayload -Cache $limCache -UtcNow ([datetime]'2026-10-12T10:00:00') -TimeZone $tz
    $partial = ConvertTo-ClaudePayload -Source 'ccusage' -Updated 'x' -Today ([ordered]@{ cost_usd = 1.005 })

    $tests = @(
        @{ Name = 'Zeitzone Berlin gefunden'; Ok = ($null -ne $tz) }
        @{ Name = 'Sommerzeit: Tagesbeginn 22:00 UTC am Vortag'; Ok = ((ConvertTo-IsoUtc $summer.TodayStartUtc) -eq '2026-10-11T22:00:00Z') }
        @{ Name = 'Sommerzeit: Zeitstempel mit +02:00'; Ok = ($summer.UpdatedIso -eq '2026-10-12T12:55:00+02:00') }
        @{ Name = 'Monatsanfang als UTC-Tag'; Ok = ((ConvertTo-IsoUtc $summer.MonthStartUtcDay) -eq '2026-10-01T00:00:00Z' -and $summer.MonthSinceText -eq '20261001') }
        @{ Name = 'Winterzeit: Tageswechsel nach Berliner Zeit'; Ok = ($winter.LocalDateText -eq '2026-01-01' -and (ConvertTo-IsoUtc $winter.TodayStartUtc) -eq '2025-12-31T23:00:00Z' -and $winter.UpdatedIso.EndsWith('+01:00')) }
        @{ Name = 'Usage: Input = uncached + cache_read + cache_creation'; Ok = ($usage.InputTokens -eq 127 -and $usage.OutputTokens -eq 50) }
        @{ Name = 'Cost: Cent -> USD, Monat'; Ok = ((Get-CostSum -Buckets $costBuckets) -eq 2.84) }
        @{ Name = 'Cost: nur heutiger UTC-Tag'; Ok = ((Get-CostSum -Buckets $costBuckets -OnlyBucketStartUtc ([datetime]'2026-10-12')) -eq 1.84) }
        @{ Name = 'Zeitstempel aus String und DateTime als UTC'; Ok = ((ConvertTo-UtcDateTime '2026-10-12T00:00:00Z').Day -eq 12 -and (ConvertTo-UtcDateTime ([datetime]::SpecifyKind([datetime]'2026-10-12', 'Utc'))).Day -eq 12 -and $null -eq (ConvertTo-UtcDateTime 'kein Datum')) }
        @{ Name = 'ccusage: heute/Monat, alte und neue Feldnamen'; Ok = ($cc.today.input_tokens -eq 6 -and $cc.today.output_tokens -eq 4 -and $cc.today.cost_usd -eq 1.23 -and $cc.month.input_tokens -eq 121 -and $cc.month.cost_usd -eq 1.73) }
        @{ Name = 'ccusage: einzelner Tag (kein Array-Fehler unter PS 5.1)'; Ok = ($single.today.output_tokens -eq 2 -and $single.month.cost_usd -eq 3) }
        @{ Name = 'Payload enthält alle Felder'; Ok = ($payload -match '"source":"test"' -and $payload -match '"input_tokens":3100000' -and $payload -match '"budget_usd":100') }
        @{ Name = 'Payload ohne fehlende Felder'; Ok = ($partial -notmatch 'month' -and $partial -notmatch 'budget' -and $partial -notmatch 'input_tokens' -and $partial -match '"cost_usd":1') }
        @{ Name = 'Payload unter 1 KB'; Ok = ($payload.Length -lt 1024) }
        @{ Name = 'Reset heute nur Uhrzeit, sonst mit Wochentag'; Ok = ((Format-ResetText -ResetsAt 1791824400 -UtcNow ([datetime]'2026-10-12T10:00:00') -TimeZone $tz) -eq '19:00' -and (Format-ResetText -ResetsAt 1792101600 -UtcNow ([datetime]'2026-10-12T10:00:00') -TimeZone $tz) -eq 'Fr 00:00') }
        @{ Name = 'Limits: abgelaufenes Fenster zählt als 0 %, Alter in Minuten'; Ok = ($lim.session.used_pct -eq 0 -and $lim.week.used_pct -eq 42 -and $lim.week.resets -eq 'Fr 00:00' -and $lim.age_min -eq 5) }
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
    Write-Log "Start (Test=$Test, SetAdminKey=$SetAdminKey)"
    $config = Read-BridgeConfig -Path $ConfigPath

    if ($SetAdminKey) {
        $secure = Read-Host -Prompt 'Admin-API-Key (sk-ant-admin...)' -AsSecureString
        if ($PSCmdlet.ShouldProcess($config.AdminKeyFile, 'Admin-Key per DPAPI verschlüsselt speichern')) {
            ConvertFrom-SecureString -SecureString $secure | Set-Content -LiteralPath $config.AdminKeyFile -Encoding ASCII
            Write-Log "Admin-Key verschlüsselt gespeichert: $($config.AdminKeyFile)"
            $count++
        }
        return
    }

    $tz = Get-BerlinTimeZone
    $utcNow = [datetime]::UtcNow
    $bounds = Get-PeriodBound -UtcNow $utcNow -TimeZone $tz
    if ($Test) {
        $json = Get-TestPayload -Updated $bounds.UpdatedIso -BudgetUsd $config.BudgetUsd
    }
    else {
        if ($config.Source -eq 'admin_api') {
            $usage = Get-AdminApiUsage -Bounds $bounds -ApiKey (Read-AdminKey -Path $config.AdminKeyFile)
        }
        else {
            $usage = Get-CcusageUsage -Bounds $bounds -Config $config
        }
        $limits = ConvertTo-LimitPayload -Cache (Read-LimitCache -Path $config.LimitsCache) -UtcNow $utcNow -TimeZone $tz
        if ($null -eq $limits) { Write-Log "Keine Abo-Limits ($($config.LimitsCache)); Statuszeile in Claude Code eingerichtet?" }
        $json = ConvertTo-ClaudePayload -Source $config.Source -Updated $bounds.UpdatedIso -Today $usage.today -Month $usage.month -BudgetUsd $config.BudgetUsd -Limits $limits
    }
    Write-Log "Payload: $json"

    if ($PSCmdlet.ShouldProcess("http://$($config.EspHost)/claude", 'Claude-Nutzung senden')) {
        Send-ClaudePayload -EspHost $config.EspHost -Token $config.EspToken -Json $json
        Write-Log "Gesendet an $($config.EspHost)"
        $count++
    }

    $removed = Remove-OldLog -Folder $LogPath -RetentionDays $config.LogRetentionDays
    if ($removed -gt 0) { Write-Log "$removed alte Logdatei(en) bereinigt" }
    Write-Log ("Fertig: {0} Objekt(e) in {1:n1} s" -f $count, $sw.Elapsed.TotalSeconds)
}
catch {
    Write-Log "Fehler: $($_.Exception.Message)" -Level ERROR
    throw
}
