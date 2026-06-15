# Dakodeon

Dakodeon is a tiny macOS menu bar local model runner.

Dakodeon ships its supported model list in the app, launches the system `llama-server` directly, and exposes an OpenAI-compatible API at `http://127.0.0.1:8080/v1`. It does not bundle `llama.cpp`, `hf`, or model weights.

## Install

```sh
brew install --cask emin93/tap/dakodeon
```

Dakodeon assumes `llama.cpp` and `hf` are already installed on the system. `hf` is used to resolve bundled draft-model files when a model includes one.

## Supported Models

Dakodeon currently includes one bundled model:

- Gemma4-12B-Coder: `yuxinlu1/gemma-4-12B-coder-fable5-composer2.5-v1-GGUF:Q8_0`

## Development

```sh
make run
```

The release artifact is `dist/Dakodeon.zip`:

```sh
make zip
```
