# dotnet-probe.ps1 - read P/Invoke surface + IL constants straight out of a .NET assembly
# without any decompiler. Usage: powershell -File dotnet-probe.ps1 <assembly> [-Exports] [-Il <regex>]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Exports,
    [string]$Il
)

Add-Type -AssemblyName PresentationFramework  -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Xaml            -ErrorAction SilentlyContinue
Add-Type -AssemblyName WindowsBase            -ErrorAction SilentlyContinue

$asm = [Reflection.Assembly]::LoadFile((Resolve-Path -LiteralPath $Path).Path)

$types = @()
try { $types = $asm.GetTypes() }
catch [Reflection.ReflectionTypeLoadException] {
    Write-Output "!! ReflectionTypeLoadException - using partial types"
    foreach ($le in $_.Exception.LoaderExceptions) { Write-Output ("   loader: " + $le.Message) }
    $types = $_.Exception.Types | Where-Object { $_ -ne $null }
}
Write-Output ("### assembly: {0}  types={1}" -f $asm.FullName, $types.Count)

$flags = [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic -bor `
         [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance -bor `
         [Reflection.BindingFlags]::DeclaredOnly

if ($Exports) {
    Write-Output "### DllImport surface"
    foreach ($t in $types) {
        $ms = $null
        try { $ms = $t.GetMethods($flags) } catch { continue }
        foreach ($m in $ms) {
            $di = $null
            try { $di = $m.GetCustomAttributes([System.Runtime.InteropServices.DllImportAttribute], $false) } catch { }
            foreach ($d in $di) {
                $ps = ($m.GetParameters() | ForEach-Object { "{0} {1}" -f $_.ParameterType.Name, $_.Name }) -join ', '
                Write-Output ("  [{0}] {1} {2}.{3}({4})" -f $d.Value, $m.ReturnType.Name, $t.FullName, $m.Name, $ps)
            }
        }
    }
}

if ($Il) {
    Write-Output "### IL scan: methods matching '$Il'"
    foreach ($t in $types) {
        $ms = $null
        try { $ms = $t.GetMethods($flags) } catch { continue }
        foreach ($m in $ms) {
            if ($m.Name -notmatch $Il -and $t.Name -notmatch $Il) { continue }
            $body = $null
            try { $body = $m.GetMethodBody() } catch { continue }
            if ($null -eq $body) { continue }
            $ilb = $body.GetILAsByteArray()
            $mod = $m.Module
            # collect int32 constants pushed by ldc.i4 family and string literals
            $ints = New-Object System.Collections.Generic.List[string]
            $strs = New-Object System.Collections.Generic.List[string]
            $i = 0
            while ($i -lt $ilb.Length) {
                $op = $ilb[$i]
                switch ($op) {
                    0x1F { if ($i + 4 -lt $ilb.Length) { $ints.Add([BitConverter]::ToInt32($ilb, $i + 1)) }; $i += 5; continue }
                    0x20 { if ($i + 4 -lt $ilb.Length) { $ints.Add([BitConverter]::ToInt32($ilb, $i + 1)) }; $i += 5; continue }
                    0x21 { if ($i + 8 -lt $ilb.Length) { $ints.Add([BitConverter]::ToInt64($ilb, $i + 1)) }; $i += 9; continue }
                    0x72 {
                        if ($i + 4 -lt $ilb.Length) {
                            $tok = [BitConverter]::ToInt32($ilb, $i + 1)
                            try { $strs.Add($mod.ResolveString($tok)) } catch { }
                        }
                        $i += 5; continue
                    }
                    0x22 { $i += 5; continue }   # ldc.r4
                    0x23 { $i += 9; continue }   # ldc.r8
                    0x28 { $i += 5; continue }   # call
                    0x6F { $i += 5; continue }   # callvirt
                    0x73 { $i += 5; continue }   # newobj
                    0x7B { $i += 5; continue }   # ldfld
                    0x7D { $i += 5; continue }   # stfld
                    0x80 { $i += 5; continue }   # stsfld
                    0x7E { $i += 5; continue }   # ldsfld
                    0x74 { $i += 5; continue }   # castclass
                    0x75 { $i += 5; continue }   # unbox
                    0x8C { $i += 5; continue }   # box
                    0x8D { $i += 5; continue }   # newarr
                    0x8F { $i += 5; continue }   # stelem
                    0xFE { $i += 5; continue }   # two-byte opcodes (approx)
                    default { $i += 1; continue }
                }
            }
            $intTxt = ($ints | Select-Object -Unique | Select-Object -First 40) -join ','
            $strTxt = ($strs | Select-Object -Unique | Select-Object -First 25) -join ' | '
            Write-Output ("  {0}.{1}  ints=[{2}]  strs=[{3}]" -f $t.FullName, $m.Name, $intTxt, $strTxt)
        }
    }
}
