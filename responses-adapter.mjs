#!/usr/bin/env node

import http from "node:http";
import process from "node:process";
import { once } from "node:events";

const HOST = process.env.CLAUDE_RESPONSES_ADAPTER_HOST || "127.0.0.1";
const PORT = Number(process.env.CLAUDE_RESPONSES_ADAPTER_PORT || 47827);
const UPSTREAM_BASE_URL = (process.env.RESPONSES_UPSTREAM_BASE_URL || "https://ca.memofun.net").replace(/\/$/, "");
const DEFAULT_MODEL = process.env.RESPONSES_DEFAULT_MODEL || "gpt-5.6-sol";
const VERSION = "1.0.1";
const MAX_BODY_BYTES = 64 * 1024 * 1024;

function sendJson(res, status, value, headers = {}) {
  const payload = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    ...headers,
  });
  res.end(payload);
}

function errorEnvelope(message, type = "api_error") {
  return { type: "error", error: { type, message } };
}

async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw Object.assign(new Error("Request body is too large"), { status: 413 });
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  } catch {
    throw Object.assign(new Error("Request body is not valid JSON"), { status: 400 });
  }
}

function blockText(value) {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return value == null ? "" : JSON.stringify(value);
  return value
    .map((block) => {
      if (typeof block === "string") return block;
      if (block?.type === "text" || block?.type === "input_text" || block?.type === "output_text") return block.text || "";
      if (block?.type === "image") return "[image]";
      return JSON.stringify(block);
    })
    .join("\n");
}

function systemInstructions(system) {
  if (typeof system === "string") return system;
  if (!Array.isArray(system)) return "";
  return system
    .filter((block) => block?.type === "text" || typeof block === "string")
    .map((block) => (typeof block === "string" ? block : block.text || ""))
    .join("\n\n");
}

function imagePart(block) {
  const source = block?.source || {};
  if (source.type === "base64" && source.data) {
    return { type: "input_image", image_url: `data:${source.media_type || "image/png"};base64,${source.data}` };
  }
  if (source.type === "url" && source.url) return { type: "input_image", image_url: source.url };
  return { type: "input_text", text: "[unsupported image]" };
}

function documentPart(block) {
  const source = block?.source || {};
  if (source.type === "text") return { type: "input_text", text: source.data || "" };
  if (source.type === "base64" && source.data) {
    return {
      type: "input_file",
      filename: block.title || "document.pdf",
      file_data: `data:${source.media_type || "application/pdf"};base64,${source.data}`,
    };
  }
  return { type: "input_text", text: "[unsupported document]" };
}

function callId(value) {
  const raw = String(value || `tool_${Date.now()}`).replace(/[^a-zA-Z0-9_-]/g, "_");
  return raw.startsWith("call_") ? raw : `call_${raw}`;
}

function toolOutput(content, isError) {
  const text = blockText(content);
  return isError ? `Tool error: ${text}` : text;
}

function convertMessages(messages) {
  const input = [];

  for (const message of Array.isArray(messages) ? messages : []) {
    const role = message?.role === "assistant" ? "assistant" : "user";
    const blocks = Array.isArray(message?.content)
      ? message.content
      : [{ type: "text", text: String(message?.content ?? "") }];
    let messageParts = [];

    const flush = () => {
      if (!messageParts.length) return;
      input.push({ type: "message", role, content: messageParts });
      messageParts = [];
    };

    for (const block of blocks) {
      if (typeof block === "string" || block?.type === "text") {
        messageParts.push({ type: role === "assistant" ? "output_text" : "input_text", text: typeof block === "string" ? block : block.text || "" });
        continue;
      }

      if (role === "user" && block?.type === "image") {
        messageParts.push(imagePart(block));
        continue;
      }

      if (role === "user" && block?.type === "document") {
        messageParts.push(documentPart(block));
        continue;
      }

      if (role === "assistant" && block?.type === "tool_use") {
        flush();
        input.push({
          type: "function_call",
          call_id: callId(block.id),
          name: block.name,
          arguments: JSON.stringify(block.input ?? {}),
        });
        continue;
      }

      if (role === "user" && block?.type === "tool_result") {
        flush();
        input.push({
          type: "function_call_output",
          call_id: callId(block.tool_use_id),
          output: toolOutput(block.content, block.is_error),
        });
        continue;
      }

      // Thinking/signature blocks are Anthropic-specific and cannot be replayed to Responses.
      if (block?.type === "thinking" || block?.type === "redacted_thinking") continue;

      messageParts.push({
        type: role === "assistant" ? "output_text" : "input_text",
        text: blockText(block),
      });
    }
    flush();
  }

  if (!input.length) input.push({ type: "message", role: "user", content: [{ type: "input_text", text: "" }] });
  return input;
}

