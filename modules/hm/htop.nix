{ config, lib, ... }:

{
  options = {
    smind.hm.htop.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable htop with custom layout";
    };
  };

  config = lib.mkIf config.smind.hm.htop.enable {
    programs.htop = {
      enable = true;
      settings = {
        fields = with config.lib.htop.fields; [
          PID
          USER
          PRIORITY
          NICE
          M_SIZE
          M_RESIDENT
          M_SHARE
          STATE
          PERCENT_CPU
          PERCENT_MEM
          TIME
          COMM
        ];

        sort_key = 46;
        sort_direction = 0;
        tree_sort_key = 46;
        tree_sort_direction = 0;

        hide_kernel_threads = 1;
        hide_userland_threads = 1;

        shadow_other_users = 1;
        show_thread_names = 0;
        show_program_path = 0;

        highlight_base_name = 1;
        highlight_megabytes = 1;
        highlight_threads = 1;
        highlight_changes = 1;
        highlight_changes_delay_secs = 1;

        find_comm_in_cmdline = 1;

        strip_exe_from_cmdline = 1;
        show_merged_command = 0;
        tree_view = 0;
        tree_view_always_by_pid = 0;

        header_margin = 0;
        detailed_cpu_time = 1;
        cpu_count_from_one = 1;
        show_cpu_usage = 1;
        show_cpu_frequency = 0;
        update_process_names = 0;
        account_guest_in_cpu_meter = 1;
        color_scheme = 0;
        enable_mouse = 1;
        delay = 15;
        left_meters = [ "LeftCPUs2" "Memory" "Swap" ];
        left_meter_modes = [ 1 1 1 ];
        right_meters = [ "RightCPUs2" "Tasks" "LoadAverage" "Uptime" ];
        right_meter_modes = [ 1 2 2 2 ];
        hide_function_bar = 0;

      };
    };
  };
}
