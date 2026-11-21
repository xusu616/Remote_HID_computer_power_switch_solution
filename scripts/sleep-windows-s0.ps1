# Running this script turns off the display and requests Modern Standby.
# Verified on the project test PC; other PCs must support S0 low-power idle.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WakeBridgeModernStandby {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
'@
$window = [System.Windows.Forms.NativeWindow]::new()
$parameters = [System.Windows.Forms.CreateParams]::new()
$parameters.Caption = 'Wake Bridge Modern Standby'
$parameters.Style = 0
$window.CreateHandle($parameters)
try {
    # One recipient prevents other windows from processing queued power messages after wake.
    [void][WakeBridgeModernStandby]::SendMessage($window.Handle, 0x112, [IntPtr]0xf170, [IntPtr]2)
} finally {
    $window.DestroyHandle()
}
