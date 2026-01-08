[0;1;32m●[0m tuned-ppd.service - PPD-to-TuneD API Translation Daemon
     Loaded: loaded (]8;;file://pavel-fw/etc/systemd/system/tuned-ppd.service\/etc/systemd/system/tuned-ppd.service]8;;\; [0;1;32menabled[0m; preset: ignored)
    Drop-In: /nix/store/hwvxhq2ikdwpk5dfiz1n0zppk7ww77l0-system-units/tuned-ppd.service.d
             └─]8;;file://pavel-fw/nix/store/hwvxhq2ikdwpk5dfiz1n0zppk7ww77l0-system-units/tuned-ppd.service.d/overrides.conf\overrides.conf]8;;\
     Active: [0;1;32mactive (running)[0m since Thu 2026-01-08 11:47:39 GMT; 1min 46s ago
 Invocation: 6e4837c115bc4f85a2003e8504da9421
   Main PID: 158949 (.tuned-ppd-wrap)
         IP: 0B in, 0B out
         IO: 0B read, 0B written
      Tasks: 4[0;38;5;245m (limit: 57462)[0m
     Memory: 16.7M (peak: 18.7M)
        CPU: 129ms
     CGroup: /system.slice/tuned-ppd.service
             └─[0;38;5;245m158949 /nix/store/qzc04a3npl70cyyy6flnnrb2ig3kayxm-python3-3.13.11/bin/python3 -Es /nix/store/27yz632fkx200kpplxc73fkvkp83x01v-tuned-2.26.0/bin/.tuned-ppd-wrapped -l[0m

Jan 08 11:47:39 pavel-fw systemd[1]: Starting PPD-to-TuneD API Translation Daemon...
Jan 08 11:47:39 pavel-fw systemd[1]: Started PPD-to-TuneD API Translation Daemon.
