cmake_minimum_required(VERSION 3.20)
project(t1report VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Binaries land next to the build directory rather than in a config subfolder,
# so the documented path (app/build/t1report) is the same on every generator.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

#------------------------------------------------------------------------------
# libpq (PostgreSQL client)
#
# Homebrew's postgresql@14 is keg-only: its headers and library are tucked under
# a versioned subdirectory and it registers no .pc file, so neither
# find_package(PostgreSQL) nor pkg-config locates it unaided. The Homebrew
# prefix is asked for it directly, with the normal search paths kept as a
# fallback for other platforms.
#------------------------------------------------------------------------------
find_program(BREW_EXECUTABLE brew)
if(BREW_EXECUTABLE)
    execute_process(COMMAND ${BREW_EXECUTABLE} --prefix
                    OUTPUT_VARIABLE BREW_PREFIX
                    OUTPUT_STRIP_TRAILING_WHITESPACE
                    ERROR_QUIET)
endif()

set(_pg_hints)
set(_pg_inc_hints)
if(BREW_PREFIX)
    foreach(_v postgresql@17 postgresql@16 postgresql@15 postgresql@14 libpq)
        list(APPEND _pg_hints     "${BREW_PREFIX}/opt/${_v}/lib")
        list(APPEND _pg_inc_hints "${BREW_PREFIX}/opt/${_v}/include")
    endforeach()
    # postgresql@N also installs into versioned subdirectories of the prefix.
    file(GLOB _pg_versioned_lib "${BREW_PREFIX}/lib/postgresql@*")
    file(GLOB _pg_versioned_inc "${BREW_PREFIX}/include/postgresql@*")
    list(APPEND _pg_hints ${_pg_versioned_lib})
    list(APPEND _pg_inc_hints ${_pg_versioned_inc})
endif()

find_path(LIBPQ_INCLUDE_DIR libpq-fe.h
          HINTS ${_pg_inc_hints}
          PATH_SUFFIXES postgresql)
find_library(LIBPQ_LIBRARY NAMES pq libpq
             HINTS ${_pg_hints})

if(NOT LIBPQ_INCLUDE_DIR OR NOT LIBPQ_LIBRARY)
    message(FATAL_ERROR
        "libpq not found.\n"
        "  headers: ${LIBPQ_INCLUDE_DIR}\n"
        "  library: ${LIBPQ_LIBRARY}\n"
        "Install it with:  brew install postgresql@14\n"
        "or point cmake at it with -DLIBPQ_INCLUDE_DIR=... -DLIBPQ_LIBRARY=...")
endif()
message(STATUS "libpq headers : ${LIBPQ_INCLUDE_DIR}")
message(STATUS "libpq library : ${LIBPQ_LIBRARY}")

#------------------------------------------------------------------------------
# unixODBC (SQL Server, via the FreeTDS driver registered by
# scripts/setup-odbc.sh - the driver is loaded at run time, so only the ODBC
# driver manager is linked here)
#------------------------------------------------------------------------------
set(_odbc_hints)
set(_odbc_inc_hints)
if(BREW_PREFIX)
    list(APPEND _odbc_hints     "${BREW_PREFIX}/opt/unixodbc/lib")
    list(APPEND _odbc_inc_hints "${BREW_PREFIX}/opt/unixodbc/include")
endif()

find_path(ODBC_INCLUDE_DIR sql.h HINTS ${_odbc_inc_hints})
find_library(ODBC_LIBRARY NAMES odbc iodbc odbc32 HINTS ${_odbc_hints})

if(NOT ODBC_INCLUDE_DIR OR NOT ODBC_LIBRARY)
    message(FATAL_ERROR
        "unixODBC not found.\n"
        "  headers: ${ODBC_INCLUDE_DIR}\n"
        "  library: ${ODBC_LIBRARY}\n"
        "Run scripts/setup-odbc.sh first.")
endif()
message(STATUS "unixODBC headers: ${ODBC_INCLUDE_DIR}")
message(STATUS "unixODBC library: ${ODBC_LIBRARY}")

#------------------------------------------------------------------------------
add_executable(t1report
    src/main.cpp
    src/query.cpp
    src/money.cpp
    src/formatter.cpp
    src/postgres_source.cpp
    src/sqlserver_source.cpp
)

target_include_directories(t1report
    PRIVATE include ${LIBPQ_INCLUDE_DIR} ${ODBC_INCLUDE_DIR})

target_link_libraries(t1report PRIVATE ${LIBPQ_LIBRARY} ${ODBC_LIBRARY})

target_compile_options(t1report PRIVATE
    -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion)
