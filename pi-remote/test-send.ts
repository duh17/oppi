import WebSocket from "ws";

const token = "sk_3N7002wTCTFuZFEO3F0Y0Ny7";
const sessionId = "vIRefZEm";

const ws = new WebSocket(`ws://localhost:7749/sessions/${sessionId}/stream`, {
  headers: { Authorization: `Bearer ${token}` }
});

let sentPrompt = false;

ws.on("open", () => console.log("WS open"));

ws.on("message", (data: Buffer) => {
  const msg = JSON.parse(data.toString());
  const t = new Date().toISOString().slice(11, 23);
  
  if (msg.type === "connected" || msg.type === "state") {
    console.log(`${t} <- ${msg.type} status=${msg.session?.status}`);
    if (msg.session?.status === "ready" && !sentPrompt) {
      sentPrompt = true;
      console.log(`${t} -> sending prompt...`);
      ws.send(JSON.stringify({ type: "prompt", message: "say hi in one word" }));
    }
  } else if (msg.type === "agent_start" || msg.type === "agent_end") {
    console.log(`${t} <- ${msg.type}`);
  } else if (msg.type === "text_delta") {
    process.stdout.write(msg.delta);
  } else if (msg.type === "tool_start") {
    console.log(`\n${t} <- tool_start: ${msg.tool}`);
  } else if (msg.type === "tool_end") {
    console.log(`${t} <- tool_end: ${msg.tool}`);
  } else if (msg.type === "rpc_result") {
    console.log(`${t} <- rpc_result: ${msg.command} ok=${msg.success}`);
  } else {
    console.log(`${t} <- ${msg.type}`);
  }
  
  if (msg.type === "agent_end") {
    setTimeout(() => { ws.close(); process.exit(0); }, 1000);
  }
});

ws.on("error", (err: Error) => console.error("WS error:", err.message));
ws.on("close", (code: number) => console.log(`WS closed (${code})`));
setTimeout(() => { console.log("\nTIMEOUT — no agent_end"); ws.close(); process.exit(1); }, 120000);
