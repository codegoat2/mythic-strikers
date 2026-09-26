# Reports Luau block depth at each top-level function boundary, to locate
# the exact line where block nesting diverges.
# Usage: pwsh -File tools/find-depth.ps1 -Path <file>

param([Parameter(Mandatory=$true)][string]$Path)

function Strip([string]$t) {
    $t = [regex]::Replace($t, '(?s)--\[\[.*?\]\]', ' ')
    $t = [regex]::Replace($t, '(?s)\[\[.*?\]\]', ' ')
    $t = [regex]::Replace($t, '"[^"\r\n]*"', '""')
    $t = [regex]::Replace($t, "'[^'\r\n]*'", "''")
    $t = [regex]::Replace($t, '--[^\r\n]*', ' ')
    return $t
}

$reFn  = [regex]'(?<![\w.])function(?![\w])'
# Statement-position `if` only. A Luau if-expression (`x = if c then a else b`)
# has no `end` and never starts a line, so counting it as a block is wrong.
$reIf  = [regex]'(?m)^\s*if\b'
$reDo  = [regex]'(?<![\w.])do(?![\w])'
$reEn  = [regex]'(?<![\w.])end(?![\w])'
$reRp  = [regex]'(?<![\w.])repeat(?![\w])'
$reUn  = [regex]'(?<![\w.])until(?![\w])'

$lines = (Get-Content -Raw -LiteralPath $Path) -split "`r?`n"
$depth = 0
$rep   = 0
$prevWasFunc = $false

for ($i = 0; $i -lt $lines.Count; $i++) {
    $code = Strip $lines[$i]
    $o = $reFn.Matches($code).Count + $reIf.Matches($code).Count + $reDo.Matches($code).Count
    $e = $reEn.Matches($code).Count
    if ($reRp.Matches($code).Count -gt 0) { $rep++ }
    if ($reUn.Matches($code).Count -gt 0) { $rep-- }

    $isFuncStart = $code -match '^\s*(local\s+)?function\b'
    # A top-level function should begin at depth 0.
    if ($isFuncStart -and $depth -ne 0) {
        Write-Output ("UNBALANCED before line {0}  depth={1}" -f ($i + 1), $depth)
        Write-Output ("   >>> " + $lines[$i].Trim())
        for ($j = [Math]::Max(0, $i - 6); $j -lt $i; $j++) {
            Write-Output ("   prev " + ($j + 1) + ": " + $lines[$j].Trim())
        }
        Write-Output ""
    }
    $depth += ($o - $e)
    $prevWasFunc = $isFuncStart
}

Write-Output ("FINAL depth = {0}   repeat-open = {1}   lines = {2}" -f $depth, $rep, $lines.Count)
