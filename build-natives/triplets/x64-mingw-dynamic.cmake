set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
# Compiler subprocesses need the MinGW runtime DLL directory. The hosted
# runner's full PATH contains unrelated, frequently changing tool versions;
# pass it through without making those paths part of every package ABI. The
# compiler identity remains tracked separately by vcpkg.
# vcpkg sanitizes build environments. Preserve the runtime-discovered MSYS2
# compiler location without making its runner-specific absolute path part of
# package ABI hashes; compiler identity is hashed separately.
set(VCPKG_ENV_PASSTHROUGH_UNTRACKED PATH LIBVIPS_FFM_MINGW_BIN)
set(VCPKG_CMAKE_SYSTEM_NAME MinGW)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE
    "${CMAKE_CURRENT_LIST_DIR}/x64-mingw-msys2-toolchain.cmake")
set(VCPKG_BUILD_TYPE release)
set(VCPKG_C_FLAGS "")
set(VCPKG_CXX_FLAGS "")
set(VCPKG_LINKER_FLAGS "")
