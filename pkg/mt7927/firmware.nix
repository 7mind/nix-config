# MT7927 / MT6639 (Filogic 380) Bluetooth firmware.
#
# WiFi blobs (WIFI_RAM_CODE_MT6639_2_1.bin, WIFI_MT6639_PATCH_MCU_2_1_hdr.bin)
# reached linux-firmware via MR !1055. Installing the Windows-ZIP copies
# here would shadow those (the firmware loader tries the uncompressed name
# first). jetm 2.14-4 stopped shipping them for that reason.
#
# The Bluetooth blob is still not in linux-firmware (MR !946 closed: vendor
# blobs only from the copyright holder). Extract it from the ASUS ZIP
# vendored in the private submodule (private/pkg/mt7927-firmware/) and
# passed in here as `driverZip`.
{
  lib,
  stdenvNoCC,
  python3,

  # Path to the ASUS driver ZIP (DRV_WiFi_MTK_MT7925_MT7927_..._V5603998_...zip),
  # imported narrowly via `builtins.path` by the caller so the firmware output
  # is keyed only on the ZIP bytes, not on the whole private submodule.
  driverZip,
}:

stdenvNoCC.mkDerivation {
  pname = "mt7927-firmware";
  version = "5603998";

  src = driverZip;

  nativeBuildInputs = [ python3 ];
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    python3 ${./extract_firmware.py} "$src" extracted
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    d="$out/lib/firmware/mediatek/mt7927"
    install -Dm644 extracted/BT_RAM_CODE_MT6639_2_1_hdr.bin \
      "$d/BT_RAM_CODE_MT6639_2_1_hdr.bin"
    runHook postInstall
  '';

  meta = {
    description = "MediaTek MT7927/MT6639 Bluetooth firmware (extracted from ASUS driver)";
    homepage = "https://github.com/jetm/mediatek-mt7927-dkms";
    # Proprietary MediaTek/ASUS firmware; user-supplied, not redistributed.
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}
