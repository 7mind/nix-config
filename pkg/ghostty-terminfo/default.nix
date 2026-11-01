{ stdenv, ghostty, ghostty-bin }:
(if stdenv.hostPlatform.isDarwin then ghostty-bin else ghostty).terminfo
