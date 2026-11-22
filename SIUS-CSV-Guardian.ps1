[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0)]
    [string]$Path,
    [switch]$DryRun,
    [switch]$NoGui,
    [string]$ReportPath
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
    return $fields.ToArray()
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

function Read-TextPreservingEncoding {
    param([string]$FilePath)
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    $encoding = New-Object Text.UTF8Encoding($false)
    $bom = [byte[]]@()
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($true); $bom = [byte[]](0xEF,0xBB,0xBF); $offset=3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.Encoding]::Unicode; $bom = [byte[]](0xFF,0xFE); $offset=2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.Encoding]::BigEndianUnicode; $bom = [byte[]](0xFE,0xFF); $offset=2
    } else { $offset=0 }
    $text = $encoding.GetString($bytes,$offset,$bytes.Length-$offset)
    return [pscustomobject]@{ Text=$text; Encoding=$encoding; Bom=$bom }
}

function Write-TextAtomically {
    param([string]$FilePath,[string]$Text,$Encoding,[byte[]]$Bom)
    $directory = [IO.Path]::GetDirectoryName($FilePath)
    $temp = [IO.Path]::Combine($directory,([IO.Path]::GetRandomFileName()))
    try {
        $body = $Encoding.GetBytes($Text)
        $all = New-Object byte[] ($Bom.Length + $body.Length)
        if ($Bom.Length) { [Array]::Copy($Bom,0,$all,0,$Bom.Length) }
        [Array]::Copy($body,0,$all,$Bom.Length,$body.Length)
        [IO.File]::WriteAllBytes($temp,$all)
        [IO.File]::Replace($temp,$FilePath,$null)
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

$source = Read-TextPreservingEncoding $Path
$newline = if ($source.Text.Contains("`r`n")) { "`r`n" } elseif ($source.Text.Contains("`n")) { "`n" } else { [Environment]::NewLine }
$hadFinalNewline = $source.Text.EndsWith("`n") -or $source.Text.EndsWith("`r")
$lines = @($source.Text -split "`r`n|`n|`r")
if ($hadFinalNewline -and $lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count-2)]) }

$changed = 0; $invalidRows = New-Object System.Collections.Generic.List[int]
$playerZeroRows = New-Object System.Collections.Generic.List[int]
$warnings = New-Object System.Collections.Generic.List[string]
$playerIndex = -1

if ($lines.Count -gt 0) {
    try {
        $first = Get-CsvFields $lines[0]
        for ($i=0; $i -lt $first.Count; $i++) {
            if ((Get-UnquotedValue $first[$i].Raw).Trim() -ieq 'PlayerNumber') { $playerIndex=$i; break }
        }
    } catch { $warnings.Add("Row 1 could not be parsed: $($_.Exception.Message)") }
}

for ($row=0; $row -lt $lines.Count; $row++) {
    if ([string]::IsNullOrWhiteSpace($lines[$row])) { continue }
    try { $fields = Get-CsvFields $lines[$row] } catch { $invalidRows.Add($row+1); continue }
    if ($fields.Count -lt 3) { $invalidRows.Add($row+1); continue }
    $third = Get-UnquotedValue $fields[2].Raw
    if ($third -ceq '0' -or $third -ceq '1') {
        $replacement = if ($third -eq '0') { 'False' } else { 'True' }
        if ($fields[2].Raw.StartsWith('"')) { $replacement='"'+$replacement+'"' }
        $lines[$row] = Replace-Field $lines[$row] $fields[2] $replacement
        $changed++
        $fields = Get-CsvFields $lines[$row]
    }
    if ($playerIndex -ge 0 -and $fields.Count -gt $playerIndex) {
        if ((Get-UnquotedValue $fields[$playerIndex].Raw).Trim() -eq '0') { $playerZeroRows.Add($row+1) }
    }
}

if ($playerIndex -lt 0) { $warnings.Add('No PlayerNumber header was found. PlayerNumber 0 records could not be identified safely and were not changed.') }
if ($playerZeroRows.Count) { $warnings.Add('PlayerNumber 0 was found. These rows were NOT changed or removed because the correct mapping is unknown.') }
if ($invalidRows.Count) { $warnings.Add('Some rows could not be safely parsed and were left unchanged.') }

$resultText = [string]::Join($newline,$lines) + $(if ($hadFinalNewline) { $newline } else { '' })
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backup = "$Path.backup-$stamp"
if (-not $ReportPath) { $ReportPath = "$Path.report-$stamp.txt" }
$mode = if ($DryRun) { 'DRY RUN - no CSV changes written' } else { 'REPAIR' }
$report = @(
    'SIUS CSV Guardian report', "Mode: $mode", "File: $Path", "Rows inspected: $($lines.Count)",
    "Third-field Boolean replacements: $changed", "PlayerNumber 0 rows: $(if($playerZeroRows.Count){$playerZeroRows -join ', '}else{'none detected'})",
    "Unparseable/short rows: $(if($invalidRows.Count){$invalidRows -join ', '}else{'none'})",
    'Session handling: no rows were merged, deduplicated, reordered, or dropped.',
    "Warnings: $(if($warnings.Count){$warnings -join ' | '}else{'none'})"
)

if (-not $DryRun -and $changed -gt 0) {
    Copy-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop
    try { Write-TextAtomically $Path $resultText $source.Encoding $source.Bom }
    catch { Copy-Item -LiteralPath $backup -Destination $Path -Force; throw }
    $report += "Backup: $backup"
} elseif (-not $DryRun) { $report += 'Backup: not created because the CSV required no confirmed changes.' }
[IO.File]::WriteAllLines($ReportPath,$report,(New-Object Text.UTF8Encoding($true)))
$report | ForEach-Object { Write-Host $_ }
Write-Host "Report: $ReportPath"

if (-not $NoGui) {
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($warnings.Count) { [Windows.Forms.MessageBoxIcon]::Warning } else { [Windows.Forms.MessageBoxIcon]::Information }
    [void][Windows.Forms.MessageBox]::Show(($report -join [Environment]::NewLine),'SIUS CSV Guardian',[Windows.Forms.MessageBoxButtons]::OK,$icon)
}
if ($invalidRows.Count -or $playerZeroRows.Count) { exit 2 }
