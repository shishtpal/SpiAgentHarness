function Test-InteractiveConsole {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        # KeyAvailable also checks whether this host has a usable console.
        $null = [Console]::KeyAvailable
        return $true
    }
    catch { return $false }
}