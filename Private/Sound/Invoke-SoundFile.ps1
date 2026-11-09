function Invoke-SoundFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $IsWindows) { return $false }
    # Use a namespaced type and initialize it once, including across module reloads.
    if (-not ('SpiAgentHarness.NativeSound' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SpiAgentHarness {
    public static class NativeSound {
        [DllImport("winmm.dll", EntryPoint = "PlaySoundW", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool PlaySound(string path, IntPtr module, uint flags);
    }
}
'@ -ErrorAction Stop
    }
    # Async playback can accept the request before checking the file. Reject missing WAVs ourselves.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    # SND_ASYNC | SND_FILENAME | SND_NODEFAULT: play the requested alarm, never a quiet default sound.
    [SpiAgentHarness.NativeSound]::PlaySound($Path, [IntPtr]::Zero, 0x00020003)
}