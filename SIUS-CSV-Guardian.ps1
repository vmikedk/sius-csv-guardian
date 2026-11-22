[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Path,
    [switch]$DryRun,
    [switch]$NoGui,
    [string]$ReportPath,
    # Folder for the repaired copy. Default: an "Upload" folder next to the source file.
    [string]$OutputDir,
    # Legacy behaviour: modify the source file itself (a backup is made first).
    [switch]$InPlace,
    # 1-based column holding the shooter number when the file has no PlayerNumber header.
    [ValidateRange(1,1000)]
    [int]$PlayerColumn = 1,
    # Expected number of fields per row. 0 = use the most common count in the file.
    [ValidateRange(0,1000)]
    [int]$ExpectedFields = 0,
    # Remove rows whose shooter number is 0 from the output and save them to <name>.skipped.csv.
    # Rows are never reassigned to another shooter.
    [switch]$ExcludePlayerZero
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-CsvFields {
    param([string]$Line)
    $fields = New-Object System.Collections.Generic.List[object]
    $start = 0; $inQuotes = $false; $i = 0
    while ($i -lt $Line.Length) {
        $c = $Line[$i]
        if ($c -eq '"') {
            if ($inQuotes -and ($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq '"') { $i += 2; continue }
            $inQuotes = -not $inQuotes
        } elseif ($c -eq ';' -and -not $inQuotes) {
            $fields.Add([pscustomobject]@{ Start=$start; Length=$i-$start; Raw=$Line.Substring($start,$i-$start) })
            $start = $i + 1
        }
        $i++
    }
    if ($inQuotes) { throw 'Unbalanced quote in CSV row.' }
    $fields.Add([pscustomobject]@{ Start=$start; Length=$Line.Length-$start; Raw=$Line.Substring($start) })
    # The leading comma keeps a single-field result an array instead of unrolling it.
    return ,$fields.ToArray()
}

function Get-UnquotedValue {
    param([string]$Raw)
    if ($Raw.Length -ge 2 -and $Raw[0] -eq '"' -and $Raw[$Raw.Length-1] -eq '"') {
        return $Raw.Substring(1,$Raw.Length-2).Replace('""','"')
    }
    return $Raw
}

function Replace-Field {
    param([string]$Line, $Field, [string]$Value)
    return $Line.Substring(0,$Field.Start) + $Value + $Line.Substring($Field.Start+$Field.Length)
}

# Reads a file while allowing other processes (SIUS) to keep it open, retrying if it is locked.
function Read-BytesShared {
    param([string]$FilePath, [int]$Attempts = 5, [int]$DelayMs = 1000)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $stream = New-Object IO.FileStream($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $memory = New-Object IO.MemoryStream
                $stream.CopyTo($memory)
                return ,$memory.ToArray()
            } finally { $stream.Dispose() }
        } catch {
            if ($attempt -ge $Attempts) {
                throw "Could not read '$FilePath' after $Attempts attempts. It may be locked by another process (for example SIUS Data). Close it or try again. Details: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# Decodes strictly. A file that is not valid UTF-8 (and has no BOM) is decoded as Latin-1,
# which round-trips every byte exactly, so characters such as aeo/AEO in Windows-1252 are never replaced.
function Read-TextPreservingEncoding {
    param([byte[]]$Bytes)
    $offset = 0
    $bom = [byte[]]@()
    $note = ''
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($false,$true); $bom = [byte[]](0xEF,0xBB,0xBF); $offset = 3
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $encoding = [Text.Encoding]::Unicode; $bom = [byte[]](0xFF,0xFE); $offset = 2
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $encoding = [Text.Encoding]::BigEndianUnicode; $bom = [byte[]](0xFE,0xFF); $offset = 2
    } else {
        $encoding = New-Object Text.UTF8Encoding($false,$true)
    }
    try {
        $text = $encoding.GetString($Bytes,$offset,$Bytes.Length-$offset)
    } catch {
        if ($bom.Length) { throw }
        $encoding = [Text.Encoding]::GetEncoding(28591)
        $text = $encoding.GetString($Bytes,0,$Bytes.Length)
        $note = 'The file is not valid UTF-8 and was handled byte-for-byte as a single-byte encoding (probably Windows-1252). Characters were not altered.'
    }
    return [pscustomobject]@{ Text=$text; Encoding=$encoding; Bom=$bom; Note=$note }
}

function Write-TextAtomically {
    param([string]$FilePath,[string]$Text,$Encoding,[byte[]]$Bom)
    $directory = [IO.Path]::GetDirectoryName($FilePath)
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
    $temp = [IO.Path]::Combine($directory, ('.guardian-' + [IO.Path]::GetRandomFileName() + '.tmp'))
    try {
        $body = $Encoding.GetBytes($Text)
        $all = New-Object byte[] ($Bom.Length + $body.Length)
        if ($Bom.Length) { [Array]::Copy($Bom,0,$all,0,$Bom.Length) }
        [Array]::Copy($body,0,$all,$Bom.Length,$body.Length)
        [IO.File]::WriteAllBytes($temp,$all)
        if (Test-Path -LiteralPath $FilePath) { [IO.File]::Replace($temp,$FilePath,$null) }
        else { [IO.File]::Move($temp,$FilePath) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Show-FilePicker {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select SIUS CSV file'
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    if (Test-Path 'C:\SIUS\SiusData\Data') { $dialog.InitialDirectory='C:\SIUS\SiusData\Data' }
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $null }
    return $dialog.FileName
}

if (-not $Path) {
    if ($NoGui) { throw 'Supply a CSV path when using -NoGui.' }
    $Path = Show-FilePicker
    if (-not $Path) { Write-Host 'Cancelled. No file was changed.'; exit 0 }
}
$Path = (Resolve-Path -LiteralPath $Path).Path
if ([IO.Path]::GetExtension($Path) -ne '.csv') { throw 'The selected file is not a .csv file.' }

$sourceDir = [IO.Path]::GetDirectoryName($Path)
$baseName = [IO.Path]::GetFileNameWithoutExtension($Path)
if ($InPlace) {
    $outputPath = $Path
    $outputFolder = $sourceDir
} else {
    if (-not $OutputDir) { $OutputDir = Join-Path $sourceDir 'Upload' }
    $outputFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
    if ($outputFolder.TrimEnd('\','/') -ieq $sourceDir.TrimEnd('\','/')) {
        throw 'OutputDir must be a different folder than the source file. Use -InPlace to modify the original.'
    }
    $outputPath = Join-Path $outputFolder ([IO.Path]::GetFileName($Path))
}
$skippedPath = Join-Path $outputFolder "$baseName.skipped.csv"

$source = Read-TextPreservingEncoding (Read-BytesShared $Path)
$newline = if ($source.Text.Contains("`r`n")) { "`r`n" } elseif ($source.Text.Contains("`n")) { "`n" } else { [Environment]::NewLine }
$hadFinalNewline = $source.Text.EndsWith("`n") -or $source.Text.EndsWith("`r")
$lines = @($source.Text -split "`r`n|`n|`r")
if ($hadFinalNewline -and $lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count-2)]) }

$warnings = New-Object System.Collections.Generic.List[string]
$issues = New-Object System.Collections.Generic.List[string]
$invalidRows = New-Object System.Collections.Generic.List[int]
$badValueRows = New-Object System.Collections.Generic.List[int]
$playerZeroRows = New-Object System.Collections.Generic.List[int]
$outLines = New-Object System.Collections.Generic.List[string]
$skippedLines = New-Object System.Collections.Generic.List[string]
$changed = 0; $inspected = 0
if ($source.Note) { $warnings.Add($source.Note) }

# Pass 1: parse every row once.
$parsed = New-Object object[] $lines.Count
$parseErrors = @{}
$firstRow = -1
for ($row=0; $row -lt $lines.Count; $row++) {
    if ([string]::IsNullOrWhiteSpace($lines[$row])) { continue }
    if ($firstRow -lt 0) { $firstRow = $row }
    try { $parsed[$row] = Get-CsvFields $lines[$row] } catch { $parseErrors[$row] = $_.Exception.Message }
}

# Header detection: a PlayerNumber header names the column; otherwise a non-numeric
# shooter field in the first row means that row is a header and -PlayerColumn is used.
$playerIndex = $PlayerColumn - 1
$headerRow = -1
if ($firstRow -ge 0 -and $null -ne $parsed[$firstRow]) {
    $first = $parsed[$firstRow]
    $named = -1
    for ($i=0; $i -lt $first.Count; $i++) {
        if ((Get-UnquotedValue $first[$i].Raw).Trim() -ieq 'PlayerNumber') { $named = $i; break }
    }
    if ($named -ge 0) {
        $playerIndex = $named; $headerRow = $firstRow
    } elseif ($first.Count -gt $playerIndex -and (Get-UnquotedValue $first[$playerIndex].Raw).Trim() -notmatch '^\d+$') {
        $headerRow = $firstRow
    }
}
if ($headerRow -ge 0) { $warnings.Add("Row $($headerRow+1) was treated as a header and left unchanged.") }

# Expected field count: explicit, otherwise the most common count among data rows.
$counts = @{}
for ($row=0; $row -lt $lines.Count; $row++) {
    if ($row -eq $headerRow -or $null -eq $parsed[$row]) { continue }
    $n = $parsed[$row].Count
    if ($counts.ContainsKey($n)) { $counts[$n] = $counts[$n] + 1 } else { $counts[$n] = 1 }
}
$expected = $ExpectedFields
if ($expected -le 0 -and $counts.Count -gt 0) {
    $expected = [int](($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key)
}

# Pass 2: repair, validate, and optionally set aside shooter-0 rows.
for ($row=0; $row -lt $lines.Count; $row++) {
    $original = $lines[$row]
    $number = $row + 1
    if ([string]::IsNullOrWhiteSpace($original)) { $outLines.Add($original); continue }
    $inspected++
    if ($parseErrors.ContainsKey($row)) {
        $invalidRows.Add($number); $issues.Add("row ${number}: $($parseErrors[$row])")
        $outLines.Add($original); continue
    }
    if ($row -eq $headerRow) { $outLines.Add($original); continue }

    $fields = $parsed[$row]
    if ($fields.Count -lt 3) {
        $invalidRows.Add($number); $issues.Add("row ${number}: only $($fields.Count) field(s), field 3 is missing")
        $outLines.Add($original); continue
    }
    if ($expected -gt 0 -and $fields.Count -ne $expected) {
        $invalidRows.Add($number); $issues.Add("row ${number}: $($fields.Count) fields, expected $expected")
    }

    $line = $original
    $converted = $false
    $third = (Get-UnquotedValue $fields[2].Raw).Trim()
    if ($third -ceq '0' -or $third -ceq '1') {
        $replacement = if ($third -eq '0') { 'False' } else { 'True' }
        if ($fields[2].Raw.StartsWith('"')) { $replacement = '"' + $replacement + '"' }
        $line = Replace-Field $line $fields[2] $replacement
        $converted = $true
    } elseif ($third -ine 'true' -and $third -ine 'false') {
        $badValueRows.Add($number); $issues.Add("row ${number} field 3: unexpected value '$third' (expected 0, 1, True or False)")
    }

    if ($fields.Count -gt $playerIndex -and (Get-UnquotedValue $fields[$playerIndex].Raw).Trim() -match '^0+$') {
        $playerZeroRows.Add($number)
        if ($ExcludePlayerZero) { $skippedLines.Add($original); continue }
    }

    $outLines.Add($line)
    if ($converted) { $changed++ }
}

if ($playerZeroRows.Count) {
    if ($ExcludePlayerZero) {
        $warnings.Add("Shooter number 0 (field $($playerIndex+1)) was found in $($playerZeroRows.Count) row(s). They were removed from the output and saved to '$skippedPath'. They were NOT reassigned to any shooter; check them manually.")
    } else {
        $warnings.Add("Shooter number 0 (field $($playerIndex+1)) was found. These rows remain in the output and DGI is likely to answer HTTP 500. Re-run with -ExcludePlayerZero to set them aside. They are never reassigned to another shooter.")
    }
}
if ($invalidRows.Count) { $warnings.Add('Some rows could not be safely parsed or have an unexpected field count and were left unchanged.') }
if ($badValueRows.Count) { $warnings.Add('Some rows have a third field that SPConnector cannot parse as Boolean. They were left unchanged.') }

$resultText = [string]::Join($newline,$outLines.ToArray()) + $(if ($hadFinalNewline) { $newline } else { '' })
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backup = "$Path.backup-$stamp"
if (-not $ReportPath) {
    $reportDir = if ($InPlace -or $DryRun) { $sourceDir } else { $outputFolder }
    $ReportPath = Join-Path $reportDir "$baseName.report-$stamp.txt"
}
$mode = if ($DryRun) { 'DRY RUN - nothing written except this report' } elseif ($InPlace) { 'REPAIR IN PLACE' } else { 'REPAIR TO COPY' }
$headerText = if ($headerRow -ge 0) { "row $($headerRow+1)" } else { 'none' }
$report = New-Object System.Collections.Generic.List[string]
$report.AddRange([string[]]@(
    'SIUS CSV Guardian report', "Mode: $mode", "Source file: $Path",
    "Output file: $(if ($DryRun) { '(dry run)' } else { $outputPath })",
    "Rows inspected: $inspected", "Header row: $headerText",
    "Shooter number field: $($playerIndex+1)", "Expected fields per row: $(if ($expected -gt 0) { $expected } else { 'unknown' })",
    "Third-field Boolean replacements: $changed",
    "Shooter number 0 rows: $(if($playerZeroRows.Count){$playerZeroRows -join ', '}else{'none detected'})",
    "Shooter number 0 rows excluded: $(if ($ExcludePlayerZero) { $skippedLines.Count } else { 'no (-ExcludePlayerZero not used)' })",
    "Unparseable, short or wrong-length rows: $(if($invalidRows.Count){$invalidRows -join ', '}else{'none'})",
    "Rows with unexpected third-field value: $(if($badValueRows.Count){$badValueRows -join ', '}else{'none'})",
    'Session handling: no rows were merged, deduplicated, reordered, or assigned to another shooter.',
    "Warnings: $(if($warnings.Count){$warnings -join ' | '}else{'none'})"
))
if ($issues.Count) { $report.Add('Details:'); foreach ($item in $issues) { $report.Add("  - $item") } }

if (-not $DryRun) {
    if ($InPlace) {
        if ($changed -gt 0 -or $skippedLines.Count -gt 0) {
            Copy-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop
            Write-TextAtomically $Path $resultText $source.Encoding $source.Bom
            $report.Add("Backup: $backup")
        } else { $report.Add('Backup: not created because the CSV required no changes.') }
    } else {
        Write-TextAtomically $outputPath $resultText $source.Encoding $source.Bom
        $report.Add('Source file: left untouched.')
    }
    if ($skippedLines.Count) {
        $skippedText = [string]::Join($newline,$skippedLines.ToArray()) + $newline
        Write-TextAtomically $skippedPath $skippedText $source.Encoding $source.Bom
        $report.Add("Excluded rows saved to: $skippedPath")
    }
}
$reportFolder = [IO.Path]::GetDirectoryName($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath))
if (-not (Test-Path -LiteralPath $reportFolder)) { [void](New-Item -ItemType Directory -Path $reportFolder) }
[IO.File]::WriteAllLines($ReportPath,$report.ToArray(),(New-Object Text.UTF8Encoding($true)))
$report | ForEach-Object { Write-Host $_ }
Write-Host "Report: $ReportPath"

if (-not $NoGui) {
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($warnings.Count) { [Windows.Forms.MessageBoxIcon]::Warning } else { [Windows.Forms.MessageBoxIcon]::Information }
    [void][Windows.Forms.MessageBox]::Show(($report -join [Environment]::NewLine),'SIUS CSV Guardian',[Windows.Forms.MessageBoxButtons]::OK,$icon)
}
$unresolved = ($invalidRows.Count -gt 0) -or ($badValueRows.Count -gt 0) -or (($playerZeroRows.Count -gt 0) -and -not $ExcludePlayerZero)
if ($unresolved) { exit 2 }
