# vcpkg.exe runs native Windows CMake even when the outer build is hosted by
# an MSYS2 MINGW64 shell. Pinning the native paths avoids depending on PATH
# conversion behavior at that process boundary.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Keep the MinGW runtime DLL directory visible to compiler subprocesses. The
# native CMake/Ninja processes do not consistently inherit MSYS2's converted
# PATH when the build is launched through Windows OpenSSH.
set(ENV{PATH} "C:\\msys64\\mingw64\\bin;$ENV{PATH}")

set(CMAKE_C_COMPILER
    "${CMAKE_CURRENT_LIST_DIR}/mingw-gcc.cmd")
set(CMAKE_CXX_COMPILER
    "${CMAKE_CURRENT_LIST_DIR}/mingw-gxx.cmd")
set(CMAKE_RC_COMPILER
    "${CMAKE_CURRENT_LIST_DIR}/mingw-windres.cmd")
