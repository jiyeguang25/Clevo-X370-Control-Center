# pe-exports.ps1 - minimal PE export-table reader (no dumpbin needed)
# Usage: powershell -File pe-exports.ps1 <dll> [<dll>...]
[CmdletBinding()]
param([Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Path)

function Get-PEExports {
    param([string]$File)

    $bytes = [System.IO.File]::ReadAllBytes($File)

    function R16([int]$o) { [BitConverter]::ToUInt16($bytes, $o) }
    function R32([int]$o) { [BitConverter]::ToUInt32($bytes, $o) }

    $peOff = [int](R32 0x3C)
    if ((R32 $peOff) -ne 0x00004550) { throw "not a PE file" }

    $coff    = $peOff + 4
    $machine = R16 $coff
    $numSec  = R16 ($coff + 2)
    $optSize = R16 ($coff + 16)
    $opt     = $coff + 20
    $magic   = R16 $opt
    $is64    = ($magic -eq 0x20b)

    $dd      = $opt + $(if ($is64) { 112 } else { 96 })
    $expRva  = R32 $dd
    $expSize = R32 ($dd + 4)

    $secOff = $opt + $optSize
    $secs = @()
    for ($i = 0; $i -lt $numSec; $i++) {
        $s = $secOff + $i * 40
        $secs += [pscustomobject]@{
            Name    = [Text.Encoding]::ASCII.GetString($bytes, $s, 8).Trim([char]0)
            VSize   = R32 ($s + 8)
            VA      = R32 ($s + 12)
            RawSize = R32 ($s + 16)
            Raw     = R32 ($s + 20)
        }
    }

    function RvaToOff([uint32]$rva) {
        foreach ($s in $secs) {
            $span = [Math]::Max($s.VSize, $s.RawSize)
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $span)) {
                return [int]($s.Raw + ($rva - $s.VA))
            }
        }
        return -1
    }

    $info = [pscustomobject]@{
        Arch      = if ($is64) { 'x64' } else { 'x86' }
        ExportRva = $expRva
        NumNames  = 0
        Names     = @()
    }
    if ($expRva -eq 0) { return $info }

    $e        = RvaToOff $expRva
    if ($e -lt 0) { return $info }
    $nNames   = R32 ($e + 24)
    $afNames  = R32 ($e + 32)
    $namesOff = RvaToOff $afNames
    $names = @()
    for ($i = 0; $i -lt $nNames; $i++) {
        $nr = R32 ($namesOff + $i * 4)
        $no = RvaToOff $nr
        if ($no -lt 0) { continue }
        $end = $no
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        $names += [Text.Encoding]::ASCII.GetString($bytes, $no, $end - $no)
    }
    $info.NumNames = $nNames
    $info.Names = ($names | Sort-Object -Unique)
    return $info
}

foreach ($f in $Path) {
    Write-Output "===== $f ====="
    if (-not (Test-Path -LiteralPath $f)) { Write-Output '  (missing)'; continue }
    try {
        $r = Get-PEExports $f
        Write-Output ("  arch={0} exports={1} (unique={2})" -f $r.Arch, $r.NumNames, $r.Names.Count)
        foreach ($n in $r.Names) { Write-Output "    $n" }
    }
    catch { Write-Output "  ERROR: $_" }
}
