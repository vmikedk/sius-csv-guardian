BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..\SIUS-CSV-Guardian.ps1'
    $shell = (Get-Process -Id $PID).Path
    function Run-Guardian([string]$InputPath,[string]$OutputReport,[switch]$DryRun) {
        $arguments = @('-NoProfile','-File',$scriptPath,'-Path',$InputPath,'-NoGui','-ReportPath',$OutputReport)
        if ($DryRun) { $arguments += '-DryRun' }
        $process = Start-Process -FilePath $shell -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        return $process.ExitCode
    }
}

Describe 'SIUS CSV Guardian' {
    BeforeEach { $case = Join-Path $TestDrive 'input.csv' }

    It 'preserves repeated shooter sessions and changes only field three' {
        @('PlayerNumber;Session;Flag;Score','42;A;0;100','42;B;1;99') -join "`r`n" | Set-Content $case -NoNewline
        Run-Guardian $case (Join-Path $TestDrive 'r.txt') | Should -Be 0
        (Get-Content $case -Raw) | Should -Be (@('PlayerNumber;Session;Flag;Score','42;A;False;100','42;B;True;99') -join "`r`n")
        (Get-Content $case).Count | Should -Be 3
        (Get-ChildItem "$case.backup-*").Count | Should -Be 1
    }

    It 'does not write the CSV or backup during dry run' {
        '7;S1;0;10' | Set-Content $case -NoNewline
        $before = Get-Content $case -Raw
        Run-Guardian $case (Join-Path $TestDrive 'dry.txt') -DryRun | Should -Be 0
        (Get-Content $case -Raw) | Should -Be $before
        @(Get-ChildItem "$case.backup-*" -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'handles quoted semicolons without shifting fields' {
        '7;"Session;Final";0;10' | Set-Content $case -NoNewline
        Run-Guardian $case (Join-Path $TestDrive 'q.txt') | Should -Be 0
        (Get-Content $case -Raw) | Should -Be '7;"Session;Final";False;10'
    }

    It 'is idempotent' {
        '7;S1;0;10' | Set-Content $case -NoNewline
        Run-Guardian $case (Join-Path $TestDrive 'one.txt') | Should -Be 0
        $afterFirst = Get-Content $case -Raw
        Run-Guardian $case (Join-Path $TestDrive 'two.txt') | Should -Be 0
        (Get-Content $case -Raw) | Should -Be $afterFirst
        @(Get-ChildItem "$case.backup-*").Count | Should -Be 1
    }

    It 'flags PlayerNumber zero without mutating or deleting it' {
        @('PlayerNumber;Session;Flag;Score','0;A;False;100','5;B;False;90') -join "`r`n" | Set-Content $case -NoNewline
        Run-Guardian $case (Join-Path $TestDrive 'zero.txt') | Should -Be 2
        (Get-Content $case).Count | Should -Be 3
        (Get-Content $case -Raw) | Should -Match '(?m)^0;A;False;100$' -Because 'the zero row remains intact'
        (Get-Content (Join-Path $TestDrive 'zero.txt') -Raw) | Should -Match 'PlayerNumber 0 rows: 2'
    }
}
