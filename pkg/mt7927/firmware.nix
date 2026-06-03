# MT7927 / MT6639 (Filogic 380) WiFi + Bluetooth firmware.
#
# The blobs are NOT in linux-firmware (a draft MR exists for the BT blob only).
# They must be extracted from ASUS's proprietary Windows driver ZIP, which is
# freely downloadable from any MT7927 board's support page but is not
# redistributable. The ZIP is vendored in the *private* submodule
# (private/pkg/mt7927-firmware/) and passed in here as `driverZip`;
# extract_firmware.py then carves the three blobs out of the `mtkwlan.dat`
# container deterministically.
#
# The destination paths match the `MODULE_FIRMWARE`/request_firmware() strings
# the patched mt7925e/btmtk drivers use (see patches/mt7927-wifi-07-*.patch):
#   mediatek/mt7927/WIFI_RAM_CODE_MT6639_2_1.bin       (WM)
#   mediatek/mt7927/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin  (ROM patch)
#   mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin     (Bluetooth)
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
    install -Dm644 extracted/BT_RAM_CODE_MT6639_2_1_hdr.bin    "$d/BT_RAM_CODE_MT6639_2_1_hdr.bin"
    install -Dm644 extracted/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin "$d/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin"
    install -Dm644 extracted/WIFI_RAM_CODE_MT6639_2_1.bin      "$d/WIFI_RAM_CODE_MT6639_2_1.bin"
    runHook postInstall
  '';

  meta = {
    description = "MediaTek MT7927/MT6639 (Filogic 380) WiFi 7 + Bluetooth firmware (extracted from ASUS driver)";
    homepage = "https://github.com/jetm/mediatek-mt7927-dkms";
    # Proprietary MediaTek/ASUS firmware; user-supplied, not redistributed.
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}
