<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/dakodeon-icon-light.png">
  <img src="docs/assets/dakodeon-icon.png" alt="Dakodeon" width="88">
</picture>

# Dakodeon

**Run local models from your macOS menu bar — behind an OpenAI-compatible API.**

[![License: MIT](https://img.shields.io/badge/License-MIT-0A84FF.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)](#install)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](Package.swift)
[![Website](https://img.shields.io/badge/Website-dakodeon-30C057)](https://emin93.github.io/dakodeon/)

[Website](https://emin93.github.io/dakodeon/) · [Install](#install) · [How it works](#how-it-works) · [Develop](#development)

<br>

<img src="docs/assets/screenshot-menu.png" alt="Dakodeon menu bar panel" width="360">

</div>

---

Dakodeon is a tiny menu bar app. Pick a curated model, start the local
[`llama-server`](https://github.com/ggml-org/llama.cpp), and point any agent — OpenCode,
Zed, or your own scripts — at `http://127.0.0.1:8080/v1`.

It bundles **no runtime and no weights**. It drives the `llama.cpp` and `hf` tools already
on your machine, so the app itself stays tiny.

## Install

```sh
brew install --cask emin93/tap/dakodeon
```

> [!NOTE]
> **Requirements:** macOS 14+, with `llama-server` and `hf` on your `PATH`.
> ```sh
> brew install llama.cpp
> pip install -U "huggingface_hub[cli]"   # provides `hf`
> ```

## Features

|  |  |
| :-- | :-- |
| 🧭&nbsp; **Menu bar control** | Start/stop the server and switch models from a slim panel. |
| 📦&nbsp; **Model manager** | A Settings window shows each model's download status — download, cancel, delete, or reveal weights in Finder. |
| 🔄&nbsp; **Instant switching** | Pick a model while the server runs and it relaunches with that profile's parameters. |
| 🧹&nbsp; **Clean shutdown** | Quitting the app stops `llama-server`. |
| 🚀&nbsp; **Full context** | Every model is served at its full trained context (`-c 0`) using its own chat template (`--jinja`). |

<div align="center">
<img src="docs/assets/screenshot-settings.png" alt="Dakodeon Settings — model manager" width="480">
</div>

## How it works

Dakodeon launches `llama-server` with the selected profile and exposes the standard
OpenAI-compatible endpoints. `GET /v1/models` returns the selected profile id, such
as `gemma4-12b-it-qat` or `gemma4-31b-it-qat`.

```http
POST http://127.0.0.1:8080/v1/chat/completions
GET  http://127.0.0.1:8080/v1/models
```

Model files download to the shared Hugging Face cache via `hf`; the app resolves the
local GGUF paths and points the server at them — nothing is copied or duplicated.

## Models

Profiles are curated in code at
[`Sources/Dakodeon/Catalog.swift`](Sources/Dakodeon/Catalog.swift). Each `ModelProfile`
declares its weights, an optional draft / MTP model, and any extra `llama-server` flags.
The app exposes **no per-user configuration** — to add a model, append an entry:

```swift
ModelProfile(
  id: "gemma4-12b-it-qat",
  name: "Gemma 4 12B IT QAT",
  detail: "12B · UD-Q4_K_XL · MTP draft",
  weights: ModelAsset(repo: "unsloth/gemma-4-12B-it-qat-GGUF", file: "gemma-4-12B-it-qat-UD-Q4_K_XL.gguf", bytes: 6_716_355_328),
  draft:   ModelAsset(repo: "unsloth/gemma-4-12B-it-qat-GGUF", file: "mtp-gemma-4-12B-it.gguf", bytes: 253_707_328),
  extraArguments: ["-ngl", "999", "-fa", "on", "--spec-type", "draft-mtp", "--spec-draft-n-max", "4", "--n-gpu-layers-draft", "all"]
)
```

**Bundled today**

| Profile | Quant | Draft | Download |
| :-- | :-- | :-- | --: |
| [Gemma 4 12B IT QAT](https://huggingface.co/unsloth/gemma-4-12B-it-qat-GGUF) | UD-Q4_K_XL | MTP | 6.97 GB |
| [Gemma 4 31B IT QAT](https://huggingface.co/unsloth/gemma-4-31B-it-qat-GGUF) | UD-Q4_K_XL | MTP | 17.57 GB |

## Development

```sh
make run     # build, package, and launch the .app
make dist    # build the signed Dakodeon.app bundle
make zip     # build dist/Dakodeon.zip (release artifact)
```

### Source layout

| File | Responsibility |
| :-- | :-- |
| [`Catalog.swift`](Sources/Dakodeon/Catalog.swift) | Curated model profiles + types |
| [`ModelStore.swift`](Sources/Dakodeon/ModelStore.swift) | Download / delete / status via the `hf` cache |
| [`ServerController.swift`](Sources/Dakodeon/ServerController.swift) | `llama-server` lifecycle, switching, shutdown |
| [`MenuView.swift`](Sources/Dakodeon/MenuView.swift) | The menu bar panel |
| [`SettingsView.swift`](Sources/Dakodeon/SettingsView.swift) | Model-management window |
| [`DakodeonApp.swift`](Sources/Dakodeon/DakodeonApp.swift) | App entry, scenes, and icons |

## License

[MIT](LICENSE) for the app. Model weights remain under their own licenses — the bundled
Gemma model follows the [Gemma Terms of Use](https://ai.google.dev/gemma/terms).
