{
  lib,
  stdenv,
  fetchurl,
  cmake,
  ninja,
  pkg-config,
  python3,
  git,
  gawk,
  patchelf,
  openssl,
  systemd,
  nghttp2,
  sqlite,
  jsoncpp,
  xercesc,
  libxml2,
  hiredis,
  libmysqlclient,
  srtp,
  speex,
  jansson,
  zlib,
  boost,
  linphonePackages,
}:

let
  version = "1.0.2";

  flexisipSrc = fetchurl {
    url = "https://github.com/BelledonneCommunications/flexisip/archive/32c1968f8c1f506101c2689a630038f0536c60dd.tar.gz";
    hash = "sha256-ydu/AGu99iQSRxVO9ysb1C8kUlmlVE/uaGQ6tG5l3Ls=";
  };

  sofiaSrc = ../flexisip/vendor/bc-sofia-sip-02b6544.tar.gz;

  xsdSrc = fetchurl {
    url = "https://gitlab.linphone.org/BC/public/external/xsd/-/archive/a2ca5f3676c1139346f386648f16e95ab4f34044/xsd-a2ca5f3676c1139346f386648f16e95ab4f34044.tar.gz";
    hash = "sha256-aOPerU4PjjNCcJO7ymD6OwVh0Jp3/kTqIPOxvqL1qG4=";
  };

  pythonEnv = python3.withPackages (ps: [
    ps.pystache
    ps.six
  ]);

  bc-soci = linphonePackages.bc-soci.overrideAttrs (old: {
    buildInputs = (old.buildInputs or [ ]) ++ [
      libmysqlclient
      boost
    ];
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DWITH_MYSQL=YES"
      "-DMYSQL_INCLUDE_DIR=${libmysqlclient.dev}/include/mysql"
      "-DMYSQL_LIBRARIES=${libmysqlclient}/lib/mariadb/libmysqlclient.so"
    ];
  });

  cmakePrefixPath = lib.concatStringsSep ";" [
    linphonePackages.bctoolbox
    linphonePackages.ortp
    linphonePackages.belr
    linphonePackages.belle-sip
    linphonePackages.belcard
    linphonePackages.bzrtp
    linphonePackages.lime
    linphonePackages.mediastreamer2
    linphonePackages.liblinphone
    linphonePackages.bc-decaf
    linphonePackages.bc-mbedtls
    bc-soci
    jsoncpp
    openssl
    sqlite
    xercesc
    libxml2
  ];

  runtimeLibPath = lib.makeLibraryPath [
    linphonePackages.bctoolbox
    linphonePackages.ortp
    linphonePackages.belr
    linphonePackages.belle-sip
    linphonePackages.mediastreamer2
    linphonePackages.liblinphone
    bc-soci
    linphonePackages.lime
    linphonePackages.bzrtp
    openssl
    nghttp2
    sqlite
    jsoncpp
    srtp
    speex
    xercesc
    libxml2
    systemd
    libmysqlclient
    hiredis
  ];
