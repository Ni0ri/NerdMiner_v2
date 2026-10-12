BeforeAll {
    $script:ScriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'ClaudeMinerBridge.ps1'
    . $script:ScriptPath -LogPath $TestDrive
    $script:Tz = Get-BerlinTimeZone
    $script:Bounds = Get-PeriodBound -UtcNow ([datetime]'2026-10-12T10:55:00') -TimeZone $script:Tz

    function script:New-TestConfig {
        param([hashtable]$Override = @{})
        $c = [ordered]@{ esp_host = '192.0.2.50'; esp_token = 'geheim'; source = 'ccusage'; budget_usd = 100.0 }
        foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }
        $path = Join-Path $TestDrive ('config_{0}.json' -f [guid]::NewGuid())
        $c | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }
}

Describe 'Zeitgrenzen Europe/Berlin' {
    It 'Tagesbeginn und Zeitstempel in der Sommerzeit' {
        ConvertTo-IsoUtc $script:Bounds.TodayStartUtc | Should -Be '2026-10-11T22:00:00Z'
        $script:Bounds.UpdatedIso | Should -Be '2026-10-12T12:55:00+02:00'
        $script:Bounds.LocalDateText | Should -Be '2026-10-12'
    }
    It 'Monatswechsel nach Berliner Zeit (31.10. 23:30 UTC ist schon November)' {
        $b = Get-PeriodBound -UtcNow ([datetime]'2026-10-31T23:30:00') -TimeZone $script:Tz
        $b.LocalDateText | Should -Be '2026-11-01'
        $b.MonthSinceText | Should -Be '20261101'
        ConvertTo-IsoUtc $b.MonthStartUtcDay | Should -Be '2026-11-01T00:00:00Z'
    }
}

Describe 'Auswertung Admin API' {
    It 'summiert Tokens über alle Buckets und Ergebnisse' {
        $buckets = @(
            [pscustomobject]@{ results = @([pscustomobject]@{ uncached_input_tokens = 1000; cache_read_input_tokens = 500
                        cache_creation = [pscustomobject]@{ ephemeral_5m_input_tokens = 10; ephemeral_1h_input_tokens = 0 }; output_tokens = 300 }) }
            [pscustomobject]@{ results = @() }
            [pscustomobject]@{ results = @([pscustomobject]@{ uncached_input_tokens = 1; output_tokens = 2 }) }
        )
        $s = Get-UsageTokenSum -Buckets $buckets
        $s.InputTokens | Should -Be 1511
        $s.OutputTokens | Should -Be 302
    }
    It 'rechnet Cent-Beträge in USD um und ignoriert andere Währungen' {
        $buckets = @([pscustomobject]@{ starting_at = '2026-10-12T00:00:00Z'; results = @(
                    [pscustomobject]@{ amount = '150.5'; currency = 'USD' },
                    [pscustomobject]@{ amount = '999'; currency = 'EUR' }) })
        Get-CostSum -Buckets $buckets | Should -Be 1.51
    }
    It 'folgt der Paginierung (has_more/next_page) und sendet die Pflicht-Header' {
        $script:calls = @()
        Mock Invoke-RestMethod {
            $script:calls += $Uri
            if ($Uri -notmatch 'page=') { return [pscustomobject]@{ data = @([pscustomobject]@{ results = @() }); has_more = $true; next_page = 'p2' } }
            return [pscustomobject]@{ data = @([pscustomobject]@{ results = @() }); has_more = $false; next_page = $null }
        }
        $b = Invoke-AnthropicReport -Path 'cost_report' -Query @{ starting_at = '2026-10-01T00:00:00Z'; bucket_width = '1d' } -ApiKey 'k'
        $b.Count | Should -Be 2
        $script:calls.Count | Should -Be 2
        # Windows PowerShell 5.1 gibt [Uri] unescaped aus (":" statt "%3A"), daher unescaped vergleichen
        [uri]::UnescapeDataString([string]$script:calls[0]) | Should -Be 'https://api.anthropic.com/v1/organizations/cost_report?bucket_width=1d&starting_at=2026-10-01T00:00:00Z'
        $script:calls[1] | Should -Match 'page=p2$'
        Should -Invoke Invoke-RestMethod -Times 2 -ParameterFilter { $Headers['x-api-key'] -eq 'k' -and $Headers['anthropic-version'] -eq '2023-06-01' }
    }
    It 'Get-AdminApiUsage fragt heute stündlich ab Berliner Mitternacht und den Monat täglich ab' {
        Mock Invoke-AnthropicReport {
            if ($Path -eq 'cost_report') {
                return , @([pscustomobject]@{ starting_at = '2026-10-11T00:00:00Z'; results = @([pscustomobject]@{ amount = '1000'; currency = 'USD' }) },
                    [pscustomobject]@{ starting_at = '2026-10-12T00:00:00Z'; results = @([pscustomobject]@{ amount = '184'; currency = 'USD' }) })
            }
            $n = 10
            if ($Query.bucket_width -eq '1d') { $n = 100 }
            return , @([pscustomobject]@{ results = @([pscustomobject]@{ uncached_input_tokens = $n; output_tokens = $n }) })
        }
        $u = Get-AdminApiUsage -Bounds $script:Bounds -ApiKey 'k'
        $u.today.input_tokens | Should -Be 10
        $u.month.output_tokens | Should -Be 100
        $u.today.cost_usd | Should -Be 1.84
        $u.month.cost_usd | Should -Be 11.84
        Should -Invoke Invoke-AnthropicReport -Times 1 -ParameterFilter { $Path -eq 'usage_report/messages' -and $Query.bucket_width -eq '1h' -and $Query.starting_at -eq '2026-10-11T22:00:00Z' }
        Should -Invoke Invoke-AnthropicReport -Times 1 -ParameterFilter { $Path -eq 'usage_report/messages' -and $Query.bucket_width -eq '1d' -and $Query.starting_at -eq '2026-10-01T00:00:00Z' }
    }
    It 'liefert eine sprechende Meldung bei HTTP-Fehler' {
        Mock Invoke-RestMethod { throw 'Unauthorized' }
        { Invoke-AnthropicReport -Path 'cost_report' -Query @{ a = 1 } -ApiKey 'k' } | Should -Throw '*cost_report*fehlgeschlagen*'
    }
}

