Set WshShell = CreateObject("WScript.Shell")
If WScript.Arguments.Count > 0 Then
  cmd = ""
  For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments(i)
    If InStr(arg, " ") > 0 Or InStr(arg, Chr(9)) > 0 Then
      arg = Chr(34) & arg & Chr(34)
    End If
    If cmd = "" Then
      cmd = arg
    Else
      cmd = cmd & " " & arg
    End If
  Next
  WshShell.Run cmd, 0, False
End If
