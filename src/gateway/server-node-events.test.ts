import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../infra/system-events.js", () => ({
  enqueueSystemEvent: vi.fn(),
}));
vi.mock("../infra/heartbeat-wake.js", () => ({
  requestHeartbeatNow: vi.fn(),
}));
vi.mock("../infra/device-pairing.js", () => ({
  updatePairedDeviceMetadata: vi.fn(async () => {}),
}));

import type { CliDeps } from "../cli/deps.js";
import type { HealthSummary } from "../commands/health.js";
import type { NodeEventContext } from "./server-node-events-types.js";
import { updatePairedDeviceMetadata } from "../infra/device-pairing.js";
import { requestHeartbeatNow } from "../infra/heartbeat-wake.js";
import { enqueueSystemEvent } from "../infra/system-events.js";
import { NodeRegistry } from "./node-registry.js";
import { handleNodeEvent } from "./server-node-events.js";

const enqueueSystemEventMock = vi.mocked(enqueueSystemEvent);
const requestHeartbeatNowMock = vi.mocked(requestHeartbeatNow);
const updatePairedDeviceMetadataMock = vi.mocked(updatePairedDeviceMetadata);

function buildCtx(): NodeEventContext {
  return {
    deps: {} as CliDeps,
    nodeRegistry: new NodeRegistry(),
    broadcast: () => {},
    nodeSendToSession: () => {},
    nodeSubscribe: () => {},
    nodeUnsubscribe: () => {},
    broadcastVoiceWakeChanged: () => {},
    addChatRun: () => {},
    removeChatRun: () => undefined,
    chatAbortControllers: new Map(),
    chatAbortedRuns: new Map(),
    chatRunBuffers: new Map(),
    chatDeltaSentAt: new Map(),
    dedupe: new Map(),
    agentRunSeq: new Map(),
    getHealthCache: () => null,
    refreshHealthSnapshot: async () => ({}) as HealthSummary,
    loadGatewayModelCatalog: async () => [],
    logGateway: { warn: () => {} },
  };
}

function seedConnectedNode(ctx: NodeEventContext, nodeId: string) {
  // NodeRegistry only tracks metadata for connected nodes. For this unit test,
  // seed a minimal session entry without needing a real websocket client.
  const reg = ctx.nodeRegistry as unknown as { nodesById: Map<string, unknown> };
  reg.nodesById.set(nodeId, {
    nodeId,
    connId: "test-conn",
    client: {} as unknown,
    caps: [],
    commands: [],
    connectedAtMs: Date.now(),
  });
}

describe("node exec events", () => {
  beforeEach(() => {
    enqueueSystemEventMock.mockReset();
    requestHeartbeatNowMock.mockReset();
    updatePairedDeviceMetadataMock.mockReset();
  });

  it("enqueues exec.started events", async () => {
    const ctx = buildCtx();
    await handleNodeEvent(ctx, "node-1", {
      event: "exec.started",
      payloadJSON: JSON.stringify({
        sessionKey: "agent:main:main",
        runId: "run-1",
        command: "ls -la",
      }),
    });

    expect(enqueueSystemEventMock).toHaveBeenCalledWith(
      "Exec started (node=node-1 id=run-1): ls -la",
      { sessionKey: "agent:main:main", contextKey: "exec:run-1" },
    );
    expect(requestHeartbeatNowMock).toHaveBeenCalledWith({ reason: "exec-event" });
  });

  it("enqueues exec.finished events with output", async () => {
    const ctx = buildCtx();
    await handleNodeEvent(ctx, "node-2", {
      event: "exec.finished",
      payloadJSON: JSON.stringify({
        runId: "run-2",
        exitCode: 0,
        timedOut: false,
        output: "done",
      }),
    });

    expect(enqueueSystemEventMock).toHaveBeenCalledWith(
      "Exec finished (node=node-2 id=run-2, code 0)\ndone",
      { sessionKey: "node-node-2", contextKey: "exec:run-2" },
    );
    expect(requestHeartbeatNowMock).toHaveBeenCalledWith({ reason: "exec-event" });
  });

  it("enqueues exec.denied events with reason", async () => {
    const ctx = buildCtx();
    await handleNodeEvent(ctx, "node-3", {
      event: "exec.denied",
      payloadJSON: JSON.stringify({
        sessionKey: "agent:demo:main",
        runId: "run-3",
        command: "rm -rf /",
        reason: "allowlist-miss",
      }),
    });

    expect(enqueueSystemEventMock).toHaveBeenCalledWith(
      "Exec denied (node=node-3 id=run-3, allowlist-miss): rm -rf /",
      { sessionKey: "agent:demo:main", contextKey: "exec:run-3" },
    );
    expect(requestHeartbeatNowMock).toHaveBeenCalledWith({ reason: "exec-event" });
  });
});

describe("node lifecycle/location/push metadata", () => {
  beforeEach(() => {
    updatePairedDeviceMetadataMock.mockReset();
  });

  it("persists node.lifecycle into nodeRegistry and pairing store", async () => {
    const ctx = buildCtx();
    seedConnectedNode(ctx, "ios-node-1");
    await handleNodeEvent(ctx, "ios-node-1", {
      event: "node.lifecycle",
      payloadJSON: JSON.stringify({ state: "backgrounding", reason: "scenePhase.background" }),
    });
    const session = ctx.nodeRegistry.get("ios-node-1");
    expect(session?.lifecycle?.state).toBe("backgrounding");
    expect(updatePairedDeviceMetadataMock).toHaveBeenCalledWith(
      "ios-node-1",
      expect.objectContaining({
        lifecycle: expect.objectContaining({ state: "backgrounding" }),
      }),
    );
  });

  it("persists node.location into nodeRegistry and pairing store", async () => {
    const ctx = buildCtx();
    seedConnectedNode(ctx, "ios-node-2");
    await handleNodeEvent(ctx, "ios-node-2", {
      event: "node.location",
      payloadJSON: JSON.stringify({ lat: 1.23, lon: 4.56, accuracyM: 10, tsMs: 123 }),
    });
    const session = ctx.nodeRegistry.get("ios-node-2");
    expect(session?.lastLocation?.lat).toBe(1.23);
    expect(updatePairedDeviceMetadataMock).toHaveBeenCalledWith(
      "ios-node-2",
      expect.objectContaining({
        lastLocation: expect.objectContaining({ lat: 1.23, lon: 4.56 }),
      }),
    );
  });

  it("persists push.apnsToken into nodeRegistry and pairing store", async () => {
    const ctx = buildCtx();
    seedConnectedNode(ctx, "ios-node-3");
    await handleNodeEvent(ctx, "ios-node-3", {
      event: "push.apnsToken",
      payloadJSON: JSON.stringify({ token: "deadbeef" }),
    });
    const session = ctx.nodeRegistry.get("ios-node-3");
    expect(session?.push?.apns).toBe("deadbeef");
    expect(updatePairedDeviceMetadataMock).toHaveBeenCalledWith(
      "ios-node-3",
      expect.objectContaining({
        push: expect.objectContaining({ apns: "deadbeef" }),
      }),
    );
  });
});