Describe 'Auswertung ccusage' {
    It 'trennt heute und Monat und ignoriert Vormonat' {
        $json = '{"daily":[{"period":"2026-10-12","inputTokens":1,"cacheCreationTokens":2,"cacheReadTokens":3,"outputTokens":4,"totalCost":0.5},' +
                '{"period":"2026-10-01","inputTokens":10,"outputTokens":20,"totalCost":1},{"period":"2026-09-30","inputTokens":99,"outputTokens":99,"totalCost":9}]}'
        $r = ConvertFrom-CcusageJson -Json $json -TodayText '2026-10-12' -MonthPrefix '2026-10'
        $r.today.input_tokens | Should -Be 6
        $r.month.input_tokens | Should -Be 16
        $r.month.output_tokens | Should -Be 24
        $r.month.cost_usd | Should -Be 1.5
    }
    It 'ohne Nutzung im Monat liefert Nullwerte' {
        $r = ConvertFrom-CcusageJson -Json '{"daily":[],"totals":{}}' -TodayText '2026-10-12' -MonthPrefix '2026-10'
        $r.today.cost_usd | Should -Be 0
        $r.month.input_tokens | Should -Be 0
    }
    It 'ruft ccusage mit Monatsbeginn und Zeitzone auf und überspringt Text vor dem JSON' {
        Mock Invoke-CcusageCommand { "npx-Hinweis`n" + '{"daily":[{"period":"2026-10-12","inputTokens":5,"outputTokens":6,"totalCost":0.1}]}' }
        $cfg = Read-BridgeConfig -Path (New-TestConfig)
        $u = Get-CcusageUsage -Bounds $script:Bounds -Config $cfg
        $u.today.output_tokens | Should -Be 6
        Should -Invoke Invoke-CcusageCommand -Times 1 -ParameterFilter {
            $Command -eq 'npx' -and ($Arguments -join ' ') -eq '--yes ccusage@latest daily --json --since 20261001 --timezone Europe/Berlin' }
    }
}

