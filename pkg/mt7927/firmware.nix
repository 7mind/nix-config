# MT7927 / MT6639 (Filogic 380) WiFi + Bluetooth firmware.
#
# The blobs are NOT in linux-firmware (a draft MR exists for the BT blob only).
# They must be extracted from ASUS's proprietary Windows driver ZIP, which is
# freely downloadable from any MT7927 board's support page but is not
# redistributable — so we take it via requireFile rather than fetchurl. The
# user supplies the ZIP to the store once; extract_firmware.py then carves the
# three blobs out of the `mtkwlan.dat` container deterministically.
#
# The destination paths match the `MODULE_FIRMWARE`/request_firmware() strings
# the patched mt7925e/btmtk drivers use (see patches/mt7927-wifi-07-*.patch):
#   mediatek/mt7927/WIFI_RAM_CODE_MT6639_2_1.bin       (WM)
#   mediatek/mt7927/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin  (ROM patch)
#   mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin     (Bluetooth)
{
  lib,
  stdenvNoCC,
  requireFile,
  python3,
}:

let
  # ASUS driver release V5603998 (2025-07-09). Same ZIP jetm's PKGBUILD pins.
  zipName = "DRV_WiFi_MTK_MT7925_MT7927_TP_W11_64_V5603998_20250709R.zip";
in
stdenvNoCC.mkDerivation {
  pname = "mt7927-firmware";
  version = "5603998";

  src = requireFile {
    name = zipName;
    sha256 = "b377fffa28208bb1671a0eb219c84c62fba4cd6f92161b74e4b0909476307cc8";
    message = ''
      MT7927 firmware must be extracted from ASUS's proprietary driver ZIP,
      which cannot be redistributed. It is a free public download.

      Fetch it (any MT7927 board's ZIP works — the blobs are identical), then
      add it to the Nix store:

        f=${zipName}
        url="https://cdnta.asus.com/api/v1/TokenHQ?filePath=https:%2F%2Fdlcdnta.asus.com%2Fpub%2FASUS%2Fmb%2F08WIRELESS%2F$f%3Fmodel%3DROG%2520CROSSHAIR%2520X870E%2520HERO&systemCode=rog"
        json=$(curl -sf "$url" -X POST -H 'Origin: https://rog.asus.com')
        sig=$(  jq -r .signature <<<"$json")
        exp=$(  jq -r .expires   <<<"$json")
        kid=$(  jq -r .keyPairId <<<"$json")
        curl -Lf -o "$f" "https://dlcdnta.asus.com/pub/ASUS/mb/08WIRELESS/$f?model=ROG%20CROSSHAIR%20X870E%20HERO&Signature=$sig&Expires=$exp&Key-Pair-Id=$kid"
        nix-store --add-fixed sha256 "$f"

      (Or download the "MediaTek MT7925/MT7927 WiFi driver" from your board's
      ASUS support page.) Then rebuild.
    '';
  };

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
