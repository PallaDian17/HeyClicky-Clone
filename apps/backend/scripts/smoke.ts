// Hits a running backend with a real screenshot: `pnpm smoke [path/to/image.png] [question]`.
// Spends one chat call and one Realtime mint.
import { readFileSync } from "node:fs";

const base = process.env.BACKEND_URL ?? "http://localhost:8787";
const [, , imagePath, question] = process.argv;

const screenshot = imagePath ? readFileSync(imagePath).toString("base64") : undefined;
const body = {
  transcript: question ?? "What am I looking at, and where would I click to allow the microphone?",
  screenshot,
  appName: "HeyClicky Clone",
  elements: [
    { id: 1, role: "AXButton", title: "Open Settings", frame: { x: 746, y: 256, w: 220, h: 48 } },
    { id: 2, role: "AXButton", title: "Allow", frame: { x: 854, y: 644, w: 112, h: 48 } },
    { id: 3, role: "AXButton", title: "Refresh", frame: { x: 850, y: 924, w: 140, h: 48 } },
  ],
};

const chat = await fetch(`${base}/v1/chat`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
console.log("chat", chat.status, JSON.stringify(await chat.json(), null, 2));

const rt = await fetch(`${base}/v1/realtime/session`, { method: "POST" });
const grant = (await rt.json()) as Record<string, unknown>;
if (typeof grant.clientSecret === "string") grant.clientSecret = grant.clientSecret.slice(0, 6) + "…";
console.log("realtime", rt.status, JSON.stringify(grant));
