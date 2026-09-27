# dotnet-il.ps1 - proper IL walker for .NET assemblies (no decompiler required)
# Emits, per method: int constants, string literals and called methods, in order.
# Usage: powershell -File dotnet-il.ps1 <assembly> -TypeFilter <regex> [-MethodFilter <regex>]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$TypeFilter = '.',
    [string]$MethodFilter = '.',
    [switch]$Quiet
)

Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Xaml           -ErrorAction SilentlyContinue
Add-Type -AssemblyName WindowsBase           -ErrorAction SilentlyContinue

# ---- opcode table ---------------------------------------------------------
$script:OpMap = @{}
foreach ($f in [Reflection.Emit.OpCodes].GetFields([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static)) {
    $op = $f.GetValue($null)
    $key = [int]$op.Value -band 0xFFFF
    $script:OpMap[$key] = $op
}

function Get-OperandSize($op, [byte[]]$il, [int]$pos) {
    switch ($op.OperandType.ToString()) {
        'InlineNone'          { return 0 }
        'ShortInlineI'        { return 1 }
        'ShortInlineVar'      { return 1 }
        'ShortInlineBrTarget' { return 1 }
        'InlineVar'           { return 2 }
        'InlineI'             { return 4 }
        'InlineBrTarget'      { return 4 }
        'InlineField'         { return 4 }
        'InlineMethod'        { return 4 }
        'InlineSig'           { return 4 }
        'InlineString'        { return 4 }
        'InlineTok'           { return 4 }
        'InlineType'          { return 4 }
        'ShortInlineR'        { return 4 }
        'InlineI8'            { return 8 }
        'InlineR'             { return 8 }
        'InlineSwitch'        { return 4 + 4 * [BitConverter]::ToInt32($il, $pos) }
        default               { return 0 }
    }
}

$asm = [Reflection.Assembly]::LoadFile((Resolve-Path -LiteralPath $Path).Path)
$types = @()
try { $types = $asm.GetTypes() }
catch [Reflection.ReflectionTypeLoadException] { $types = $_.Exception.Types | Where-Object { $_ -ne $null } }

$flags = [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic -bor `
         [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance -bor `
         [Reflection.BindingFlags]::DeclaredOnly

foreach ($t in ($types | Sort-Object FullName)) {
    if ($t.FullName -notmatch $TypeFilter) { continue }
    $ms = @()
    try { $ms = $t.GetMethods($flags) } catch { continue }
    foreach ($m in $ms) {
        if ($m.Name -notmatch $MethodFilter) { continue }
        $body = $null
        try { $body = $m.GetMethodBody() } catch { continue }
        if ($null -eq $body) { continue }
        $il = $body.GetILAsByteArray()
        if ($null -eq $il) { continue }
        $mod = $m.Module

        $trace = New-Object System.Collections.Generic.List[string]
        $i = 0
        while ($i -lt $il.Length) {
            $key = [int]$il[$i]; $opBytes = 1
            if ($il[$i] -eq 0xFE -and ($i + 1) -lt $il.Length) { $key = 0xFE00 -bor [int]$il[$i + 1]; $opBytes = 2 }
            $op = $script:OpMap[$key]
            if ($null -eq $op) { $i += $opBytes; continue }

            $operandPos = $i + $opBytes
            $size = Get-OperandSize $op $il $operandPos

            switch ($op.Name) {
                'ldc.i4.m1' { $trace.Add('-1') }
                'ldc.i4.0'  { $trace.Add('0') }
                'ldc.i4.1'  { $trace.Add('1') }
                'ldc.i4.2'  { $trace.Add('2') }
                'ldc.i4.3'  { $trace.Add('3') }
                'ldc.i4.4'  { $trace.Add('4') }
                'ldc.i4.5'  { $trace.Add('5') }
                'ldc.i4.6'  { $trace.Add('6') }
                'ldc.i4.7'  { $trace.Add('7') }
                'ldc.i4.8'  { $trace.Add('8') }
                # ldc.i4.s takes a SIGNED byte, so 0xF7 (=247, e.g. PreGPU_Mode) arrives as
                # -9. Casting [sbyte]191 throws in PowerShell, so sign-extend by hand and
                # show the unsigned byte next to it - otherwise enum ids like 247 read as -9.
                'ldc.i4.s'  {
                    $raw = [int]$il[$operandPos]
                    $v = if ($raw -gt 127) { $raw - 256 } else { $raw }
                    if ($raw -gt 127) { $trace.Add(('{0} (0x{1:X2})' -f $v, $raw)) } else { $trace.Add([string]$v) }
                }
                'ldc.i4'    { $trace.Add([string][BitConverter]::ToInt32($il, $operandPos)) }
                'ldc.i8'    { $trace.Add([string][BitConverter]::ToInt64($il, $operandPos)) }
                'ldc.r4'    { $trace.Add('f32:' + [BitConverter]::ToSingle($il, $operandPos).ToString('R')) }
                'ldc.r8'    { $trace.Add('f64:' + [BitConverter]::ToDouble($il, $operandPos).ToString('R')) }
                'ldstr' {
                    try { $trace.Add('"' + $mod.ResolveString([BitConverter]::ToInt32($il, $operandPos)) + '"') } catch { }
                }
                'call' {
                    try {
                        $mm = $mod.ResolveMethod([BitConverter]::ToInt32($il, $operandPos))
                        $trace.Add('CALL ' + $mm.DeclaringType.Name + '.' + $mm.Name)
                    }
                    catch { }
                }
                'callvirt' {
                    try {
                        $mm = $mod.ResolveMethod([BitConverter]::ToInt32($il, $operandPos))
                        $trace.Add('CALLV ' + $mm.DeclaringType.Name + '.' + $mm.Name)
                    }
                    catch { }
                }
                'newobj' {
                    try {
                        $mm = $mod.ResolveMethod([BitConverter]::ToInt32($il, $operandPos))
                        $trace.Add('NEW ' + $mm.DeclaringType.Name + '::.ctor')
                    }
                    catch { }
                }
                'ldfld' { try { $trace.Add('FLD ' + $mod.ResolveField([BitConverter]::ToInt32($il, $operandPos)).Name) } catch { } }
                'stfld' { try { $trace.Add('FLD! ' + $mod.ResolveField([BitConverter]::ToInt32($il, $operandPos)).Name) } catch { } }
                'ldsfld' { try { $trace.Add('SFLD ' + $mod.ResolveField([BitConverter]::ToInt32($il, $operandPos)).Name) } catch { } }
                'stsfld' { try { $trace.Add('SFLD! ' + $mod.ResolveField([BitConverter]::ToInt32($il, $operandPos)).Name) } catch { } }
                # arithmetic / element access - needed to read the byte-layout recipes
                'ldelem.u1' { $trace.Add('B[') }
                'ldelem.i1' { $trace.Add('b[') }
                'ldelem.u2' { $trace.Add('W[') }
                'ldelem.i2' { $trace.Add('w[') }
                'ldelem.u4' { $trace.Add('D[') }
                'ldelem.i4' { $trace.Add('d[') }
                'ldelem'    { $trace.Add('E[') }
                'stelem.i1' { $trace.Add(']B!') }
                'stelem.i2' { $trace.Add(']W!') }
                'stelem.i4' { $trace.Add(']D!') }
                'shl' { $trace.Add('<<') }
                'shr' { $trace.Add('>>') }
                'shr.un' { $trace.Add('>>>') }
                'add' { $trace.Add('+') }
                'sub' { $trace.Add('-') }
                'mul' { $trace.Add('*') }
                'div' { $trace.Add('/') }
                'div.un' { $trace.Add('//') }
                'rem' { $trace.Add('%') }
                'or'  { $trace.Add('|') }
                'and' { $trace.Add('&') }
                'xor' { $trace.Add('^') }
                'not' { $trace.Add('~') }
                'neg' { $trace.Add('neg') }
                'conv.u1' { $trace.Add('->u8') }
                'conv.i1' { $trace.Add('->i8') }
                'conv.u2' { $trace.Add('->u16') }
                'conv.i2' { $trace.Add('->i16') }
                'conv.i4' { $trace.Add('->i32') }
                'conv.u4' { $trace.Add('->u32') }
                'conv.r4' { $trace.Add('->f32') }
                'conv.r8' { $trace.Add('->f64') }
                'dup' { $trace.Add('dup') }
                'pop' { $trace.Add('pop') }
            }
            if (($operandPos + $size) -gt $il.Length) { break }
            $i = $operandPos + $size
        }

        Write-Output ('### {0}.{1}({2})' -f $t.FullName, $m.Name, (($m.GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ','))
        if (-not $Quiet) { Write-Output ('    ' + ($trace -join ' ')) }
    }
}
