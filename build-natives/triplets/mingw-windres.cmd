@echo off
if not defined LIBVIPS_FFM_MINGW_BIN (
  echo LIBVIPS_FFM_MINGW_BIN is not set 1>&2
  exit /b 1
)
set "PATH=%LIBVIPS_FFM_MINGW_BIN%;%PATH%"
"%LIBVIPS_FFM_MINGW_BIN%\windres.exe" %*
