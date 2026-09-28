# Gedeelde hulpfuncties: logging, HTTP met herhaalpogingen, CSV schrijven/bijwerken, ruwe opslag.
# Werkt in Windows PowerShell 5.1 en PowerShell 7 (Windows, Linux, macOS).

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Utf8Bom = New-Object Text.UTF8Encoding($true)

function Initialize-Verzamelaar {
    param([hashtable]$Config, [string]$Root)
    $script:Cfg = $Config
    $script:DataDir = if ([IO.Path]::IsPathRooted($Config.DataDir)) { $Config.DataDir } else { Join-Path $Root $Config.DataDir }
    foreach ($d in @($script:DataDir, (Join-Path $script:DataDir 'ruw'), (Join-Path $script:DataDir 'status'), (Join-Path $script:DataDir 'logs'))) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    $script:RunStamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv)
    $script:Today = (Get-Date).ToString('yyyy-MM-dd', $script:Inv)
}

function Get-DataPath { param([string]$Name) Join-Path $script:DataDir $Name }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv), $Level, $Message
    Write-Host $line
    $log = Join-Path (Join-Path $script:DataDir 'logs') ((Get-Date).ToString('yyyy-MM', $script:Inv) + '.log')
    [IO.File]::AppendAllText($log, $line + [Environment]::NewLine, $script:Utf8Bom)
}

function Suspend-Beleefd { Start-Sleep -Milliseconds ([int]$script:Cfg.PauzeMs) }

# GET met herhaalpogingen (5 s, 15 s, 45 s). Geeft de body als UTF-8-string terug, of schrijft naar -OutFile.
function Invoke-Get {
    param([string]$Uri, [string]$OutFile, [int]$TimeoutSec = 300)
    $delay = 5
    for ($i = 1; $i -le 4; $i++) {
        try {
            if ($OutFile) {
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UserAgent $script:Cfg.UserAgent -UseBasicParsing -TimeoutSec $TimeoutSec
                return
            }
            $r = Invoke-WebRequest -Uri $Uri -UserAgent $script:Cfg.UserAgent -UseBasicParsing -TimeoutSec $TimeoutSec
            return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        } catch {
            if ($i -eq 4) { throw }
            Write-Log ("Poging {0} mislukt ({1}): {2}. Opnieuw over {3} s." -f $i, $Uri, $_.Exception.Message, $delay) 'WARN'
            Start-Sleep -Seconds $delay
            $delay *= 3
        }
    }
}

# Arrays worden element voor element teruggegeven (PowerShell 5.1 geeft anders één array-object door).
function Invoke-GetJson {
    param([string]$Uri, [int]$TimeoutSec = 300)
    $o = ConvertFrom-Json -InputObject (Invoke-Get -Uri $Uri -TimeoutSec $TimeoutSec)
    return $o
}

# PowerShell 7 zet ISO-datums in JSON om naar DateTime; dit maakt er weer een vaste UTC-string van.
function Format-Utc {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv) }
    return [string]$Value
}

function Format-Tijd {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-ddTHH:mm:ss', $script:Inv) }
    return [string]$Value
}

# ---------- CSV (komma-gescheiden, punt als decimaal, UTF-8 met BOM) ----------
function ConvertTo-CsvField {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { $s = $Value.ToString($script:Inv) }
    elseif ($Value -is [bool]) { $s = if ($Value) { 'true' } else { 'false' } }
    else { $s = [string]$Value }
    if ($s -match '[",\r\n]') { return '"' + $s.Replace('"', '""') + '"' }
    return $s
}

function ConvertTo-CsvLine { param([string[]]$Columns, $Row) ($Columns | ForEach-Object { ConvertTo-CsvField $Row.$_ }) -join ',' }