in
stdenv.mkDerivation {
  pname = "flexisip-conference";
  inherit version;

  # Official mirror: the canonical GitLab archive is unreachable from builders.
  src = fetchurl {
    url = "https://github.com/BelledonneCommunications/flexisip-conference/archive/${version}.tar.gz";
    hash = "sha256-W/95VVW9XAFaTJ+ltAthbqJDU0d0v2ans5EaCPSFY4s=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    git
    pythonEnv
    gawk
    patchelf
  ];

  buildInputs = [
    openssl
    systemd
    nghttp2
    sqlite
    jsoncpp
    xercesc
    libxml2
    hiredis
    libmysqlclient
    srtp
    speex
    jansson
    zlib
    linphonePackages.bctoolbox
    linphonePackages.ortp
    linphonePackages.belr
    linphonePackages.belle-sip
    linphonePackages.mediastreamer2
    linphonePackages.liblinphone
    linphonePackages.lime
    linphonePackages.bzrtp
    linphonePackages.belcard
    linphonePackages.bc-decaf
    bc-soci
  ];

  postPatch = ''
    conference_resource_replacement=${lib.escapeShellArg "Factory::get()->setTopResourcesDir(\"${placeholder "out"}/share\");\n\tauto configLinphone = Factory::get()->createConfig(\"\");"}
    substituteInPlace CMakeLists.txt \
      --replace-fail 'include("./linphone-sdk/bctoolbox/cmake/BCToolboxCMakeUtils.cmake")' \
                     'include("${linphonePackages.bctoolbox}/share/BCToolbox/cmake/BCToolboxCMakeUtils.cmake")'
    substituteInPlace src/conference/conference-server.cc \
      --replace-fail \
        'auto configLinphone = Factory::get()->createConfig("");' \
        "$conference_resource_replacement"

    cat > cmake/LinphoneSDK.cmake <<'EOF'
    find_package(BCToolbox REQUIRED)
    find_package(Ortp REQUIRED)
    find_package(Belr REQUIRED)
    find_package(BelleSIP REQUIRED)
    find_package(Mediastreamer2 REQUIRED)
    find_package(LibLinphone REQUIRED)
    find_package(LinphoneCxx REQUIRED)
    EOF

    rm -rf flexisip
    tar xzf ${flexisipSrc}
    mv flexisip-32c1968f8c1f506101c2689a630038f0536c60dd flexisip

    substituteInPlace flexisip/CMakeLists.txt \
      --replace-fail 'include("./linphone-sdk/bctoolbox/cmake/BCToolboxCMakeUtils.cmake")' \
                     'include("${linphonePackages.bctoolbox}/share/BCToolbox/cmake/BCToolboxCMakeUtils.cmake")'

    echo '# Nix: Linphone dependencies provided by find_package.' > flexisip/cmake/LinphoneSDK.cmake
    cat ${../flexisip/nix-system-deps.cmake} >> flexisip/cmake/ExternalDependencies.cmake

    rm -rf flexisip/submodules/externals/sofia-sip
    mkdir -p flexisip/submodules/externals
    tar xzf ${sofiaSrc} -C flexisip/submodules/externals
    mv flexisip/submodules/externals/bc-sofia-sip-02b6544 flexisip/submodules/externals/sofia-sip
    test -f flexisip/submodules/externals/sofia-sip/CMakeLists.txt

    rm -rf flexisip/submodules/externals/xsd
    tar xzf ${xsdSrc} -C flexisip/submodules/externals
    mv flexisip/submodules/externals/xsd-a2ca5f3676c1139346f386648f16e95ab4f34044 flexisip/submodules/externals/xsd
    test -f flexisip/submodules/externals/xsd/libxsd/xsd/cxx/config.hxx
  '';

  NIX_CFLAGS_COMPILE = "-isystem ${libmysqlclient.dev}/include/mysql";

  cmakeFlags = [
    "-GNinja"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DFLEXISIP_CONFERENCE_VERSION=${version}"
    "-DENABLE_STRICT=OFF"
    "-DENABLE_STRICT_LINPHONESDK=OFF"
    "-DENABLE_SANITIZERS=OFF"
    "-DENABLE_UNIT_TESTS=OFF"
    "-DENABLE_SYSTEMD=ON"
    "-DENABLE_COVERAGE=OFF"
    "-DENABLE_SNMP=OFF"
    "-DENABLE_PDFDOC=OFF"
    "-DENABLE_DATEHANDLER=OFF"
    "-DENABLE_MDNS=OFF"
    "-DINTERNAL_LIBSRTP2=OFF"
    "-DINTERNAL_JSONCPP=OFF"
    "-DINTERNAL_LIBHIREDIS=OFF"
    "-DSYSCONF_INSTALL_DIR=${placeholder "out"}/etc"
    "-DbcSoci=${bc-soci}"
    "-DlibMysqlClient=${libmysqlclient}/lib/mariadb/libmysqlclient.so"
    "-DCMAKE_PREFIX_PATH=${cmakePrefixPath}"
  ];

  preBuild = ''
    export LD_LIBRARY_PATH=${lib.escapeShellArg runtimeLibPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  '';

  postInstall = ''
    mkdir -p "$out/share/belr/grammars"
    cp -rs ${linphonePackages.liblinphone}/share/* "$out/share/"
    cp -s ${linphonePackages.belle-sip}/share/belr/grammars/* "$out/share/belr/grammars/"
  '';

  postFixup = ''
    for f in "$out/bin/flexisip-conference" "$out/lib/libflexisip-conference.so" "$out/lib/libflexisip.so"; do
      if [ -f "$f" ]; then
        patchelf --add-rpath "${libmysqlclient}/lib/mariadb" "$f"
      fi
    done
  '';

  meta = {
    description = "Flexisip SIP conference and group-chat server";
    homepage = "https://gitlab.linphone.org/BC/public/flexisip-conference";
    license = lib.licenses.agpl3Plus;
    mainProgram = "flexisip-conference";
    platforms = lib.platforms.linux;
  };
}
