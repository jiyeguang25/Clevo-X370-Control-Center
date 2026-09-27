# dotnet-consts.ps1 - dump literal constants, enums and method names from a .NET assembly
# Usage: powershell -File dotnet-consts.ps1 <assembly> [-TypeFilter <regex>]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$TypeFilter = '.',
    [switch]$Methods
)

Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Xaml           -ErrorAction SilentlyContinue
Add-Type -AssemblyName WindowsBase           -ErrorAction SilentlyContinue

$asm = [Reflection.Assembly]::LoadFile((Resolve-Path -LiteralPath $Path).Path)
$types = @()
try { $types = $asm.GetTypes() }
catch [Reflection.ReflectionTypeLoadException] { $types = $_.Exception.Types | Where-Object { $_ -ne $null } }

$flags = [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic -bor `
         [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance -bor `
         [Reflection.BindingFlags]::DeclaredOnly

foreach ($t in ($types | Sort-Object FullName)) {
    if ($t.FullName -notmatch $TypeFilter) { continue }

    $enums = @()
    if ($t.IsEnum) {
        foreach ($n in [Enum]::GetNames($t)) {
            $v = [Convert]::ToInt64([Enum]::Parse($t, $n))
            $enums += ("      {0} = {1} (0x{1:X})" -f $n, $v)
        }
    }

    $consts = @()
    $fields = @()
    try { $fields = $t.GetFields($flags) } catch { }
    foreach ($f in $fields) {
        try {
            if ($f.IsLiteral) {
                $v = $f.GetRawConstantValue()
                $num = if ($v -is [ValueType] -and $v -isnot [bool]) { " (0x{0:X})" -f [int64]$v } else { '' }
                $consts += ("      const {0} {1} = {2}{3}" -f $f.FieldType.Name, $f.Name, $v, $num)
            }
        }
        catch { }
    }

    $mlist = @()
    if ($Methods) {
        $ms = @()
        try { $ms = $t.GetMethods($flags) } catch { }
        foreach ($m in $ms) {
            $ps = ($m.GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ','
            $mlist += ("      {0} {1}({2})" -f $m.ReturnType.Name, $m.Name, $ps)
        }
    }

    if ($enums.Count -or $consts.Count -or $mlist.Count) {
        Write-Output ("### {0}" -f $t.FullName)
        if ($enums.Count)   { Write-Output '   [enum]';   $enums   | ForEach-Object { Write-Output $_ } }
        if ($consts.Count)  { Write-Output '   [const]';  $consts  | ForEach-Object { Write-Output $_ } }
        if ($mlist.Count)   { Write-Output '   [methods]'; $mlist  | ForEach-Object { Write-Output $_ } }
    }
}
