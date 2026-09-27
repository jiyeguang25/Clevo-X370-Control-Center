# diag-ildump.ps1 - strict IL disassembler: prints every opcode in real order with its
# operand, so byte-layout recipes (which index gets which value) are unambiguous.
#
# Why a second tool when dotnet-il.ps1 exists: dotnet-il.ps1 prints a *summary* trace and
# silently drops opcodes it does not model (ldloc/ldarg/brfalse...), so "ldc.i4.s 24",
# "ldc.i4.0", "stelem.i1" could be either `buf[0]=24` or `buf[24]=0`. That difference
# decides whether a DCHU write lands or silently does nothing, so this tool prints the
# raw byte offsets and operands instead of a compressed trace.
#
# Usage: powershell -File diag-ildump.ps1 <assembly> -TypeFilter <regex> [-MethodFilter <regex>]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$TypeFilter = '.',
    [string]$MethodFilter = '.'
)

$script:OpMap = @{}
foreach ($f in [Reflection.Emit.OpCodes].GetFields([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static)) {
    $op = $f.GetValue($null)
    $script:OpMap[[int]$op.Value -band 0xFFFF] = $op
}

function Get-SByte([int]$b) { if ($b -gt 127) { $b - 256 } else { $b } }

function Read-Operand($op, [byte[]]$il, [int]$pos, $mod) {
    $t = $op.OperandType.ToString()
    switch ($t) {
        'InlineNone' { return @{ Size = 0; Text = '' } }
        'ShortInlineI' {
            $raw = [int]$il[$pos]
            return @{ Size = 1; Text = ('{0}{1}' -f $raw, $(if ($raw -gt 127) { ' (sbyte ' + (Get-SByte $raw) + ')' } else { '' })) }
        }
        'ShortInlineVar' { return @{ Size = 1; Text = ('V{0}' -f $il[$pos]) } }
        'InlineVar' { return @{ Size = 2; Text = ('V{0}' -f [BitConverter]::ToUInt16($il, $pos)) } }
        'InlineI' { return @{ Size = 4; Text = [string][BitConverter]::ToInt32($il, $pos) } }
        'InlineI8' { return @{ Size = 8; Text = [string][BitConverter]::ToInt64($il, $pos) } }
        'ShortInlineR' { return @{ Size = 4; Text = [string][BitConverter]::ToSingle($il, $pos) } }
        'InlineR' { return @{ Size = 8; Text = [string][BitConverter]::ToDouble($il, $pos) } }
        'ShortInlineBrTarget' {
            $d = Get-SByte ([int]$il[$pos])
            return @{ Size = 1; Text = ('IL_{0:X4}' -f ($pos + 1 + $d)) }
        }
        'InlineBrTarget' {
            $d = [BitConverter]::ToInt32($il, $pos)
            return @{ Size = 4; Text = ('IL_{0:X4}' -f ($pos + 4 + $d)) }
        }
        'InlineSwitch' {
            $n = [BitConverter]::ToInt32($il, $pos)
            $tg = @()
            for ($k = 0; $k -lt $n; $k++) { $tg += ('IL_{0:X4}' -f ($pos + 4 + 4 * $n + [BitConverter]::ToInt32($il, $pos + 4 + 4 * $k))) }
            return @{ Size = 4 + 4 * $n; Text = ($tg -join ',') }
        }
        'InlineString' {
            try { return @{ Size = 4; Text = '"' + $mod.ResolveString([BitConverter]::ToInt32($il, $pos)) + '"' } }
            catch { return @{ Size = 4; Text = '<str?>' } }
        }
        'InlineMethod' {
            try {
                $m = $mod.ResolveMethod([BitConverter]::ToInt32($il, $pos))
                return @{ Size = 4; Text = ($m.DeclaringType.Name + '.' + $m.Name) }
            }
            catch { return @{ Size = 4; Text = '<method?>' } }
        }
        'InlineField' {
            try {
                $f = $mod.ResolveField([BitConverter]::ToInt32($il, $pos))
                return @{ Size = 4; Text = ($f.DeclaringType.Name + '.' + $f.Name) }
            }
            catch { return @{ Size = 4; Text = '<field?>' } }
        }
        'InlineType' {
            try { return @{ Size = 4; Text = $mod.ResolveType([BitConverter]::ToInt32($il, $pos)).Name } }
            catch { return @{ Size = 4; Text = '<type?>' } }
        }
        'InlineTok' {
            try {
                $mb = $mod.ResolveMember([BitConverter]::ToInt32($il, $pos))
                return @{ Size = 4; Text = ($mb.DeclaringType.Name + '.' + $mb.Name) }
            }
            catch { return @{ Size = 4; Text = '<tok?>' } }
        }
        default { return @{ Size = 4; Text = ('<' + $t + '>') } }
    }
}

$asm = [Reflection.Assembly]::LoadFile((Resolve-Path -LiteralPath $Path).Path)
$types = @()
try { $types = $asm.GetTypes() }
catch [Reflection.ReflectionTypeLoadException] { $types = $_.Exception.Types | Where-Object { $_ } }

$flags = [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic -bor `
         [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance -bor `
         [Reflection.BindingFlags]::DeclaredOnly

foreach ($t in ($types | Sort-Object FullName)) {
    if (-not $t.FullName -or $t.FullName -notmatch $TypeFilter) { continue }
    $ms = @()
    try { $ms = $t.GetMethods($flags) } catch { continue }
    foreach ($m in $ms) {
        if ($m.Name -notmatch $MethodFilter) { continue }
        $body = $null
        try { $body = $m.GetMethodBody() } catch { continue }
        if ($null -eq $body) { continue }
        $il = $body.GetILAsByteArray()
        if ($null -eq $il) { continue }
        Write-Output ''
        Write-Output ('### {0}.{1}({2})' -f $t.FullName, $m.Name, (($m.GetParameters() | ForEach-Object { $_.ParameterType.Name + ' ' + $_.Name }) -join ', '))
        $locals = @()
        try { $locals = $body.LocalVariables | ForEach-Object { $_.LocalType.Name + ' V' + $_.LocalIndex } } catch { }
        if ($locals) { Write-Output ('    .locals ' + ($locals -join ', ')) }
        $i = 0
        while ($i -lt $il.Length) {
            $start = $i
            $key = [int]$il[$i]; $opBytes = 1
            if ($il[$i] -eq 0xFE -and ($i + 1) -lt $il.Length) { $key = 0xFE00 -bor [int]$il[$i + 1]; $opBytes = 2 }
            $op = $script:OpMap[$key]
            if ($null -eq $op) { $i += $opBytes; continue }
            $operandPos = $i + $opBytes
            if ($operandPos -gt $il.Length) { break }
            $o = Read-Operand $op $il $operandPos $m.Module
            if ($o.Text) { Write-Output ('    IL_{0:X4}: {1,-14} {2}' -f $start, $op.Name, $o.Text) }
            else { Write-Output ('    IL_{0:X4}: {1}' -f $start, $op.Name) }
            $i = $operandPos + $o.Size
        }
    }
}
