const vscode = require("vscode");
const fs = require("fs");
const path = require("path");
const https = require("https");
const os = require("os");
const { execFile, spawn } = require("child_process");

const configName = "llambda-agent.config";
const secretKey = "llambda-agent.nvidiaApiKey";
const defaultBaseUrl = "https://integrate.api.nvidia.com/v1";
const defaultModel = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning";
/** @type {vscode.ExtensionContext | undefined} */
let extensionContext;

/** @type {vscode.WebviewPanel | undefined} */
let panel;
/** @type {any[]} */
let messages = [];
/** @type {import("child_process").ChildProcessWithoutNullStreams | undefined} */
let compiler;

const tools = [
  {
    type: "function",
    function: {
      name: "use_compiler",
      description: "Call this only when you decide the compiler pane should handle the request. Pass the user request as the task. The Nemotron subagent inside that session runs the compiler.",
      parameters: {
        type: "object",
        properties: { task: { type: "string" } },
        required: ["task"],
      },
    },
  },

  {
    type: "function",
    function: {
      name: "run",
      description: "Run a PowerShell command in the workspace. Use this for pwd, ls, and any other shell command.",
      parameters: {
        type: "object",
        properties: { command: { type: "string" } },
        required: ["command"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "list_dir",
      description: "List a directory inside the workspace.",
      parameters: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "read_file",
      description: "Read a text file inside the workspace.",
      parameters: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "write_file",
      description: "Write a text file inside the workspace.",
      parameters: {
        type: "object",
        properties: { path: { type: "string" }, contents: { type: "string" } },
        required: ["path", "contents"],
      },
    },
  },
];

function workspaceDir() {
  const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
  if (folder) {
    return folder.uri.fsPath;
  }
  return os.tmpdir();
}

function findConfig() {
  const folders = vscode.workspace.workspaceFolders || [];
  for (const folder of folders) {
    const candidate = path.join(folder.uri.fsPath, configName);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return undefined;
}

function filePairs() {
  const file = findConfig();
  if (!file) {
    return {};
  }
  return Object.fromEntries(
    fs
      .readFileSync(file, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#") && line.includes("="))
      .map((line) => {
        const index = line.indexOf("=");
        return [line.slice(0, index).trim(), line.slice(index + 1).trim()];
      })
  );
}

async function readConfig() {
  const settings = vscode.workspace.getConfiguration("llambda-agent");
  const fromFile = filePairs();
  const stored = extensionContext ? await extensionContext.secrets.get(secretKey) : "";
  const apiKey = (stored || fromFile["api-key"] || "").trim();
  if (!apiKey) {
    throw new Error("Set your own NVIDIA API key with llambda-agent: Set NVIDIA API Key.");
  }
  const base = settings.inspect("baseUrl");
  const model = settings.inspect("model");
  return {
    "base-url": (base && (base.workspaceValue || base.globalValue)) || fromFile["base-url"] || defaultBaseUrl,
    model: (model && (model.workspaceValue || model.globalValue)) || fromFile.model || defaultModel,
    "api-key": apiKey,
  };
}

function post(message) {
  if (panel) {
    panel.webview.postMessage(message);
  }
}

function inside(rel) {
  const root = path.resolve(workspaceDir());
  const target = path.resolve(root, rel || ".");
  const prefix = root.endsWith(path.sep) ? root : root + path.sep;
  if (target !== root && !target.startsWith(prefix)) {
    throw new Error("path escapes the workspace");
  }
  if (path.basename(target) === configName) {
    throw new Error("refusing to touch " + configName);
  }
  return target;
}

function runCommand(command) {
  return new Promise((resolve) => {
    execFile(
      "pwsh",
      ["-NoProfile", "-Command", command],
      { cwd: workspaceDir(), windowsHide: true, timeout: 60000, maxBuffer: 1024 * 1024 },
      (err, stdout, stderr) => {
        const text = [stdout, stderr, err && !stdout && !stderr ? err.message : ""]
          .filter(Boolean)
          .join("")
          .slice(0, 12000);
        resolve(text || "(no output)");
      }
    );
  });
}

async function useTool(call) {
  const args = JSON.parse(call.function.arguments || "{}");
  if (call.function.name === "run") {
    return runCommand(String(args.command || ""));
  }
  if (call.function.name === "use_compiler") {
    callsCompiler = true;
    return compilerFromUpper(String(args.task || ""));
  }
  if (call.function.name === "list_dir") {
    const names = fs.readdirSync(inside(args.path));
    return names.join("\n") || "(empty)";
  }
  if (call.function.name === "read_file") {
    return fs.readFileSync(inside(args.path), "utf8");
  }
  if (call.function.name === "write_file") {
    const file = inside(args.path);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, String(args.contents || ""), "utf8");
    return "wrote " + file;
  }
  return "unknown tool " + call.function.name;
}

function complete(cfg, messageList, toolList) {
  const body = JSON.stringify({
    model: cfg.model,
    messages: messageList || messages,
    tools: toolList || tools,
    tool_choice: "auto",
    max_tokens: 1024,
    temperature: 0,
  });
  const url = new URL(cfg["base-url"].replace(/\/$/, "") + "/chat/completions");
  return new Promise((resolve, reject) => {
    const req = https.request(
      url,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer " + cfg["api-key"],
          "Content-Type": "application/json",
          Accept: "application/json",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          if (res.statusCode !== 200) {
            reject(new Error("NVIDIA HTTP " + res.statusCode + " " + raw.slice(0, 400)));
            return;
          }
          const parsed = JSON.parse(raw);
          resolve((parsed.choices && parsed.choices[0] && parsed.choices[0].message) || {});
        });
      }
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

function injectCompiler(answer) {
  const lines = String(answer || "").split(/\r?\n/);
  for (const line of lines) {
    const match = line.match(/^\s*compiler:\s*(.*)$/i);
    if (match && match[1].trim()) {
      writeCompiler(match[1].trim());
      return;
    }
  }
}

async function askNvidia(text) {
  const cfg = await readConfig();
  const direct = /^(pwd|ls|dir|cd|Get-Location|Get-ChildItem)\b/i.test(text.trim());
  if (direct) {
    const output = await runCommand(text.trim() === "pwd" ? "Get-Location" : text.trim());
    messages.push({ role: "user", content: text });
    messages.push({ role: "assistant", content: output });
    post({ type: "out", text: output + (output.endsWith("\n") ? "" : "\n") });
    return;
  }
  messages.push({ role: "user", content: text });
  callsCompiler = false;
  for (let turn = 0; turn < 2; turn += 1) {
    const message = await complete(cfg);
    const calls = message.tool_calls || [];
    if (!calls.length) {
      const answer = message.content || "";
      messages.push({ role: "assistant", content: answer });
      post({ type: "out", text: answer + "\n" });
      if (!callsCompiler) injectCompiler(answer);
      return;
    }
    messages.push({
      role: "assistant",
      content: message.content || null,
      tool_calls: calls,
    });
    for (const call of calls) {
      let result;
      try {
        result = await useTool(call);
      } catch (err) {
        result = "error: " + err.message;
      }
      post({ type: "out", text: call.function.name + " -> " + String(result).slice(0, 500) + "\n" });
      messages.push({ role: "tool", tool_call_id: call.id, content: String(result).slice(0, 12000) });
    }
  }
  post({ type: "out", text: "stopped: too many tool turns\n" });
}

let compilerContinued = false;
let callsCompiler = false;
let compilerMessages = [];

function claudeBinary() {
  const versions = path.join(process.env.USERPROFILE || "", ".local", "share", "claude", "versions");
  if (!fs.existsSync(versions)) {
    return "";
  }
  const files = fs
    .readdirSync(versions)
    .map((name) => path.join(versions, name))
    .filter((file) => fs.statSync(file).isFile());
  files.sort();
  return files.length ? files[files.length - 1] : "";
}

function compilerEnv() {
  const binary = claudeBinary();
  const env = { ...process.env };
  if (!binary) {
    return env;
  }
  const dir = path.join(require("os").tmpdir(), "llambda-claude");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "claude.cmd"), `@echo off\r\n"${binary}" %*\r\n`, "utf8");
  env.PATH = dir + path.delimiter + (env.PATH || "");
  return env;
}

function runCompiler(args) {
  const binary = claudeBinary();
  if (!binary) {
    post({ type: "compiler", text: "Claude Code binary was not found.\n" });
    return;
  }
  if (compiler && compiler.exitCode === null) {
    compiler.kill();
  }
  const model = "qwen2.5-coder:1.5b";
  const env = compilerEnv();
  env.ANTHROPIC_BASE_URL = "http://localhost:11434";
  env.ANTHROPIC_AUTH_TOKEN = "ollama";
  delete env.ANTHROPIC_API_KEY;
  env.ANTHROPIC_DEFAULT_HAIKU_MODEL = model;
  env.ANTHROPIC_DEFAULT_SONNET_MODEL = model;
  env.ANTHROPIC_DEFAULT_OPUS_MODEL = model;
  env.CLAUDE_CODE_SUBAGENT_MODEL = model;
  env.CLAUDE_CODE_MAX_CONTEXT_TOKENS = "32768";
  post({ type: "compiler", text: binary + " " + args.join(" ") + "\n" });
  compiler = spawn(binary, args, {
    cwd: workspaceDir(),
    env,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const send = (chunk) => post({ type: "compiler", text: chunk.toString() });
  compiler.stdout.on("data", send);
  compiler.stderr.on("data", send);
  compiler.on("error", (err) => post({ type: "compiler", text: "\n" + err.message + "\n" }));
  compiler.on("exit", (code) => {
    post({ type: "compiler", text: "\n[compiler exited " + code + "]\n" });
    compiler = undefined;
  });
}

function claudeKey() {
  const key = process.env.ANTHROPIC_API_KEY || process.env.CLAUDE_API_KEY || "";
  return key.trim();
}

async function askNemotron(text) {
  const cfg = await readConfig();
  compilerMessages.push({ role: "user", content: text });
  const body = JSON.stringify({
    model: cfg.model,
    messages: [
      { role: "system", content: "You are the compiler pane. Answer the user directly." },
      ...compilerMessages,
    ],
    max_tokens: 1024,
    temperature: 0,
  });
  const url = new URL(cfg["base-url"].replace(/\/$/, "") + "/chat/completions");
  const req = https.request(
    url,
    {
      method: "POST",
      headers: {
        Authorization: "Bearer " + cfg["api-key"],
        "Content-Type": "application/json",
        Accept: "application/json",
        "Content-Length": Buffer.byteLength(body),
      },
    },
    (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        if (res.statusCode !== 200) {
          compilerMessages.pop();
          post({ type: "compiler", text: "NVIDIA HTTP " + res.statusCode + " " + raw.slice(0, 400) + "\n" });
          return;
        }
        const parsed = JSON.parse(raw);
        const message = parsed.choices && parsed.choices[0] && parsed.choices[0].message;
        const answer = (message && (message.content || message.reasoning_content)) || "";
        compilerMessages.push({ role: "assistant", content: answer });
        post({ type: "compiler", text: answer + "\n" });
      });
    }
  );
  req.on("error", (err) => {
    compilerMessages.pop();
    post({ type: "compiler", text: err.message + "\n" });
  });
  req.write(body);
  req.end();
}

async function startCompiler() {
  const binary = claudeBinary();
  if (!claudeKey()) {
    let model = defaultModel;
    try { model = (await readConfig()).model; } catch (err) { post({ type: "compiler", text: err.message + "\n" }); }
    post({ type: "compiler", text: "no Claude key, using " + model + "\n" });
    return;
  }
  post({
    type: "compiler",
    text: binary
      ? "claude " + binary + "\nollama http://localhost:11434\nmodel qwen2.5-coder:1.5b\n"
      : "claude on PATH is the Bun stub. The Claude Code binary was not found.\n",
  });
}

function writeCompiler(text) {
  const line = text.replace(/\r?\n/g, "");
  if (!line.trim()) {
    return;
  }
  if (!claudeKey()) {
    askNemotron(line).catch((err) => post({ type: "compiler", text: err.message + "\n" }));
    return;
  }
  const args = ["--model", "qwen2.5-coder:1.5b"];
  if (compilerContinued) {
    args.push("--continue");
  }
  args.push("-p", line);
  compilerContinued = true;
  runCompiler(args);
}


const runTools = [
  {
    type: "function",
    function: {
      name: "run",
      description: "Run the compiler command in PowerShell.",
      parameters: {
        type: "object",
        properties: { command: { type: "string" } },
        required: ["command"],
      },
    },
  },
];

function claudePrint(prompt, continued) {
  return new Promise((resolve) => {
    const binary = claudeBinary();
    if (!binary) {
      resolve("Claude Code binary was not found.");
      return;
    }
    const args = ["--model", "qwen2.5-coder:1.5b"];
    if (continued) args.push("--continue");
    args.push("-p", prompt);
    const env = compilerEnv();
    env.ANTHROPIC_BASE_URL = "http://localhost:11434";
    env.ANTHROPIC_AUTH_TOKEN = "ollama";
    delete env.ANTHROPIC_API_KEY;
    env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "qwen2.5-coder:1.5b";
    env.ANTHROPIC_DEFAULT_SONNET_MODEL = "qwen2.5-coder:1.5b";
    env.ANTHROPIC_DEFAULT_OPUS_MODEL = "qwen2.5-coder:1.5b";
    env.CLAUDE_CODE_SUBAGENT_MODEL = "qwen2.5-coder:1.5b";
    env.CLAUDE_CODE_MAX_CONTEXT_TOKENS = "32768";
    post({ type: "compiler", text: "claude " + args.join(" ") + "\n" });
    const child = spawn(binary, args, {
      cwd: workspaceDir(),
      env,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    const send = (chunk) => {
      const text = chunk.toString();
      out += text;
      post({ type: "compiler", text });
    };
    child.stdout.on("data", send);
    child.stderr.on("data", send);
    child.on("error", (err) => {
      out += err.message;
      post({ type: "compiler", text: err.message + "\n" });
    });
    child.on("exit", () => resolve(out));
  });
}

async function nemotronCompile(task) {
  const cfg = await readConfig();
  const thread = [
    {
      role: "system",
      content: "You are the Nemotron compiler assistant inside the Claude compiler session. You are the subagent that actually runs the compiler. Use the run tool for the build or compile command. When the compiler has finished, reply with a short result and do not call a tool.",
    },
    { role: "user", content: task },
  ];
  let summary = "";
  for (let turn = 0; turn < 2; turn += 1) {
    const message = await complete(cfg, thread, runTools);
    const calls = message.tool_calls || [];
    if (!calls.length) {
      summary = message.content || message.reasoning_content || summary;
      post({ type: "compiler", text: summary + "\n" });
      break;
    }
    thread.push({ role: "assistant", content: message.content || null, tool_calls: calls });
    for (const call of calls) {
      let result = "";
      try {
        const callArgs = JSON.parse(call.function.arguments || "{}");
        result = call.function.name === "run" ? await runCommand(String(callArgs.command || "")) : "only the run tool is available";
      } catch (err) {
        result = "error: " + err.message;
      }
      post({ type: "compiler", text: "nemotron run -> " + String(result).slice(0, 500) + "\n" });
      thread.push({ role: "tool", tool_call_id: call.id, content: String(result).slice(0, 12000) });
      summary = String(result);
    }
  }
  return summary;
}

async function compilerFromUpper(task) {
  post({ type: "compiler", text: "\nupper pane -> compiler\n" + task + "\n" });
  if (!claudeKey()) {
    post({ type: "compiler", text: "no Claude key, Nemotron compiler-assistant is running the compiler\n" });
    return nemotronCompile(task);
  }
  post({ type: "compiler", text: "Claude session\n" });
  const plan = await claudePrint("The upper pane sent this compiler task:\n" + task + "\nTell the Nemotron compiler-assistant what to compile. Keep it short.");
  post({ type: "compiler", text: "nemotron subagent\n" });
  const assistant = await nemotronCompile(task + "\nClaude said:\n" + plan);
  const finalReply = await claudePrint("The Nemotron compiler-assistant ran the compiler and reported:\n" + assistant + "\nReply to the upper pane with the compiler result.", true);
  return finalReply || assistant;
}

async function openCli() {
  if (!panel) {
    messages = [
      {
        role: "system",
        content:
          "You are a coding agent in the workspace at " +
          workspaceDir() +
          ". You can run PowerShell with the run tool, and you can list, read, and write files. When the user types a command such as pwd, call run. You decide whether the compiler pane should run. When you decide it should, write one line that starts with compiler: followed by the text to inject. That line is sent to the lower pane. Write at most one compiler: line, and do not also call use_compiler. Do not do this for ordinary chat. Prefer a direct answer over extra tool calls. Do not say you lack a filesystem. Keep edits inside the workspace. Do not read " +
          configName +
          ".",
      },
    ];
    panel = vscode.window.createWebviewPanel("llambdaCli", "lllambda", vscode.ViewColumn.Beside, {
      enableScripts: true,
      retainContextWhenHidden: true,
    });
    panel.webview.html = page();
    panel.webview.onDidReceiveMessage((message) => {
      if (!message) {
        return;
      }
      if (message.type === "line" && String(message.text || "").trim()) {
        askNvidia(String(message.text)).catch((err) => post({ type: "out", text: err.message + "\n" }));
      }
      if (message.type === "compiler") {
        writeCompiler(String(message.text || ""));
      }
    });
    panel.onDidDispose(() => {
      panel = undefined;
      messages = [];
      if (compiler) {
        compiler.kill();
        compiler = undefined;
      }
    });
    startCompiler();
  } else {
    panel.reveal(vscode.ViewColumn.Beside);
  }
  try {
    const cfg = await readConfig();
    post({ type: "out", text: "NVIDIA " + cfg.model + "\nworkspace " + workspaceDir() + "\n" });
  } catch (err) {
    post({ type: "out", text: err.message + "\n" });
  }
}

function page() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<style>
  html, body { height: 100%; }
  body { margin: 0; background: #1e1e1e; color: #d4d4d4; font: 13px Consolas, monospace; display: flex; flex-direction: column; }
  #out { white-space: pre-wrap; padding: 8px; flex: 1; overflow: auto; }
  #out .user { color: #9cdcfe; }
  #out .mark { display: block; width: fit-content; max-width: 80%; margin: 0.55em auto; padding: 0.45em 1em; text-align: center; font-size: 16px; line-height: 1.45; border-radius: 8px; background: #143044; color: #9cdcfe; border: 1px solid #3d8fb8; }
  #out .mark:nth-of-type(3n+2) { background: #3a2c14; color: #f0c674; border-color: #c4923a; }
  #out .mark:nth-of-type(3n) { background: #2c1840; color: #e0b3ff; border-color: #a56ad4; }
  form { border-top: 1px solid #333; }
  textarea, #compilerLine { box-sizing: border-box; width: 100%; min-height: 88px; max-height: 28vh; resize: vertical; background: #1e1e1e; color: #d4d4d4; border: 0; padding: 8px; font: inherit; }
  #compiler { flex: 1; min-height: 140px; display: flex; flex-direction: column; border-top: 1px solid #333; background: #111; }
  #compilerLabel { padding: 4px 8px; color: #c4923a; }
  #compilerOut { flex: 1; margin: 0; padding: 8px; overflow: auto; white-space: pre-wrap; }
  #compilerLine { min-height: 28px; max-height: 28px; resize: none; border-top: 1px solid #333; background: #111; }
</style>
</head>
<body>
<div id="out"></div>
<form id="form">
  <textarea id="line" autofocus spellcheck="false" placeholder="Type here. Enter sends. Shift+Enter adds a line."></textarea>
</form>
<section id="compiler">
  <div id="compilerLabel">compiler</div>
  <pre id="compilerOut"></pre>
  <input id="compilerLine" spellcheck="false" placeholder="compiler command" />
</section>
<script>
  const vscode = acquireVsCodeApi();
  const out = document.getElementById("out");
  const line = document.getElementById("line");
  const form = document.getElementById("form");
  const compilerOut = document.getElementById("compilerOut");
  const compilerLine = document.getElementById("compilerLine");
  function escapeHtml(value) {
    return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function formatModel(value) {
    return escapeHtml(value).replace(/\\*\\*([^*\\n]+)\\*\\*/g, "<span class=\\"mark\\">$1</span>");
  }
  function append(className, html) {
    const block = document.createElement("div");
    block.className = className;
    block.innerHTML = html;
    out.appendChild(block);
    out.scrollTop = out.scrollHeight;
  }
  function send() {
    const text = line.value;
    if (!text.trim()) return;
    append("user", escapeHtml("> " + text));
    vscode.postMessage({ type: "line", text });
    line.value = "";
  }
  function sendCompiler() {
    const text = compilerLine.value;
    compilerOut.textContent += "> " + text + "\\n";
    compilerOut.scrollTop = compilerOut.scrollHeight;
    vscode.postMessage({ type: "compiler", text });
    compilerLine.value = "";
  }
  window.addEventListener("keydown", (event) => {
    if (event.target !== line && event.target !== compilerLine) return;
    const plainEnter = (event.key === "Enter" || event.keyCode === 13) && !event.shiftKey && !event.ctrlKey && !event.altKey && !event.metaKey;
    if (plainEnter) {
      event.preventDefault();
      event.stopPropagation();
      if (event.target === compilerLine) sendCompiler();
      else send();
      return;
    }
    event.stopPropagation();
  }, true);
  line.addEventListener("beforeinput", (event) => {
    if ((event.inputType === "insertLineBreak" || event.inputType === "insertParagraph") && !event.shiftKey) {
      event.preventDefault();
    }
  });
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    send();
  });
  window.addEventListener("message", (event) => {
    if (event.data.type === "out") {
      append("model", formatModel(event.data.text));
    }
    if (event.data.type === "compiler") {
      compilerOut.textContent += event.data.text;
      compilerOut.scrollTop = compilerOut.scrollHeight;
    }
  });
  line.focus();
</script>
</body>
</html>`;
}

async function setApiKey() {
  const value = await vscode.window.showInputBox({
    title: "NVIDIA API key",
    prompt: "This key stays in VS Code secret storage for your user. It is not written into the extension.",
    password: true,
    ignoreFocusOut: true,
  });
  if (!value || !value.trim()) {
    return;
  }
  await extensionContext.secrets.store(secretKey, value.trim());
  vscode.window.showInformationMessage("NVIDIA API key saved for this user.");
}

function activate(context) {
  extensionContext = context;
  context.subscriptions.push(
    vscode.commands.registerCommand("llambda-agent.openCli", openCli),
    vscode.commands.registerCommand("llambda-agent.nvidia", openCli),
    vscode.commands.registerCommand("llambda-agent.setApiKey", setApiKey)
  );
}

function deactivate() {}

module.exports = { activate, deactivate };