function convertTools(tools) {
  return (Array.isArray(tools) ? tools : [])
    .filter((tool) => tool?.name && tool?.input_schema)
    .map((tool) => ({
      type: "function",
      name: tool.name,
      description: tool.description || "",
      parameters: tool.input_schema,
      strict: false,
    }));
}

function convertToolChoice(choice) {
  if (!choice) return "auto";
  if (typeof choice === "string") return choice;
  if (choice.type === "auto") return "auto";
  if (choice.type === "any") return "required";
  if (choice.type === "none") return "none";
  if (choice.type === "tool" && choice.name) return { type: "function", name: choice.name };
  return "auto";
}

function reasoningEffort(body) {
  const raw = body?.output_config?.effort || body?.thinking?.effort;
  if (!raw && body?.thinking?.type !== "enabled" && body?.thinking?.type !== "adaptive") return undefined;
  if (raw === "low") return "low";
  if (raw === "medium") return "medium";
  if (raw === "max" || raw === "xhigh") return "high";
  return "high";
}

function convertRequest(body) {
  const request = {
    model: body.model || DEFAULT_MODEL,
    input: convertMessages(body.messages),
    stream: body.stream !== false,
    store: false,
  };
  const instructions = systemInstructions(body.system);
  const tools = convertTools(body.tools);
  const effort = reasoningEffort(body);

  if (instructions) request.instructions = instructions;
  if (tools.length) {
    request.tools = tools;
    request.tool_choice = convertToolChoice(body.tool_choice);
    request.parallel_tool_calls = true;
  }
  if (Number.isFinite(body.max_tokens) && body.max_tokens > 0) request.max_output_tokens = Math.min(body.max_tokens, 128000);
  if (effort) request.reasoning = { effort };
  return request;
}

function usageFrom(response) {
  const usage = response?.usage || {};
  return {
    input_tokens: usage.input_tokens || 0,
    cache_creation_input_tokens: usage.input_tokens_details?.cache_write_tokens || 0,
    cache_read_input_tokens: usage.input_tokens_details?.cached_tokens || 0,
    output_tokens: usage.output_tokens || 0,
  };
}

function stopReason(response, hasTool) {
  if (hasTool) return "tool_use";
  if (response?.status === "incomplete" && response?.incomplete_details?.reason === "max_output_tokens") return "max_tokens";
  return "end_turn";
}

function convertNonStreaming(response, requestModel) {
  const content = [];
  let hasTool = false;
  for (const item of response?.output || []) {
    if (item.type === "message") {
      for (const part of item.content || []) {
        if (part.type === "output_text") content.push({ type: "text", text: part.text || "" });
        else if (part.type === "refusal") content.push({ type: "text", text: part.refusal || "" });
      }
    } else if (item.type === "function_call") {
      hasTool = true;
      let input = {};
      try { input = JSON.parse(item.arguments || "{}"); } catch { input = { raw: item.arguments || "" }; }
      content.push({ type: "tool_use", id: item.call_id || item.id, name: item.name, input });
    }
  }
  return {
    id: response.id || `msg_${Date.now()}`,
    type: "message",
    role: "assistant",
    model: response.model || requestModel,
    content,
    stop_reason: stopReason(response, hasTool),
    stop_sequence: null,
    usage: usageFrom(response),
  };
}

async function writeEvent(res, event, data) {
  if (res.writableEnded) return;
  if (!res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)) await once(res, "drain");
}

function sseEvents(stream) {
  const decoder = new TextDecoder();
  let buffer = "";
  return {
    async *[Symbol.asyncIterator]() {
      for await (const chunk of stream) {
        buffer += decoder.decode(chunk, { stream: true });
        buffer = buffer.replace(/\r\n/g, "\n");
        let boundary;
        while ((boundary = buffer.indexOf("\n\n")) !== -1) {
          const packet = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);
          let event = "message";
          const data = [];
          for (const line of packet.split("\n")) {
            if (line.startsWith("event:")) event = line.slice(6).trim();
            else if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
          }
          if (data.length) yield { event, data: data.join("\n") };
        }
      }
      buffer += decoder.decode();
      if (buffer.trim()) {
        const data = buffer.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trimStart());
        if (data.length) yield { event: "message", data: data.join("\n") };
      }
    },
  };
}

