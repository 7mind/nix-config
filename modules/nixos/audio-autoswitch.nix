{ config, lib, ... }:

# Auto-switch audio to USB headsets when connected
# Works with PipeWire/WirePlumber by watching for new audio nodes
# and setting them as default when their form factor matches

let
  cfg = config.smind.audio.autoswitch;

  autoswitchScript = ''
    -- Auto-switch to USB headsets when connected
    -- Watches for new audio nodes and switches based on form factor

    local log = Log.open_topic("s-autoswitch-headset")
    local cutils = require("common-utils")

    local TARGET_FORM_FACTORS = {
      ${lib.concatMapStringsSep ",\n      " (f: ''["${f}"] = true'') cfg.formFactors}
    }

    local function get_device_form_factor(node)
      local device_id = node.properties["device.id"]
      if not device_id then
        return nil
      end

      local devices_om = cutils.get_object_manager("device")
      local device = devices_om:lookup {
        Constraint { "bound-id", "=", device_id, type = "gobject" },
      }

      if device then
        return device.properties["device.form-factor"]
      end
      return nil
    end

    local function set_default_node(metadata, node, node_type)
      local node_name = node.properties["node.name"]
      if not node_name then
        return
      end

      log:info("Setting default " .. node_type .. " to: " .. node_name)
      metadata:set(0, "default.configured." .. node_type, "Spa:String:JSON",
                   Json.Object { ["name"] = node_name }:to_string())
    end

    local function handle_new_node(node)
      local media_class = node.properties["media.class"]
      if not media_class then
        return
      end

      local form_factor = get_device_form_factor(node)
      if not form_factor or not TARGET_FORM_FACTORS[form_factor] then
        return
      end

      local node_name = node.properties["node.name"] or "unknown"
      log:info("Detected target device: " .. node_name .. " (form factor: " .. form_factor .. ")")

      local metadata_om = cutils.get_object_manager("metadata")
      local metadata = metadata_om:lookup { Constraint { "metadata.name", "=", "default" } }
      if not metadata then
        log:warning("Could not find default metadata")
        return
      end

      if media_class == "Audio/Sink" then
        set_default_node(metadata, node, "audio.sink")
      elseif media_class == "Audio/Source" then
        set_default_node(metadata, node, "audio.source")
      end
    end

    SimpleEventHook {
      name = "autoswitch-headset/node-added",
      interests = {
        EventInterest {
          Constraint { "event.type", "=", "node-added" },
          Constraint { "media.class", "c", "Audio/Sink", "Audio/Source" },
        },
      },
      execute = function(event)
        local node = event:get_subject()
        if node then
          handle_new_node(node)
        end
      end
    }:register()

    log:info("Auto-switch headset script loaded, watching for: ${lib.concatStringsSep ", " cfg.formFactors}")
  '';
in
{
  options.smind.audio.autoswitch = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable auto-switching to USB headsets when connected";
    };

    formFactors = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [
        "headset"
        "headphone"
        "speaker"
        "microphone"
        "webcam"
        "handset"
        "portable"
        "car"
        "hifi"
      ]);
      default = [ "headset" "headphone" ];
      description = "Form factors to auto-switch to when detected";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.pipewire.enable;
        message = "smind.audio.autoswitch requires PipeWire to be enabled";
      }
      {
        assertion = config.services.pipewire.wireplumber.enable;
        message = "smind.audio.autoswitch requires WirePlumber to be enabled";
      }
    ];

    services.pipewire.wireplumber.extraScripts = {
      "autoswitch-headset.lua" = autoswitchScript;
    };
  };
}
