cmake_minimum_required(VERSION 3.20)
project(BifrostAccountGuard VERSION 1.0.0 LANGUAGES CXX)

# A Bifrost checkout at API revision 9 or later, for its headers and manifest helper
set(BIFROST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Bifrost" CACHE PATH "Bifrost source directory")
if(NOT EXISTS "${BIFROST_DIR}/cmake/BifrostPlugin.cmake")
    message(FATAL_ERROR "BIFROST_DIR (${BIFROST_DIR}) is not a Bifrost checkout")
endif()
include("${BIFROST_DIR}/cmake/BifrostPlugin.cmake")

add_library(AccountGuard SHARED src/Plugin.cpp)
target_compile_features(AccountGuard PRIVATE cxx_std_23)
target_include_directories(AccountGuard PRIVATE src)
set_target_properties(AccountGuard PROPERTIES PREFIX "" CXX_VISIBILITY_PRESET hidden
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
bifrost_embed_manifest(AccountGuard plugin.toml)
if(MINGW)
    target_link_options(AccountGuard PRIVATE -static)
endif()
if(NOT WIN32)
    target_link_libraries(AccountGuard PRIVATE ${CMAKE_DL_LIBS})
endif()

enable_testing()
add_executable(AccountGuardTests tests/Tests.cpp)
target_compile_features(AccountGuardTests PRIVATE cxx_std_23)
target_include_directories(AccountGuardTests PRIVATE src "${BIFROST_DIR}/include")
target_compile_definitions(AccountGuardTests PRIVATE
    ACCOUNTGUARD_EXAMPLE_CONFIG="${CMAKE_CURRENT_SOURCE_DIR}/config/AccountGuard.toml")
add_test(NAME AccountGuardTests COMMAND AccountGuardTests)

install(TARGETS AccountGuard LIBRARY DESTINATION plugins RUNTIME DESTINATION plugins)
install(FILES config/AccountGuard.toml DESTINATION plugins)
