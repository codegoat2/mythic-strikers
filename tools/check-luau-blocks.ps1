# Luau block-balance checker
#
# Brace counting ({ } and ( )) is NOT sufficient to validate Luau. `do`, `if`,
# `for`, `while` and `function` each open a block closed by a bare `end` token,
# so a missing or extra `end` leaves every brace count perfectly balanced while
# the file still fails to compile with "Expected <eof>, got 'end'".
#
# This counts block openers against `end` tokens so that class of error is
# caught. Comments and string literals are stripped first so keywords inside
# them are not miscounted.
#
# Usage:  pwsh -File tools/check-luau-blocks.ps1

$ErrorActionPreference = 'Stop'

function Remove-LuauNoise([string]$Text) {
    $t = $Text
    # Long comments --[[ ... ]]
    $t = [regex]::Replace($t, '(?s)--\[\[.*?\]\]', ' ')
    # Long strings [[ ... ]]
    $t = [regex]::Replace($t, '(?s)\[\[.*?\]\]', ' ')
    # Quoted strings (single line is enough for this project's style)
    $t = [regex]::Replace($t, '"[^"\r\n]*"', '""')
    $t = [regex]::Replace($t, "'[^'\r\n]*'", "''")
    # Line comments
    $t = [regex]::Replace($t, '--[^\r\n]*', ' ')
    return $t
}

$reFn     = [regex]'(?<![\w.])function(?![\w])'
# `if` only opens a block in STATEMENT position. A Luau if-expression
# (`local x = if cond then a else b`) has no `end`, and always appears after
# something on the line, so only count `if` that starts the line.
$reIfStmt = [regex]'(?m)^\s*if\b'
$reIfAny  = [regex]'(?<![\w.])if(?![\w])'
$reFor    = [regex]'(?<![\w.])for(?![\w])'
$reWhile  = [regex]'(?<![\w.])while(?![\w])'
$reDo     = [regex]'(?<![\w.])do(?![\w])'
$reEnd    = [regex]'(?<![\w.])end(?![\w])'
$reRepeat = [regex]'(?<![\w.])repeat(?![\w])'
$reUntil  = [regex]'(?<![\w.])until(?![\w])'

function Test-LuauFile([string]$FullPath) {
    $code = Remove-LuauNoise (Get-Content -Raw -LiteralPath $FullPath)

    $fn  = $reFn.Matches($code).Count
    $iff = $reIfStmt.Matches($code).Count
    $do  = $reDo.Matches($code).Count
    $end = $reEnd.Matches($code).Count

    $ifExpr = $reIfAny.Matches($code).Count - $iff
    if ($ifExpr -lt 0) { $ifExpr = 0 }

    # Each `for` and each `while` header carries its own `do`, so counting bare
    # `do` tokens already accounts for those loops exactly once.
    $openers = $fn + $iff + $do

    $rep  = $reRepeat.Matches($code).Count
    $unt  = $reUntil.Matches($code).Count

    $status = 'OK'
    if ($openers -ne $end) { $status = "extra/missing end" }
    elseif ($rep -ne $unt) { $status = "repeat/until mismatch" }

    [pscustomobject]@{
        File      = Split-Path $FullPath -Leaf
        Openers   = $openers
        Ends      = $end
        Diff      = $end - $openers
        IfExprs   = $ifExpr
        Status    = $status
    }
}

$projectRoot = Split-Path $PSScriptRoot -Parent
$files = Get-ChildItem -Recurse -File -Path (Join-Path $projectRoot 'src') -Filter *.lua
$results = @($files | ForEach-Object { Test-LuauFile $_.FullName } | Sort-Object File)

$results | Format-Table -AutoSize

$bad = @($results | Where-Object { $_.Status -ne 'OK' })
Write-Output ""
Write-Output ("Checked {0} files. {1} with block problems." -f $results.Count, $bad.Count)
if ($bad.Count -gt 0) {
    Write-Output ""
    Write-Output "Files that WILL NOT COMPILE:"
    $bad | ForEach-Object { Write-Output ("  {0}  ({1}, diff {2})" -f $_.File, $_.Status, $_.Diff) }
    exit 1
}