# Voegt rijen toe aan het eind van een CSV (schrijft de kop bij een nieuw bestand).
function Add-CsvRows {
    param([string]$Path, [string[]]$Columns, [object[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }
    $sb = New-Object Text.StringBuilder
    if (-not (Test-Path $Path)) { [void]$sb.AppendLine(($Columns | ForEach-Object { ConvertTo-CsvField $_ }) -join ',') }
    foreach ($r in $Rows) { [void]$sb.AppendLine((ConvertTo-CsvLine $Columns $r)) }
    [IO.File]::AppendAllText($Path, $sb.ToString(), $script:Utf8Bom)
}

# Werkt rijen bij op sleutel: bestaande rijen met dezelfde sleutel worden vervangen, de rest blijft staan.
function Update-CsvRows {
    param([string]$Path, [string[]]$Columns, [object[]]$Rows, [string[]]$Key)
    if (-not $Rows -or $Rows.Count -eq 0) { return }
    $newKeys = @{}
    foreach ($r in $Rows) { $newKeys[(($Key | ForEach-Object { [string]$r.$_ }) -join '|')] = $true }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine(($Columns | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
    if (Test-Path $Path) {
        foreach ($old in (Import-Csv -Path $Path)) {
            $k = ($Key | ForEach-Object { [string]$old.$_ }) -join '|'
            if (-not $newKeys.ContainsKey($k)) { [void]$sb.AppendLine((ConvertTo-CsvLine $Columns $old)) }
        }
    }
    foreach ($r in $Rows) { [void]$sb.AppendLine((ConvertTo-CsvLine $Columns $r)) }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $sb.ToString(), $script:Utf8Bom)
    Move-Item -Path $tmp -Destination $Path -Force
}

function Get-CsvColumnValues {
    param([string]$Path, [string]$Column)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path $Path) { foreach ($r in (Import-Csv -Path $Path)) { [void]$set.Add([string]$r.$Column) } }
    return , $set
}

# ---------- Status en ruwe opslag ----------
function Get-Status {
    param([string]$Name)
    $p = Join-Path (Join-Path $script:DataDir 'status') ($Name + '.json')
    if (Test-Path $p) { return (Get-Content -Raw -Path $p -Encoding UTF8 | ConvertFrom-Json) }
    return $null
}

function Set-Status {
    param([string]$Name, $Value)
    $p = Join-Path (Join-Path $script:DataDir 'status') ($Name + '.json')
    [IO.File]::WriteAllText($p, ($Value | ConvertTo-Json -Depth 6), $script:Utf8Bom)
}

function Get-RuwPad {
    param([string]$Bron, [string]$Naam)
    $dir = Join-Path (Join-Path $script:DataDir 'ruw') $Bron
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Join-Path $dir ($script:Today + '_' + $Naam)
}

function Save-Ruw {
    param([string]$Bron, [string]$Naam, [string]$Content)
    [IO.File]::WriteAllText((Get-RuwPad $Bron $Naam), $Content, (New-Object Text.UTF8Encoding($false)))
}

function Clear-OudeRuweData {
    $grens = (Get-Date).AddDays(-[int]$script:Cfg.BewaarRuwDagen)
    Get-ChildItem -Path (Join-Path $script:DataDir 'ruw') -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $grens } | Remove-Item -Force
}

# ---------- Grote JSON-arrays element voor element lezen (laag geheugengebruik) ----------
if (-not ('JsonArraySplitter' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class JsonArraySplitter {
    public static IEnumerable<string> Elements(TextReader r) {
        int c;
        while ((c = r.Read()) != -1 && c != '[') { }
        var sb = new StringBuilder();
        int depth = 0; bool inStr = false, esc = false;
        while ((c = r.Read()) != -1) {
            char ch = (char)c;
            if (depth == 0) {
                if (ch == '{' || ch == '[') { depth = 1; sb.Length = 0; sb.Append(ch); }
                else if (ch == ']') yield break;
                continue;
            }
            sb.Append(ch);
            if (inStr) {
                if (esc) esc = false; else if (ch == '\\') esc = true; else if (ch == '"') inStr = false;
                continue;
            }
            if (ch == '"') inStr = true;
            else if (ch == '{' || ch == '[') depth++;
            else if (ch == '}' || ch == ']') { depth--; if (depth == 0) yield return sb.ToString(); }
        }
    }
}
'@
}

function Get-GzipJsonElements {
    param([string]$Path)
    $fs = [IO.File]::OpenRead($Path)
    $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
    $rd = New-Object IO.StreamReader($gz, [Text.Encoding]::UTF8)
    try { foreach ($s in [JsonArraySplitter]::Elements($rd)) { $s } }
    finally { $rd.Dispose() }
}

function Get-Mediaan {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = $Values | Sort-Object
    $n = $s.Count
    if ($n % 2 -eq 1) { return [double]$s[($n - 1) / 2] }
    return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2
}
