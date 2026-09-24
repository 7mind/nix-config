final: prev: {
  openlinkhub = prev.openlinkhub.overrideAttrs (old: {
    passthru = (old.passthru or { }) // {
      assets = {
        root = "${final.openlinkhub}/opt/OpenLinkHub";
        static = "${final.openlinkhub}/opt/OpenLinkHub/static";
        web = "${final.openlinkhub}/opt/OpenLinkHub/web";
        database = "${final.openlinkhub}/opt/OpenLinkHub/database";
      };
    };
  });
}
