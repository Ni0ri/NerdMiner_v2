BeforeAll {
    $script:ScriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'Install-Task.ps1'
    . $script:ScriptPath -LogPath $TestDrive
}

Describe 'Install-Task Hilfsfunktionen' {
    It 'Aufgabe startet PowerShell ausgeblendet ohne Profil' {
        $a = Get-TaskArgument -ScriptPath 'C:\Tools\ClaudeMinerBridge\ClaudeMinerBridge.ps1'
        $a | Should -Match '-WindowStyle Hidden'
        $a | Should -Match '-NoProfile'
        $a | Should -Match '-File "C:\\Tools\\ClaudeMinerBridge\\ClaudeMinerBridge\.ps1"$'
    }
    It 'Aufgabe startet ohne sichtbares Fenster über conhost --headless' {
        $c = Get-TaskCommand -ScriptPath 'C:\Tools\ClaudeMinerBridge\ClaudeMinerBridge.ps1'
        $c.Execute | Should -Be 'conhost.exe'
        $c.Argument | Should -Be ('--headless powershell.exe ' + (Get-TaskArgument -ScriptPath 'C:\Tools\ClaudeMinerBridge\ClaudeMinerBridge.ps1'))
        (Get-TaskCommand -ScriptPath 'C:\x.ps1' -NoHeadless).Execute | Should -Be 'powershell.exe'
    }
    It 'bestehende config.json wird nicht überschrieben' {
        $plan = @(Get-InstallPlan -SourceFolder 'a' -TargetFolder 'b' -ConfigExists $true)
        @($plan | Where-Object { $_.Target -match '[\\/]config\.json$' }).Count | Should -Be 0
    }
    It 'neue Installation legt config.json aus der Vorlage an' {
        $plan = @(Get-InstallPlan -SourceFolder 'a' -TargetFolder 'b' -ConfigExists $false)
        $cfg = $plan | Where-Object { $_.Target -match '[\\/]config\.json$' }
        $cfg.Source | Should -Match 'config\.example\.json$'
    }
}

Describe 'Install-Task Statuszeile' {
    It 'ergänzt die Statuszeile und lässt andere Einstellungen stehen' {
        $cmd = Get-StatusLineCommand -ScriptPath 'C:\Tools\ClaudeMinerBridge\Write-ClaudeStatusLine.ps1'
        $cmd | Should -Be 'powershell -NoProfile -ExecutionPolicy Bypass -File C:/Tools/ClaudeMinerBridge/Write-ClaudeStatusLine.ps1 -CachePath C:/Tools/ClaudeMinerBridge/ratelimits.json -LogPath C:/Tools/ClaudeMinerBridge'
        $r = Get-StatusLineChange -Settings ([pscustomobject]@{ model = 'opus'; permissions = [pscustomobject]@{ allow = @('Bash(ls)') } }) -Command $cmd
        $r.Action | Should -Be 'add'
        $r.Settings.model | Should -Be 'opus'
        $r.Settings.permissions.allow | Should -Be @('Bash(ls)')
        $r.Settings.statusLine.type | Should -Be 'command'
    }
    It 'überschreibt keine fremde Statuszeile' {
        $r = Get-StatusLineChange -Settings ([pscustomobject]@{ statusLine = [pscustomobject]@{ type = 'command'; command = 'mein.sh' } }) -Command 'x'
        $r.Action | Should -Be 'conflict'
        $r.Current | Should -Be 'mein.sh'
    }
    It 'aktualisiert einen eigenen älteren Eintrag, andere Felder bleiben' {
        $old = [pscustomobject]@{ theme = 'dark'; statusLine = [pscustomobject]@{ type = 'command'; command = 'powershell -NoProfile -File C:/Tools/ClaudeMinerBridge/Write-ClaudeStatusLine.ps1' } }
        $r = Get-StatusLineChange -Settings $old -Command 'neu'
        $r.Action | Should -Be 'update'
        $r.Settings.statusLine.command | Should -Be 'neu'
        $r.Settings.statusLine.type | Should -Be 'command'
        $r.Settings.theme | Should -Be 'dark'
    }
    It 'ohne settings.json wird eine neue angelegt' {
        (Get-StatusLineChange -Settings $null -Command 'x').Action | Should -Be 'add'
    }
    It 'Installationsplan enthält das Statuszeilen-Skript' {
        @(Get-InstallPlan -SourceFolder 'a' -TargetFolder 'b' -ConfigExists $true).Target -match 'Write-ClaudeStatusLine\.ps1$' | Should -Not -BeNullOrEmpty
    }
}

Describe 'Install-Task Ablauf (nur Windows)' -Skip:(-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    It '-WhatIf ändert nichts' {
        $target = Join-Path $TestDrive 'ziel'
        Mock Register-ScheduledTask {}
        Mock Copy-Item {}
        & $script:ScriptPath -InstallPath $target -TaskName 'ClaudeMinerBridgePesterTest' -LogPath $TestDrive -WhatIf
        Should -Invoke Register-ScheduledTask -Times 0
        Should -Invoke Copy-Item -Times 0
        Test-Path $target | Should -BeFalse
    }
    It '-ConfigureStatusLine schreibt settings.json ohne BOM und mit Sicherung' {
        $target = Join-Path $TestDrive 'ziel2'
        $settings = Join-Path $TestDrive 'claude\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $settings) -Force | Out-Null
        [System.IO.File]::WriteAllText($settings, '{"model":"opus"}')
        Mock Register-ScheduledTask {}
        & $script:ScriptPath -InstallPath $target -TaskName 'ClaudeMinerBridgePesterTest' -LogPath $TestDrive -ConfigureStatusLine -ClaudeSettingsPath $settings
        $bytes = [System.IO.File]::ReadAllBytes($settings)
        $bytes[0] | Should -Be ([byte][char]'{')
        $s = Get-Content $settings -Raw | ConvertFrom-Json
        $s.model | Should -Be 'opus'
        $s.statusLine.command | Should -Match 'Write-ClaudeStatusLine\.ps1$'
        @(Get-ChildItem (Split-Path $settings) -Filter 'settings.json.bak-*').Count | Should -Be 1
    }
}
