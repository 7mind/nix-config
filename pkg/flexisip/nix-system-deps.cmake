# Appended after the stock ExternalDependencies.cmake body (which still
# add_subdirectory's sofia-sip). Loads the nixpkgs linphone stack that replaces
# the linphone-sdk git submodule.
#
# Expects cache variable:
#   bcSoci - store path of bc-soci (with mysql + sqlite backends)

find_package(BCToolbox REQUIRED)
find_package(Ortp REQUIRED)
find_package(Belr REQUIRED)
find_package(BelleSIP REQUIRED)
find_package(Mediastreamer2 REQUIRED)
find_package(LibLinphone REQUIRED)
find_package(LinphoneCxx REQUIRED)

if(NOT TARGET soci_core)
  add_library(soci_core SHARED IMPORTED GLOBAL)
  set_target_properties(soci_core PROPERTIES
    IMPORTED_LOCATION "${bcSoci}/lib/libsoci_core.so"
    INTERFACE_INCLUDE_DIRECTORIES "${bcSoci}/include"
  )
endif()

if(NOT TARGET soci_sqlite3)
  add_library(soci_sqlite3 SHARED IMPORTED GLOBAL)
  set_target_properties(soci_sqlite3 PROPERTIES
    IMPORTED_LOCATION "${bcSoci}/lib/libsoci_sqlite3.so"
    INTERFACE_INCLUDE_DIRECTORIES "${bcSoci}/include"
  )
endif()

if(NOT TARGET soci_mysql)
  add_library(soci_mysql SHARED IMPORTED GLOBAL)
  set_target_properties(soci_mysql PROPERTIES
    IMPORTED_LOCATION "${bcSoci}/lib/libsoci_mysql.so"
    INTERFACE_INCLUDE_DIRECTORIES "${bcSoci}/include"
    # soci_mysql was linked against libmysqlclient but does not DT_NEEDED it
    # in a way the final link always sees; pull it in explicitly.
    INTERFACE_LINK_LIBRARIES "${libMysqlClient}"
  )
endif()