Describe 'Aufruf externer Programme (ccusage)' {
    BeforeAll {
        # Die laufende PowerShell dient als "externes Programm", das wie npx auf stderr schreibt
        $script:Shell = (Get-Process -Id $PID).Path
    }
    It 'stderr-Hinweise (npm notice) brechen auch mit ErrorActionPreference Stop nicht ab' {
        $ErrorActionPreference = 'Stop'
        $out = Invoke-CcusageCommand -Command $script:Shell -Arguments @('-NoProfile', '-Command',
            "[Console]::Error.WriteLine('npm notice'); [Console]::Out.WriteLine('{""daily"":[]}')")
        $out | Should -Be '{"daily":[]}'
    }
    It 'Exitcode ungleich 0 wird mit stderr gemeldet' {
        { Invoke-CcusageCommand -Command $script:Shell -Arguments @('-NoProfile', '-Command',
                "[Console]::Error.WriteLine('kaputt'); exit 3") } | Should -Throw '*Exitcode 3*kaputt*'
    }
    It 'fehlender Befehl wird verständlich gemeldet' {
        { Invoke-CcusageCommand -Command 'gibtesnicht-xyz' -Arguments @() } | Should -Throw '*nicht gefunden*'
    }
}

Describe 'Payload und Konfiguration' {
    It 'Testpayload entspricht dem Format des ESP' {
        $o = Get-TestPayload -Updated '2026-10-12T12:55:00+02:00' | ConvertFrom-Json
        $o.source | Should -Be 'test'
        $o.today.cost_usd | Should -Be 1.84
        $o.month.input_tokens | Should -Be 3100000
        $o.budget_usd | Should -Be 100
    }
    It 'ohne Budget fehlt budget_usd' {
        ConvertTo-ClaudePayload -Source 'ccusage' -Updated 'x' -Today ([ordered]@{ cost_usd = 1 }) | Should -Not -Match 'budget'
    }
    It 'Read-BridgeConfig setzt Standardwerte' {
        $c = Read-BridgeConfig -Path (New-TestConfig)
        $c.EspHost | Should -Be '192.0.2.50'
        $c.LogRetentionDays | Should -Be 14
        $c.AdminKeyFile | Should -Match 'adminkey\.dpapi$'
        $c.CcusageArgs | Should -Be @('--yes', 'ccusage@latest')
    }
    It 'Read-BridgeConfig meldet ungültige Werte' {
        { Read-BridgeConfig -Path (Join-Path $TestDrive 'fehlt.json') } | Should -Throw '*config.example.json*'
        { Read-BridgeConfig -Path (New-TestConfig @{ source = 'claude_ai' }) } | Should -Throw "*'source'*"
        { Read-BridgeConfig -Path (New-TestConfig @{ esp_host = 'http://x/claude' }) } | Should -Throw "*'esp_host'*"
    }
}

