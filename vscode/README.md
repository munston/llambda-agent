# llambda-agent

VS Code extension that opens the llambda command line against an NVIDIA model.

Each user supplies their own NVIDIA API key. When the key is missing, the extension shows **Set NVIDIA API Key**. You can also press Ctrl+Shift+P (Cmd+Shift+P on Mac) and run **llambda-agent: Set NVIDIA API Key**, then paste the key from https://build.nvidia.com. The key is stored in VS Code secret storage and is not included in this extension. The base URL and model are the `llambda-agent.baseUrl` and `llambda-agent.model` settings.

Commands:

- **llambda-agent: Open Command Line**
- **llambda-agent: NVIDIA**
