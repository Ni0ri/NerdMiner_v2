BeforeAll {
    $script:ScriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'Write-ClaudeStatusLine.ps1'
    . $script:ScriptPath -LogPath $TestDrive
    $script:Full = '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":23.4},' +
                   '"rate_limits":{"five_hour":{"used_percentage":6,"resets_at":1791824400},"seven_day":{"used_percentage":42,"resets_at":1792101600}}}'
}

Describe 'Write-ClaudeStatusLine' {
    It 'gibt die Statuszeile aus und schreibt den Cache' {
        $cache = Join-Path $TestDrive 'rl1.json'
        $out = & $script:ScriptPath -InputJson $script:Full -CachePath $cache -LogPath $TestDrive
        $out | Should -Be 'Opus | Kontext 23 % | Sitzung 6 % | Woche 42 %'
        $c = Get-Content $cache -Raw | ConvertFrom-Json
        $c.five_hour.used_percentage | Should -Be 6
        $c.seven_day.resets_at | Should -Be 1792101600
        # Rohtext prüfen: pwsh 7 wandelt ISO-Zeitstempel beim Einlesen in DateTime um
        Get-Content $cache -Raw | Should -Match '"captured_utc":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
    }
    It 'ohne rate_limits bleibt ein vorhandener Cache unverändert' {
        $cache = Join-Path $TestDrive 'rl2.json'
        Set-Content -Path $cache -Value '{"captured_utc":"2026-10-12T09:00:00Z","five_hour":{"used_percentage":7,"resets_at":1}}'
        $before = Get-Content $cache -Raw
        & $script:ScriptPath -InputJson '{"model":{"display_name":"Opus"}}' -CachePath $cache -LogPath $TestDrive | Should -Be 'Opus'
        Get-Content $cache -Raw | Should -Be $before
    }
    It '-WhatIf schreibt keinen Cache' {
        $cache = Join-Path $TestDrive 'rl3.json'
        & $script:ScriptPath -InputJson $script:Full -CachePath $cache -LogPath $TestDrive -WhatIf | Out-Null
        Test-Path $cache | Should -BeFalse
    }
    It 'ungültiges JSON bricht nicht ab, sondern meldet es in der Statuszeile' {
        $cache = Join-Path $TestDrive 'rl4.json'
        { & $script:ScriptPath -InputJson '{kaputt' -CachePath $cache -LogPath $TestDrive } | Should -Not -Throw
        & $script:ScriptPath -InputJson '{kaputt' -CachePath $cache -LogPath $TestDrive | Should -Match 'Fehler'
    }
    It 'funktioniert mit Schrägstrichen im Pfad und ohne -CachePath/-LogPath (Aufruf wie durch Claude Code)' {
        # Windows PowerShell 5.1 lässt $PSScriptRoot in Parameter-Standardwerten dann leer
        $shell = (Get-Process -Id $PID).Path
        $slashPath = ([System.IO.Path]::GetFullPath($script:ScriptPath)) -replace '\\', '/'
        $out = $script:Full | & $shell -NoProfile -ExecutionPolicy Bypass -File $slashPath -WhatIf
        ($out -join "`n") | Should -Match 'Opus \| Kontext 23 % \| Sitzung 6 % \| Woche 42 %'
        ($out -join "`n") | Should -Not -Match 'Join-Path'
    }
    It 'liest das JSON auch über stdin' {
        $cache = Join-Path $TestDrive 'rl5.json'
        $shell = (Get-Process -Id $PID).Path
        $out = $script:Full | & $shell -NoProfile -File $script:ScriptPath -CachePath $cache -LogPath $TestDrive
        $out | Should -Be 'Opus | Kontext 23 % | Sitzung 6 % | Woche 42 %'
        Test-Path $cache | Should -BeTrue
    }
}
