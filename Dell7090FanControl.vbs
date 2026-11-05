Option Explicit

Dim shell, fso, base, ps1, args
Set shell = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")

base = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = base & "\src\Dell7090FanControl.ps1"

args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"

If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "minimized" Then
        args = args & " -StartMinimized"
    End If
End If

shell.ShellExecute "powershell.exe", args, "", "runas", 0
