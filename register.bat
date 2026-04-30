@echo off
:: register.bat  --  Associate .vth files with vthelp.exe
:: Run as Administrator

assoc .vth=vthelp.helpfile
ftype vthelp.helpfile="%~dp0vthelp.exe" "%%1"

echo .vth files are now associated with vthelp.exe
echo Location: %~dp0vthelp.exe
pause
