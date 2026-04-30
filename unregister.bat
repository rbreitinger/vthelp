@echo off
:: unregister.bat  --  Remove .vth file association
:: Run as Administrator

assoc .vth=
ftype vthelp.helpfile=

echo .vth file association removed
pause
