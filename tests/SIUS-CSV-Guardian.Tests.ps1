BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..\SIUS-CSV-Guardian.ps1'
    $shell = (Get-Process -Id $PID).Path
    $utf8 = New-Object Text.UTF8Encoding($false)

    function Run-Guardian([string]$InputPath, [string]$OutputReport, [string[]]$Extra = @()) {
        $arguments = @('-NoProfile','-File',('"{0}"' -f $scriptPath),'-Path',('"{0}"' -f $InputPath),'-NoGui','-ReportPath',('"{0}"' -f $OutputReport)) + $Extra
        $process = Start-Process -FilePath $shell -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        return $process.ExitCode
    }
    function Write-Csv([string]$FilePath, [string[]]$Rows, [string]$Eol = "`r`n") {
        [IO.File]::WriteAllText($FilePath, ($Rows -join $Eol), $utf8)
    }
    function Read-Csv([string]$FilePath) { [IO.File]::ReadAllText($FilePath, $utf8) }
    function New-Row([string]$Shooter, [string]$Flag, [int]$Fields = 28) {
        $values = @($Shooter, 'S', $Flag) + (@(1..($Fields - 3)) | ForEach-Object { "$_" })
        return ($values -join ';')
    }
}

Describe 'SIUS CSV Guardian' {
    BeforeEach {
        $case = Join-Path $TestDrive 'input.csv'
        $upload = Join-Path $TestDrive 'Upload'
    }

    Context 'default mode (repaired copy)' {
        It 'writes a repaired copy and leaves the source untouched' {
            $rows = @((New-Row '5' '0'), (New-Row '5' '1'))
            Write-Csv $case $rows
            Run-Guardian $case (Join-Path $TestDrive 'r.txt') | Should -Be 0
            Read-Csv $case | Should -Be ($rows -join "`r`n")
            $out = Read-Csv (Join-Path $upload 'input.csv')
            $out | Should -Match ';False;'
            $out | Should -Match ';True;'
            @(Get-ChildItem "$case.backup-*" -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It 'writes nothing but the report during dry run' {
            Write-Csv $case @((New-Row '7' '0'))
            Run-Guardian $case (Join-Path $TestDrive 'dry.txt') @('-DryRun') | Should -Be 0
            Test-Path $upload | Should -BeFalse
            Test-Path (Join-Path $TestDrive 'dry.txt') | Should -BeTrue
        }

        It 'refuses an output folder equal to the source folder' {
            Write-Csv $case @((New-Row '7' '0'))
            Run-Guardian $case (Join-Path $TestDrive 'x.txt') @('-OutputDir', ('"{0}"' -f $TestDrive)) | Should -Not -Be 0
        }
    }

    Context '-InPlace' {
        It 'preserves repeated shooter sessions and changes only field three' {
            @('PlayerNumber;Session;Flag;Score','42;A;0;100','42;B;1;99') -join "`r`n" | Set-Content $case -NoNewline
            Run-Guardian $case (Join-Path $TestDrive 'r.txt') @('-InPlace') | Should -Be 0
            (Get-Content $case -Raw) | Should -Be (@('PlayerNumber;Session;Flag;Score','42;A;False;100','42;B;True;99') -join "`r`n")
            (Get-ChildItem "$case.backup-*").Count | Should -Be 1
        }

        It 'is idempotent' {
            '7;S1;0;10' | Set-Content $case -NoNewline
            Run-Guardian $case (Join-Path $TestDrive 'one.txt') @('-InPlace') | Should -Be 0
            $afterFirst = Get-Content $case -Raw
            Run-Guardian $case (Join-Path $TestDrive 'two.txt') @('-InPlace') | Should -Be 0
            (Get-Content $case -Raw) | Should -Be $afterFirst
            @(Get-ChildItem "$case.backup-*").Count | Should -Be 1
        }
    }

    It 'handles quoted semicolons without shifting fields' {
        Write-Csv $case @('7;"Session;Final";0;10')
        Run-Guardian $case (Join-Path $TestDrive 'q.txt') | Should -Be 0
        Read-Csv (Join-Path $upload 'input.csv') | Should -Be '7;"Session;Final";False;10'
    }

    Context 'shooter number 0' {
        It 'detects it by position when the file has no header, and keeps the rows by default' {
            $rows = @((New-Row '0' '1'), (New-Row '147101' '1'))
            Write-Csv $case $rows
            Run-Guardian $case (Join-Path $TestDrive 'z.txt') | Should -Be 2
            (Read-Csv (Join-Path $upload 'input.csv')) -split "`r`n" | Should -HaveCount 2
            Read-Csv (Join-Path $TestDrive 'z.txt') | Should -Match 'Shooter number 0 rows: 1'
        }

        It 'detects it through a PlayerNumber header' {
            @('PlayerNumber;Session;Flag;Score','0;A;False;100','5;B;False;90') -join "`r`n" | Set-Content $case -NoNewline
            Run-Guardian $case (Join-Path $TestDrive 'h.txt') | Should -Be 2
            Read-Csv (Join-Path $TestDrive 'h.txt') | Should -Match 'Shooter number 0 rows: 2'
        }

        It 'removes the rows into a skipped file with -ExcludePlayerZero and never reassigns them' {
            $zero = @(1..10 | ForEach-Object { New-Row '0' '1' })
            $real = @(1..21 | ForEach-Object { New-Row '147101' '1' })
            Write-Csv $case ($zero + $real)
            Run-Guardian $case (Join-Path $TestDrive 'e.txt') @('-ExcludePlayerZero') | Should -Be 0
            $out = (Read-Csv (Join-Path $upload 'input.csv')) -split "`r`n"
            $out | Should -HaveCount 21
            ($out | Where-Object { $_ -notmatch '^147101;' }) | Should -BeNullOrEmpty
            ($out | ForEach-Object { ($_ -split ';').Count } | Select-Object -Unique) | Should -Be 28
            $skipped = (Read-Csv (Join-Path $upload 'input.skipped.csv')) -split "`r`n" | Where-Object { $_ -ne '' }
            $skipped | Should -HaveCount 10
            ($skipped | Where-Object { $_ -notmatch '^0;' }) | Should -BeNullOrEmpty
        }
    }

    Context 'validation' {
        It 'flags a third field that is not 0/1/True/False' {
            Write-Csv $case @((New-Row '5' '1'), (New-Row '5' 'X'))
            Run-Guardian $case (Join-Path $TestDrive 'v.txt') | Should -Be 2
            Read-Csv (Join-Path $TestDrive 'v.txt') | Should -Match "row 2 field 3: unexpected value 'X'"
        }

        It 'flags rows whose field count differs from the rest' {
            Write-Csv $case @((New-Row '5' '1'), (New-Row '5' '1'), (New-Row '5' '1' 20))
            Run-Guardian $case (Join-Path $TestDrive 'f.txt') | Should -Be 2
            Read-Csv (Join-Path $TestDrive 'f.txt') | Should -Match 'row 3: 20 fields, expected 28'
        }
    }

    Context 'file handling' {
        It 'keeps non-UTF-8 bytes (Windows-1252) exactly as they were' {
            $bytes = [Text.Encoding]::GetEncoding(28591).GetBytes("5;Bj" + [char]0xF8 + "rn " + [char]0xC6 + ";1;10")
            [IO.File]::WriteAllBytes($case, $bytes)
            Run-Guardian $case (Join-Path $TestDrive 'enc.txt') | Should -Be 0
            $expected = [Text.Encoding]::GetEncoding(28591).GetBytes("5;Bj" + [char]0xF8 + "rn " + [char]0xC6 + ";True;10")
            [IO.File]::ReadAllBytes((Join-Path $upload 'input.csv')) | Should -Be $expected
        }

        It 'preserves a UTF-8 BOM and LF line endings' {
            $body = $utf8.GetBytes("5;A;0;1`n5;B;1;2`n")
            [IO.File]::WriteAllBytes($case, ([byte[]](0xEF,0xBB,0xBF) + $body))
            Run-Guardian $case (Join-Path $TestDrive 'bom.txt') | Should -Be 0
            $out = [IO.File]::ReadAllBytes((Join-Path $upload 'input.csv'))
            $out[0..2] | Should -Be @(0xEF,0xBB,0xBF)
            $utf8.GetString($out, 3, $out.Length - 3) | Should -Be "5;A;False;1`n5;B;True;2`n"
        }

        It 'reads a file that another process still has open for writing' {
            $stream = New-Object IO.FileStream($case, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            try {
                $data = $utf8.GetBytes((New-Row '5' '1'))
                $stream.Write($data, 0, $data.Length); $stream.Flush()
                Run-Guardian $case (Join-Path $TestDrive 'lock.txt') | Should -Be 0
            } finally { $stream.Dispose() }
            Read-Csv (Join-Path $upload 'input.csv') | Should -Match ';True;'
        }
    }
}
