# vcpkg.exe runs native Windows CMake even when the outer build is hosted by
# an MSYS2 MINGW64 shell. Pass the discovered native compiler directory across
# that process boundary rather than assuming MSYS2 is installed on C:.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

if(NOT DEFINED ENV{LIBVIPS_FFM_MINGW_BIN} OR
   "$ENV{LIBVIPS_FFM_MINGW_BIN}" STREQUAL "")
  message(FATAL_ERROR
          "LIBVIPS_FFM_MINGW_BIN must name the native MSYS2 compiler directory")
endif()

# Keep the MinGW runtime DLL directory visible to compiler subprocesses. The
# native CMake/Ninja processes do not consistently inherit MSYS2's converted
# PATH when the build is launched through Windows OpenSSH.
set(ENV{PATH} "$ENV{LIBVIPS_FFM_MINGW_BIN};$ENV{PATH}")
set(LIBVIPS_FFM_MINGW_BIN "$ENV{LIBVIPS_FFM_MINGW_BIN}")

set(CMAKE_C_COMPILER
    "${CMAKE_CURRENT_LIST_DIR}/mingw-gcc.cmd")
set(CMAKE_CXX_COMPILER
    "${CMAKE_CURRENT_LIST_DIR}/mingw-gxx.cmd")
set(CMAKE_RC_COMPILER
    "${CMAKE_CURRENT_LIST_DIR}/mingw-windres.cmd")