async function translateStream(upstream, res, requestModel) {
  const state = {
    started: false,
    finished: false,
    nextIndex: 0,
    blocks: new Map(),
    open: new Set(),
    hasTool: false,
    responseId: `msg_${Date.now()}`,
    model: requestModel,
  };

  const startMessage = async (response = {}) => {
    if (state.started) return;
    state.started = true;
    state.responseId = response.id || state.responseId;
    state.model = response.model || state.model;
    await writeEvent(res, "message_start", {
      type: "message_start",
      message: {
        id: state.responseId,
        type: "message",
        role: "assistant",
        model: state.model,
        content: [],
        stop_reason: null,
        stop_sequence: null,
        usage: usageFrom(response),
      },
    });
  };

  const startText = async (key) => {
    if (state.blocks.has(key)) return state.blocks.get(key);
    const index = state.nextIndex++;
    state.blocks.set(key, index);
    state.open.add(key);
    await writeEvent(res, "content_block_start", {
      type: "content_block_start",
      index,
      content_block: { type: "text", text: "" },
    });
    return index;
  };

  const startTool = async (key, item) => {
    if (state.blocks.has(key)) return state.blocks.get(key);
    const index = state.nextIndex++;
    state.blocks.set(key, index);
    state.open.add(key);
    state.hasTool = true;
    await writeEvent(res, "content_block_start", {
      type: "content_block_start",
      index,
      content_block: { type: "tool_use", id: item.call_id || item.id, name: item.name, input: {} },
    });
    return index;
  };

  const closeBlock = async (key) => {
    if (!state.open.has(key)) return;
    state.open.delete(key);
    await writeEvent(res, "content_block_stop", {
      type: "content_block_stop",
      index: state.blocks.get(key),
    });
  };

  const finish = async (response = {}, forcedReason) => {
    if (state.finished) return;
    state.finished = true;
    for (const key of [...state.open]) await closeBlock(key);
    const usage = usageFrom(response);
    await writeEvent(res, "message_delta", {
      type: "message_delta",
      delta: { stop_reason: forcedReason || stopReason(response, state.hasTool), stop_sequence: null },
      usage,
    });
    await writeEvent(res, "message_stop", { type: "message_stop" });
  };

  for await (const packet of sseEvents(upstream.body)) {
    if (packet.data === "[DONE]") {
      await startMessage();
      await finish();
      break;
    }
    let data;
    try { data = JSON.parse(packet.data); } catch { continue; }
    const type = data.type || packet.event;

    if (type === "response.created" || type === "response.in_progress") {
      await startMessage(data.response);
      continue;
    }

    await startMessage(data.response);

    if (type === "response.output_item.added" && data.item?.type === "function_call") {
      await startTool(data.item.id, data.item);
    } else if (type === "response.content_part.added" && data.part?.type === "output_text") {
      await startText(`${data.item_id}:${data.content_index}`);
    } else if (type === "response.output_text.delta") {
      const key = `${data.item_id}:${data.content_index}`;
      const index = await startText(key);
      await writeEvent(res, "content_block_delta", {
        type: "content_block_delta",
        index,
        delta: { type: "text_delta", text: data.delta || "" },
      });
    } else if (type === "response.output_text.done") {
      await closeBlock(`${data.item_id}:${data.content_index}`);
    } else if (type === "response.function_call_arguments.delta") {
      const key = data.item_id;
      let index = state.blocks.get(key);
      if (index == null) index = await startTool(key, { id: key, call_id: key, name: "tool" });
      await writeEvent(res, "content_block_delta", {
        type: "content_block_delta",
        index,
        delta: { type: "input_json_delta", partial_json: data.delta || "" },
      });
    } else if (type === "response.output_item.done" && data.item?.type === "function_call") {
      await closeBlock(data.item.id);
    } else if (type === "response.completed") {
      await finish(data.response);
      break;
    } else if (type === "response.incomplete") {
      await finish(data.response, "max_tokens");
      break;
    } else if (type === "response.failed" || type === "error") {
      const message = data.response?.error?.message || data.error?.message || data.message || "Upstream Responses request failed";
      await writeEvent(res, "error", errorEnvelope(message, "api_error"));
      state.finished = true;
      break;
    }
  }
  if (!state.finished && !res.writableEnded) {
    await startMessage();
    await finish();
  }
  res.end();
}

