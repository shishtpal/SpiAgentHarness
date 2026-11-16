function New-AgentHarnessFileWriteDirectory {
    $directory = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('SpiFileWrites-' + [guid]::NewGuid().ToString('N')))
    $null = [IO.Directory]::CreateDirectory($directory)
    try {
        if ($IsWindows) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { $owner = $identity.User } finally { $identity.Dispose() }
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($owner)
            $acl.SetAccessRuleProtection($true, $false)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($owner, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
            Set-Acl -LiteralPath $directory -AclObject $acl -ErrorAction Stop
        }
        elseif ('System.IO.UnixFileMode' -as [type]) {
            [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        else {
            # PowerShell 7.0 predates the managed Unix mode API; chmod is a base OS utility.
            $chmod = Get-Command chmod -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $null = & $chmod.Source '700' '--' $directory 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the staging directory.' }
        }
        $directory
    }
    catch {
        [IO.Directory]::Delete($directory, $false)
        throw 'Cannot create a private file-write staging directory.'
    }
}