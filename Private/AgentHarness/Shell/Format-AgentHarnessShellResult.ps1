function Format-AgentHarnessShellResult {
    param($Process, [int]$MaxOutputChars = 8000, [switch]$IncludeId)

    $snapshot = $Process.Snapshot()
    $sections = [Collections.Generic.List[string]]::new()
    if ($IncludeId) {
        $sections.Add("process id: $($snapshot.Id)`nstate: $($snapshot.State)`ndeadline: $($Process.TimeoutSec) seconds")
    }
    elseif ($snapshot.State -eq 'timed_out') {
        $sections.Add("ERROR: command timed out after $($Process.TimeoutSec)s.")
    }
    if ($null -ne $snapshot.ExitCode) { $sections.Add("exit code: $($snapshot.ExitCode)") }
    if ($snapshot.TerminationError) { $sections.Add($snapshot.TerminationError) }
    if ($snapshot.CaptureIncomplete) { $sections.Add('Output capture incomplete: a pipe failed or remained open after process exit.') }
    # Reserve labels/notices within the model-facing limit. Capture has its own
    # fixed cap, including for output that never emits a newline.
    $header = $sections -join "`n`n"
    $allowance = [Math]::Min(65536, [Math]::Max(0, [int][Math]::Floor(($MaxOutputChars - $header.Length - 300) / 2)))
    foreach ($stream in @(@{ Name = 'Output'; Text = $snapshot.Output; Total = $snapshot.OutputChars }, @{ Name = 'Errors'; Text = $snapshot.Error; Total = $snapshot.ErrorChars })) {
        if (-not $stream.Total) { continue }
        $text = $stream.Text
        if ($text.Length -gt $allowance) { $text = $text.Substring($text.Length - $allowance) }
        $notice = if ($stream.Total -gt $text.Length) { "[truncated; showing last $($text.Length) of $($stream.Total) chars]`n" } else { '' }
        $sections.Add("$($stream.Name):`n$notice$($text.TrimEnd("`r", "`n"))")
    }
    $sections -join "`n`n"
}