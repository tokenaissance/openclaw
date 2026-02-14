import type { Command } from "commander";
import type { NodesRpcOpts } from "./types.js";
import { defaultRuntime } from "../../runtime.js";
import { getNodesTheme, runNodesCommand } from "./cli-utils.js";
import { callGatewayCli, nodesCallOpts, resolveNodeId } from "./rpc.js";

export function registerNodesPushCommand(nodes: Command) {
  nodesCallOpts(
    nodes
      .command("push")
      .description(
        "Send an APNs push notification to an iOS node (requires gateway APNs env config)",
      )
      .requiredOption("--node <idOrNameOrIp>", "Node id, name, or IP")
      .option("--title <text>", "Notification title")
      .option("--body <text>", "Notification body")
      .option("--start-talk", "Set openclaw_startTalk=true in push payload")
      .option("--agent-id <id>", "Set openclaw_agentId in push payload")
      .option("--message <text>", "Set openclaw_message in push payload")
      .action(async (opts: NodesRpcOpts) => {
        await runNodesCommand("push", async () => {
          const nodeId = await resolveNodeId(opts, String(opts.node ?? ""));
          const title = String((opts as unknown as { title?: string }).title ?? "").trim();
          const body = String((opts as unknown as { body?: string }).body ?? "").trim();
          if (!title && !body) {
            throw new Error("missing --title or --body");
          }

          const data: Record<string, unknown> = {};
          if ((opts as unknown as { startTalk?: boolean }).startTalk) {
            data.openclaw_startTalk = true;
          }
          const agentId = String((opts as unknown as { agentId?: string }).agentId ?? "").trim();
          if (agentId) {
            data.openclaw_agentId = agentId;
          }
          const message = String((opts as unknown as { message?: string }).message ?? "").trim();
          if (message) {
            data.openclaw_message = message;
          }

          const result = await callGatewayCli("node.push", opts, {
            nodeId,
            title,
            body,
            data,
          });
          if (opts.json) {
            defaultRuntime.log(JSON.stringify(result, null, 2));
            return;
          }
          const { ok } = getNodesTheme();
          defaultRuntime.log(ok("push ok"));
        });
      }),
  );
}
