{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  python3,
  git,
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
  gawk,
  patchelf,
  cpp-jwt,
  boost,
  linphonePackages,
  withB2bua ? true,
  withTranscoder ? true,
  # Presence server is required for Linphone SUBSCRIBE/PUBLISH presence.
  withPresence ? true,
  withVoicemail ? false,
  # Redis wrapper sources are referenced from the registrar path even for the
  # in-memory backend; leave ON so the symbols resolve. A live Redis server is
  # not required at runtime when the registrar is configured for memory.
  withRedis ? true,
  withSnmp ? false,
  withOpenId ? false,
  withExternalAuth ? false,
}:

let
  pythonEnv = python3.withPackages (ps: [
    ps.pystache
    ps.six
  ]);

  # Flexisip 2.6.0 submodule pin (GitLab only). Built in-tree as STATIC libs
  # and linked into libflexisip — not installed as a standalone shared library.
  sofiaSrc = ./vendor/bc-sofia-sip-02b6544.tar.gz;

  # nixpkgs bc-soci is sqlite-only; Flexisip's soci-helper always includes the
  # mysql backend header even when auth uses the file backend. Rebuild with
  # mysql so the header and plugin exist.
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
stdenv.mkDerivation rec {
  pname = "flexisip";
  version = "2.6.0";

  src = fetchFromGitHub {
    owner = "BelledonneCommunications";
    repo = "flexisip";
    rev = version;
    hash = "sha256-7q1Hj2gcbaTaQfsme6RF/cBQXUFFJYCJHsJ9XW3wY6s=";
  };

  patches = [ ./add-supported-path.patch ];

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
    jansson
    zlib
    srtp
    speex
    linphonePackages.bctoolbox
    linphonePackages.ortp
    linphonePackages.belr
    linphonePackages.belle-sip
    linphonePackages.mediastreamer2
    linphonePackages.liblinphone
    bc-soci
    linphonePackages.lime
    linphonePackages.bzrtp
    linphonePackages.belcard
    linphonePackages.bc-decaf
    libmysqlclient
    hiredis
  ]
  ++ lib.optional withOpenId cpp-jwt;

  postPatch = ''
        # BCToolbox cmake utils (bc_compute_full_version, bc_init_compilation_flags).
        substituteInPlace CMakeLists.txt \
          --replace-fail 'include("./linphone-sdk/bctoolbox/cmake/BCToolboxCMakeUtils.cmake")' \
                         'include("${linphonePackages.bctoolbox}/share/BCToolbox/cmake/BCToolboxCMakeUtils.cmake")'

        # Keep sofia-sip as an in-tree subdirectory (STATIC, linked into flexisip).
        # Drop the linphone-sdk recursive build; use nixpkgs linphonePackages instead.
        echo '# Nix: linphone stack provided via find_package (see nix-system-deps.cmake)' > cmake/LinphoneSDK.cmake
        cat ${./nix-system-deps.cmake} >> cmake/ExternalDependencies.cmake

        # Vendor the Flexisip 2.6.0 sofia-sip submodule pin. The github archive of
        # flexisip carries an empty sofia-sip submodule placeholder — replace it.
        rm -rf submodules/externals/sofia-sip
        mkdir -p submodules/externals
        tar xzf ${sofiaSrc} -C submodules/externals
        mv submodules/externals/bc-sofia-sip-02b6544 submodules/externals/sofia-sip
        test -f submodules/externals/sofia-sip/CMakeLists.txt \
          || (echo "sofia-sip vendor unpack failed" >&2; ls -la submodules/externals >&2; exit 1)

        # External libbelr only knows its own output. Register the application
        # grammar directories before Flexisip or its Linphone libraries parse.
        # Flexisip 2.6.0 expects a slightly newer liblinphone than nixpkgs 5.4.85
        # for Message Waiting Indication helpers (getNbNewUrgent, Content::clone,
        # createMessageWaitingIndicationFromContent). Short-circuit the two MWI
        # handlers; household PBX does not use MWI/voicemail.
        python3 <<'PY'
    from pathlib import Path
    import re

    p = Path("src/main/flexisip.cc")
    t = p.read_text()
    include = "#include <tclap/CmdLine.h>"
    if t.count(include) != 1:
        raise SystemExit("flexisip.cc grammar paths: TCLAP include not found exactly once")
    t = t.replace(include, """#include <belr/grammarbuilder.h>

    #include <tclap/CmdLine.h>""")
    signature = "int flexisip::main(int argc, const char* argv[]) {"
    if t.count(signature) != 1:
        raise SystemExit("flexisip.cc grammar paths: main signature not found exactly once")
    t = t.replace(signature, """int flexisip::main(int argc, const char* argv[]) {
        auto& grammarLoader = belr::GrammarLoader::get();
        grammarLoader.addPath(BELR_GRAMMARS_DIR);
        grammarLoader.addPath("${linphonePackages.belle-sip}/share/belr/grammars");
        grammarLoader.addPath("${linphonePackages.belcard}/share/belr/grammars");
        grammarLoader.addPath("${linphonePackages.liblinphone}/share/belr/grammars");""")
    p.write_text(t)

    p = Path("src/b2bua/b2bua-server.cc")
    t = p.read_text()
    # Replace function bodies between the opening brace after the signature and the matching close.
    def stub_method(src: str, signature: str) -> str:
        i = src.find(signature)
        if i < 0:
            raise SystemExit(f"b2bua-server.cc compat: signature not found:\n{signature}")
        j = src.find("{", i)
        if j < 0:
            raise SystemExit("no opening brace")
        depth = 0
        k = j
        while k < len(src):
            if src[k] == "{":
                depth += 1
            elif src[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        else:
            raise SystemExit("unbalanced braces")
        return src[: j + 1] + "\n\t// Stubbed: requires newer liblinphone MWI API than nixpkgs 5.4.85.\n" + src[k:]

    t = stub_method(t, "void B2buaServer::onMessageWaitingIndicationChanged(")
    t = stub_method(t, "void B2buaServer::onNotifyReceived(")
    p.write_text(t)
    PY
  '';

  # soci-mysql.h does `#include <mysql.h>`; mariadb-connector installs it under
  # include/mysql/.
  NIX_CFLAGS_COMPILE = "-isystem ${libmysqlclient.dev}/include/mysql";

  cmakeFlags = [
    "-GNinja"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DFLEXISIP_VERSION=${version}"
    "-DENABLE_STRICT=OFF"
    "-DENABLE_STRICT_LINPHONESDK=OFF"
    "-DENABLE_SANITIZERS=OFF"
    "-DENABLE_UNIT_TESTS=OFF"
    "-DENABLE_SYSTEMD=ON"
    "-DENABLE_PDFDOC=OFF"
    "-DENABLE_DATEHANDLER=OFF"
    "-DENABLE_MDNS=OFF"
    "-DINTERNAL_LIBSRTP2=OFF"
    "-DINTERNAL_JSONCPP=OFF"
    "-DINTERNAL_LIBHIREDIS=OFF"
    "-DENABLE_SOCI=ON"
    "-DENABLE_SOCI_POSTGRESQL_BACKEND=OFF"
    "-DENABLE_REDIS=${if withRedis then "ON" else "OFF"}"
    "-DENABLE_SNMP=${if withSnmp then "ON" else "OFF"}"
    "-DENABLE_PRESENCE=${if withPresence then "ON" else "OFF"}"
    "-DENABLE_REGEVENT=OFF"
    "-DENABLE_B2BUA=${if withB2bua then "ON" else "OFF"}"
    "-DENABLE_VOICEMAIL=${if withVoicemail then "ON" else "OFF"}"
    "-DENABLE_TRANSCODER=${if withTranscoder then "ON" else "OFF"}"
    "-DENABLE_OPENID_CONNECT=${if withOpenId then "ON" else "OFF"}"
    "-DENABLE_EXTERNAL_AUTH_PLUGIN=${if withExternalAuth then "ON" else "OFF"}"
    "-DSYSCONF_INSTALL_DIR=${placeholder "out"}/etc"
    "-DFLEXISIP_SYSTEMD_INSTALL_DIR=${placeholder "out"}/lib/systemd/system"
    "-DbcSoci=${bc-soci}"
    "-DlibMysqlClient=${libmysqlclient}/lib/mariadb/libmysqlclient.so"
    "-DCMAKE_PREFIX_PATH=${cmakePrefixPath}"
  ];

  # flexisip.conf is generated by executing the just-built binary.
  preBuild = ''
    export LD_LIBRARY_PATH=${lib.escapeShellArg runtimeLibPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  '';

  # mariadb-connector-c installs shared libs under lib/mariadb/, which the
  # default rpath scanner does not pick up.
  postFixup = ''
    for f in "$out/bin/flexisip" "$out/bin/flexisip_pusher" "$out/lib/libflexisip.so"; do
      if [ -f "$f" ]; then
        patchelf --add-rpath "${libmysqlclient}/lib/mariadb" "$f"
      fi
    done
  '';

  meta = {
    description = "Flexisip SIP proxy / B2BUA server suite (Belledonne Communications)";
    homepage = "https://www.linphone.org/en/flexisip-sip-server/";
    license = lib.licenses.agpl3Plus;
    mainProgram = "flexisip";
    platforms = lib.platforms.linux;
  };
}
