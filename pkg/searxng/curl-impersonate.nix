{ lib, curl-impersonate, fetchFromGitHub, fetchurl }:

# curl-cffi 0.17 requires browser profiles absent from nixpkgs' 2.1.1.
# Refresh component URLs/hashes from the selected upstream CMakeLists.txt.
curl-impersonate.overrideAttrs (old:
  let
    version = "2.3.2";
    src = fetchFromGitHub {
      owner = "lexiforest";
      repo = "curl-impersonate";
      tag = "v${version}";
      hash = "sha256-PVpokqvksemCMJcyFDUlARxopa+MmVhyZWVBLD5WlQ4=";
    };
    brotli = fetchurl {
      name = "brotli-1.2.1.tar.gz";
      url = "https://github.com/google/brotli/archive/refs/tags/v1.2.1.tar.gz";
      hash = "sha256-mNNdEaeNxFOuu30Qw3SPP3P/eMgmfA3Gl7hjH2e/fo8=";
    };
    zlib = fetchurl {
      url = "https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz";
      hash = "sha256-uzKaCizQJ00FUZ1hxmfAYuBpkNcuEl7i36jeZPARnRY=";
    };
    curl = fetchurl {
      url = "https://github.com/curl/curl/archive/curl-8_23_0.tar.gz";
      hash = "sha256-0GBdWIMSTvWuZMbSswfhQXxIKzYlg7V0kf3zfZqZp5I=";
    };
    cares = fetchurl {
      url = "https://github.com/c-ares/c-ares/releases/download/v1.34.9/c-ares-1.34.9.tar.gz";
      hash = "sha256-k2S3ChLrWaBoMPtIjZNX+QEA3/DZiyPqNZOhg9Q+by8=";
    };
    sources = {
      ZLIB_URL = zlib;
      ZSTD_URL = old.passthru.deps."zstd-1.5.7.tar.gz";
      BROTLI_URL = brotli;
      BORINGSSL_URL = old.passthru.deps."boringssl-156c7b75ae9b8c3b3f847acf264f17594c3859fb.zip";
      NGHTTP2_URL = old.passthru.deps."nghttp2-1.63.0.tar.bz2";
      NGTCP2_URL = old.passthru.deps."ngtcp2-1.20.0.tar.bz2";
      NGHTTP3_URL = old.passthru.deps."nghttp3-1.15.0.tar.bz2";
      CARES_URL = cares;
      CURL_URL = curl;
    };
  in
  {
    inherit version src;
    patches = [ ./curl-darwin-libidn2.patch ];
    postPatch = lib.concatStringsSep "\n" (lib.mapAttrsToList (variable: source: ''
      substituteInPlace CMakeLists.txt \
        --replace-fail ${lib.escapeShellArg "URL \"\${${variable}}\""} ${lib.escapeShellArg "URL \"file://${source}\""}
    '') sources);
    preConfigure = ''
      mkdir -p build/deps/downloads
      cp ${old.passthru.deps."libidn2-2.3.7.tar.gz"} build/deps/downloads/libidn2-2.3.7.tar.gz
    '' + old.preConfigure;
    passthru = (builtins.removeAttrs old.passthru [ "updateScript" ]) // {
      inherit src;
      deps = old.passthru.deps // {
        "brotli-1.2.1.tar.gz" = brotli;
        "zlib-1.3.2.tar.gz" = zlib;
        "curl-8_23_0.tar.gz" = curl;
        "c-ares-1.34.9.tar.gz" = cares;
      };
    };
    meta = old.meta // {
      changelog = "https://github.com/lexiforest/curl-impersonate/releases/tag/v${version}";
    };
  })