function upstreamAuthorization(req) {
  if (req.headers.authorization) return req.headers.authorization;
  if (req.headers["x-api-key"]) return `Bearer ${req.headers["x-api-key"]}`;
  return "";
}

async function handleMessages(req, res) {
  const authorization = upstreamAuthorization(req);
  if (!authorization) return sendJson(res, 401, errorEnvelope("Missing gateway credential", "authentication_error"));

  const anthropicBody = await readJson(req);
  const responsesBody = convertRequest(anthropicBody);
  const controller = new AbortController();
  req.on("aborted", () => controller.abort());

  let upstream;
  try {
    upstream = await fetch(`${UPSTREAM_BASE_URL}/v1/responses`, {
      method: "POST",
      headers: {
        authorization,
        "content-type": "application/json",
        "user-agent": `claude-responses-adapter/${VERSION}`,
      },
      body: JSON.stringify(responsesBody),
      signal: controller.signal,
    });
  } catch (error) {
    const message = error?.name === "AbortError" ? "Upstream request was aborted" : `Unable to reach Responses API: ${error.message}`;
    return sendJson(res, 502, errorEnvelope(message, "api_error"));
  }

  const contentType = upstream.headers.get("content-type") || "";
  if (!upstream.ok || !contentType.includes("text/event-stream") || anthropicBody.stream === false) {
    let data;
    try { data = await upstream.json(); } catch { data = { error: { message: await upstream.text() } }; }
    if (!upstream.ok || data?.error) {
      const message = data?.error?.message || `Upstream returned HTTP ${upstream.status}`;
      return sendJson(res, upstream.ok ? 400 : upstream.status, errorEnvelope(message, data?.error?.type || "api_error"));
    }
    return sendJson(res, 200, convertNonStreaming(data, responsesBody.model), {
      "request-id": upstream.headers.get("x-request-id") || data.id || "",
    });
  }

  res.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
    "x-accel-buffering": "no",
  });
  await translateStream(upstream, res, responsesBody.model);
}

async function handler(req, res) {
  const url = new URL(req.url || "/", `http://${req.headers.host || `${HOST}:${PORT}`}`);
  try {
    if (req.method === "HEAD" && url.pathname === "/") {
      res.writeHead(200).end();
    } else if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      sendJson(res, 200, { ok: true, adapter: "claude-responses-adapter", version: VERSION, upstream: UPSTREAM_BASE_URL, model: DEFAULT_MODEL });
    } else if (req.method === "GET" && url.pathname === "/v1/models") {
      sendJson(res, 200, { object: "list", data: [{ id: DEFAULT_MODEL, type: "model", display_name: DEFAULT_MODEL }] });
    } else if (req.method === "POST" && url.pathname === "/v1/messages/count_tokens") {
      const body = await readJson(req);
      const approximate = Math.max(1, Math.ceil(JSON.stringify(body).length / 4));
      sendJson(res, 200, { input_tokens: approximate });
    } else if (req.method === "POST" && url.pathname === "/v1/messages") {
      await handleMessages(req, res);
    } else {
      sendJson(res, 404, errorEnvelope(`Unsupported endpoint: ${req.method} ${url.pathname}`, "not_found_error"));
    }
  } catch (error) {
    if (!res.headersSent) sendJson(res, error.status || 500, errorEnvelope(error.message || "Internal adapter error"));
    else if (!res.writableEnded) res.end();
  }
}

const server = http.createServer(handler);
server.keepAliveTimeout = 70_000;
server.headersTimeout = 75_000;
server.requestTimeout = 0;

server.listen(PORT, HOST, () => {
  console.log(`[claude-responses-adapter] listening on http://${HOST}:${PORT}; upstream=${UPSTREAM_BASE_URL}; model=${DEFAULT_MODEL}`);
});

function shutdown(signal) {
  console.log(`[claude-responses-adapter] received ${signal}, shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
