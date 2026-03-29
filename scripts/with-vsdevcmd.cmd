@echo off
setlocal

set "VSDEVCMD="
for %%P in (
  "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
) do (
  if exist %%~P (
    set "VSDEVCMD=%%~P"
    goto :found
  )
)

echo Visual Studio 2022 developer shell not found.>&2
exit /b 1

:found
call "%VSDEVCMD%" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b %errorlevel%

%*
exit /b %errorlevel%
