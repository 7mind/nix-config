import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const GROK_MODEL_PREFIX = "grok-";
const WEB_SEARCH_TOOL_NAME = "web_search";
const FUNCTION_TOOL_TYPE = "function";

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isClientWebSearchTool(tool: unknown): boolean {
  if (!isRecord(tool)) return false;
  if (tool.type !== FUNCTION_TOOL_TYPE) return false;
  if (tool.name === WEB_SEARCH_TOOL_NAME) return true;

  const fn = tool.function;
  return isRecord(fn) && fn.name === WEB_SEARCH_TOOL_NAME;
}

export default function dropClientWebSearchForGrok(pi: ExtensionAPI): void {
  pi.on("before_provider_request", (event) => {
    const payload = event.payload;
    if (!isRecord(payload)) return;

    const model = payload.model;
    if (typeof model !== "string" || !model.startsWith(GROK_MODEL_PREFIX)) return;

    const tools = payload.tools;
    if (!Array.isArray(tools)) return;

    const filteredTools = tools.filter((tool) => !isClientWebSearchTool(tool));
    if (filteredTools.length === tools.length) return;

    if (filteredTools.length === 0) {
      delete payload.tools;
    } else {
      payload.tools = filteredTools;
    }
  });
}
