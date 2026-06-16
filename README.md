# Dakodeon

A slim macOS menu bar app that runs local models with an OpenAI-compatible API.

Pick a curated model, start the local `llama-server`, and point any agent at
`http://127.0.0.1:8080/v1`. Dakodeon does not bundle `llama.cpp`, `hf`, or model
weights — it drives the tools already on your system.

## Install

```sh
brew install --cask emin93/tap/dakodeon
```

Requires `llama.cpp` and `hf` on your PATH (macOS 14+).

## What it does

- **Menu bar control** — start/stop the server and switch models from a slim panel.
- **Model manager** — the Settings window shows each model's download status, lets you
  download or delete weights, and reveals files in Finder.
- **Instant switching** — choosing a model while the server runs stops it and relaunches
  with that profile's parameters (weights, draft/MTP model, and tuned flags).
- **Clean shutdown** — quitting the app stops the `llama-server` process.

## Models

Model profiles are curated in [`Sources/Dakodeon/Catalog.swift`](Sources/Dakodeon/Catalog.swift).
Each `ModelProfile` defines its weights, an optional draft/MTP model, and any extra
`llama-server` flags. To add a model, append an entry — there are no per-user settings.

Bundled today:

- **Gemma4 12B Coder** — `yuxinlu1/gemma-4-12B-coder-fable5-composer2.5-v1-GGUF` (Q8_0) with an MTP draft model for speculative decoding.

Every model is served at its full trained context (`-c 0`) using the model's own
chat template (`--jinja`).

## Development

```sh
make run     # build, package, and launch the .app
make zip     # build dist/Dakodeon.zip (the release artifact)
```

### Source layout

| File | Responsibility |
| --- | --- |
| `Catalog.swift` | Curated model profiles + types |
| `ModelStore.swift` | Download / delete / status via the `hf` cache |
| `ServerController.swift` | `llama-server` lifecycle, model switching, shutdown |
| `MenuView.swift` | The menu bar panel |
| `SettingsView.swift` | Model management window |
| `DakodeonApp.swift` | App entry, scenes, and icons |