Describe 'Abo-Limits aus der Statuszeile' {
    It 'Reset heute als Uhrzeit, sonst mit Wochentag (Berliner Zeit)' {
        $now = [datetime]'2026-10-12T10:00:00'
        Format-ResetText -ResetsAt 1791824400 -UtcNow $now -TimeZone $script:Tz | Should -Be '19:00'
        Format-ResetText -ResetsAt 1792101600 -UtcNow $now -TimeZone $script:Tz | Should -Be 'Fr 00:00'
        Format-ResetText -ResetsAt 0 -UtcNow $now -TimeZone $script:Tz | Should -Be ''
    }
    It 'wandelt den Cache in den limits-Block, abgelaufene Fenster zählen als 0 %' {
        $cache = ConvertFrom-Json '{"captured_utc":"2026-10-12T09:40:00Z","five_hour":{"used_percentage":80,"resets_at":1791795600},"seven_day":{"used_percentage":41.96,"resets_at":1792101600}}'
        $l = ConvertTo-LimitPayload -Cache $cache -UtcNow ([datetime]'2026-10-12T10:00:00') -TimeZone $script:Tz
        $l.session.used_pct | Should -Be 0
        $l.week.used_pct | Should -Be 42
        $l.week.resets | Should -Be 'Fr 00:00'
        $l.age_min | Should -Be 20
    }
    It 'ohne Cache gibt es keinen limits-Block' {
        ConvertTo-LimitPayload -Cache $null -UtcNow ([datetime]::UtcNow) -TimeZone $script:Tz | Should -BeNullOrEmpty
        Read-LimitCache -Path (Join-Path $TestDrive 'fehlt.json') | Should -BeNullOrEmpty
    }
    It 'Payload mit Limits bleibt unter 1 KB' {
        $json = Get-TestPayload -Updated '2026-10-12T12:55:00+02:00'
        $json.Length | Should -BeLessThan 1024
        ($json | ConvertFrom-Json).limits.week.resets | Should -Be 'Fr 00:00'
    }
    It 'Hauptablauf schickt die Limits aus ratelimits.json mit' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
        Mock Invoke-CcusageCommand { '{"daily":[]}' }
        $dir = Join-Path $TestDrive ('lim_' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        $cfg = Join-Path $dir 'config.json'
        '{"esp_host":"192.0.2.50","source":"ccusage"}' | Set-Content -Path $cfg
        $future = [int64]([datetime]::UtcNow.AddHours(2) - [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc')).TotalSeconds
        ('{"captured_utc":"' + [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + '","five_hour":{"used_percentage":6,"resets_at":' + $future + '}}') |
            Set-Content -Path (Join-Path $dir 'ratelimits.json')
        & $script:ScriptPath -ConfigPath $cfg -LogPath $dir
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $o = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            $o.limits.session.used_pct -eq 6 -and $o.limits.age_min -eq 0 -and $null -eq $o.limits.week }
    }
}

Describe 'Senden an den ESP' {
    It 'sendet POST mit X-Token und UTF-8-Body' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
        Send-ClaudePayload -EspHost '192.0.2.50' -Token 'geheim' -Json '{"source":"test"}'
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'Post' -and $Uri -eq 'http://192.0.2.50/claude' -and $Headers['X-Token'] -eq 'geheim' -and
            [System.Text.Encoding]::UTF8.GetString($Body) -eq '{"source":"test"}' }
    }
    It 'ohne Token wird kein X-Token-Header gesendet' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
        Send-ClaudePayload -EspHost 'nerdminer.local' -Json '{}'
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { -not $Headers.ContainsKey('X-Token') }
    }
    It 'meldet fehlendes ok=true' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $false } }
        { Send-ClaudePayload -EspHost 'x' -Json '{}' } | Should -Throw '*ok=true*'
    }
    It 'meldet nicht erreichbaren ESP verständlich' {
        Mock Invoke-RestMethod { throw 'Zeitüberschreitung' }
        { Send-ClaudePayload -EspHost 'x' -Json '{}' } | Should -Throw '*ESP erreichbar*'
    }
}

Describe 'Hauptablauf' {
    BeforeEach {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
    }
    It '-Test sendet Beispieldaten an den ESP' {
        & $script:ScriptPath -ConfigPath (New-TestConfig) -Test -LogPath $TestDrive
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'http://192.0.2.50/claude' -and [System.Text.Encoding]::UTF8.GetString($Body) -match '"source":"test"' }
    }
    It '-WhatIf fragt ab, sendet aber nichts und schreibt trotzdem ins Log' {
        $log = Join-Path $TestDrive 'whatif'
        New-Item -ItemType Directory -Path $log -Force | Out-Null
        & $script:ScriptPath -ConfigPath (New-TestConfig) -Test -LogPath $log -WhatIf
        Should -Invoke Invoke-RestMethod -Times 0
        (Get-ChildItem $log -Filter 'Log_*.log' | Get-Content -Raw) | Should -Match 'Payload'
    }
    It 'fehlender Admin-Key bricht mit Hinweis auf -SetAdminKey ab' {
        { & $script:ScriptPath -ConfigPath (New-TestConfig @{ source = 'admin_api' }) -LogPath $TestDrive } | Should -Throw '*-SetAdminKey*'
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'löscht nur alte Logdateien' {
        $dir = Join-Path $TestDrive 'logs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $old = New-Item -Path (Join-Path $dir 'Log_2020-01-01.log') -ItemType File
        $old.LastWriteTime = (Get-Date).AddDays(-30)
        New-Item -Path (Join-Path $dir 'Log_2099-01-01.log') -ItemType File | Out-Null
        New-Item -Path (Join-Path $dir 'andere.log') -ItemType File | Out-Null
        (Get-Item (Join-Path $dir 'andere.log')).LastWriteTime = (Get-Date).AddDays(-30)
        Remove-OldLog -Folder $dir -RetentionDays 14 | Should -Be 1
        Test-Path (Join-Path $dir 'Log_2020-01-01.log') | Should -BeFalse
        Test-Path (Join-Path $dir 'andere.log') | Should -BeTrue
    }
}
