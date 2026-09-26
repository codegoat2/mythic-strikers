param([Parameter(Mandatory=$true)][string]$Path,
      [int]$From = 1,
      [int]$To = 100000)

function Strip([string]$t) {
    $t = [regex]::Replace($t, '(?s)--\[\[.*?\]\]', ' ')
    $t = [regex]::Replace($t, '(?s)\[\[.*?\]\]', ' ')
    $t = [regex]::Replace($t, '"[^"\r\n]*"', '""')
    $t = [regex]::Replace($t, "'[^'\r\n]*'", "''")
    $t = [regex]::Replace($t, '--[^\r\n]*', ' ')
    return $t
}

$reFn  = [regex]'(?<![\w.])function(?![\w])'
$reIf  = [regex]'(?m)^\s*if\b'
$reDo  = [regex]'(?<![\w.])do(?![\w])'
$reEn  = [regex]'(?<![\w.])end(?![\w])'

$lines = (Get-Content -Raw -LiteralPath $Path) -split "`r?`n"
$depth = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    $lineNo = $i + 1
    $code = Strip $lines[$i]
    $o = $reFn.Matches($code).Count + $reIf.Matches($code).Count + $reDo.Matches($code).Count
    $e = $reEn.Matches($code).Count
    $before = $depth
    $depth += ($o - $e)
    if ($lineNo -ge $From -and $lineNo -le $To) {
        $flag = if ($depth -lt 0) { ' <<< NEGATIVE' } else { '' }
        Write-Output ("{0,5} d{1}->{2}  o={3} e={4}{5}  {6}" -f $lineNo, $before, $depth, $o, $e, $flag, $lines[$i].Trim())
    }
}
