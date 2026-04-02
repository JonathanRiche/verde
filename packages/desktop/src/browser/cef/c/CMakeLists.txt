cmake_minimum_required(VERSION 3.21)

project(verde_cef_helper)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CEF_ROOT)
  message(FATAL_ERROR "CEF_ROOT must point at the CEF SDK root.")
endif()

list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)
ADD_LOGICAL_TARGET(libcef_lib "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")

add_executable(verde-browser-cef
  cef_loader.cpp
  helper_linux.cc
  native_linux.cc
)

add_executable(verde-browser-cef-process
  cef_loader.cpp
  native_linux.cc
  process_helper_linux.cc
)

SET_EXECUTABLE_TARGET_PROPERTIES(verde-browser-cef)
SET_EXECUTABLE_TARGET_PROPERTIES(verde-browser-cef-process)
target_link_libraries(verde-browser-cef PRIVATE
  libcef_lib
  libcef_dll_wrapper
  dl
  ${CEF_STANDARD_LIBS}
)
target_link_libraries(verde-browser-cef-process PRIVATE
  libcef_lib
  libcef_dll_wrapper
  dl
  ${CEF_STANDARD_LIBS}
)

if(VERDE_OUTPUT_DIR)
  set_target_properties(verde-browser-cef PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${VERDE_OUTPUT_DIR}"
  )
  set_target_properties(verde-browser-cef-process PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${VERDE_OUTPUT_DIR}"
  )
endif()
