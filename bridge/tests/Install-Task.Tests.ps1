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
}
