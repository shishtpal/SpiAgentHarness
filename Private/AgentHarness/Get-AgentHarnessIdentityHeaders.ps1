function Get-AgentHarnessIdentityHeaders {
    param([string]$PretendAgent)

    # Attribution presets only; these do not reproduce the clients' wire protocols.
    $identity = switch ($PretendAgent) {
        'Codex' { @{ Title = 'Codex'; Referer = 'https://openai.com/codex/' }; break }
        'ClaudeCode' { @{ Title = 'Claude Code'; Referer = 'https://claude.ai/code' }; break }
        'OpenCode' { @{ Title = 'opencode'; Referer = 'https://opencode.ai/' }; break }
        'Kilo' { @{ Title = 'Kilo Code'; Referer = 'https://kilo.ai/' }; break }
        'Cline' { @{ Title = 'Cline'; Referer = 'https://cline.bot' }; break }
        '' { return @{} }
        default { throw "Unknown agent identity: $PretendAgent" }
    }
    @{
        'HTTP-Referer' = $identity.Referer
        'X-Title' = $identity.Title
        'X-OpenRouter-Title' = $identity.Title
    }
}