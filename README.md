# OllamaKit

A powerful iOS app for running local Large Language Models (LLMs) with an OpenAI-compatible API server. Built with iOS 26 Liquid Glass design principles.

![Platform](https://img.shields.io/badge/platform-iOS%2017.0+-blue.svg)
![Swift](https://img.shields.io/badge/swift-5.9-orange.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## Features

### Core Functionality
- **Local LLM Inference** - Run GGUF format models directly on your device using llama.cpp
- **Hugging Face Integration** - Browse and download models from Hugging Face Hub
- **OpenAI-Compatible API** - Use existing OpenAI clients with your local models
- **Background Server** - Keep the API running even when the app is in background
- **Chat Interface** - Beautiful chat UI with markdown rendering and streaming responses

### Model Support
- GGUF format models (Q2_K to FP32 quantization)
- Context lengths up to 32K tokens
- GPU layer offloading for Metal performance
- Memory mapping and locking options
- Flash Attention support

### Server Features
- Configurable port (default: 11434)
- Optional API key authentication
- External network access support
- Background task management
- Full Ollama API compatibility

### iOS 26 Liquid Glass Design
- Animated mesh gradient backgrounds
- Ultra-thin material cards
- Smooth transitions and effects
- Dark mode optimized
- Haptic feedback throughout

## Screenshots

| Chat | Models | Server | Settings |
|------|--------|--------|----------|
| ![Chat](screenshots/chat.png) | ![Models](screenshots/models.png) | ![Server](screenshots/server.png) | ![Settings](screenshots/settings.png) |

## Requirements

- iOS 17.0 or later
- iPhone or iPad with A12 chip or newer (for best performance)
- At least 4GB RAM (8GB+ recommended for larger models)
- Free storage space for models (2-8GB per model)

## Installation

### Download Pre-built IPA

1. Go to the [Releases](https://github.com/yourusername/OllamaKit/releases) page
2. Download the latest `OllamaKit-unsigned.ipa`
3. Sign and install using one of the methods below

### Sign with AltStore

1. Install [AltStore](https://altstore.io) on your device
2. Download the IPA to your device
3. Open AltStore → My Apps
4. Tap the "+" button and select the IPA
5. Enter your Apple ID when prompted

### Sign with Sideloadly

1. Download and install [Sideloadly](https://sideloadly.io) on your computer
2. Connect your iOS device
3. Drag the IPA into Sideloadly
4. Enter your Apple ID credentials
5. Click "Start" to install

### Sign with TrollStore (if supported)

1. Install TrollStore on your device
2. Download the IPA
3. Share the file to TrollStore
4. The app will be installed permanently

## Building from Source

### Prerequisites

- macOS 15.0 or later
- Xcode 16.0 or later
- iOS 17.0+ SDK
- Active Apple Developer account (for device testing)

### Clone and Build

```bash
# Clone the repository
git clone https://github.com/yourusername/OllamaKit.git
cd OllamaKit

# Open in Xcode
open OllamaKit.xcodeproj

# Or build from command line
xcodebuild -project OllamaKit.xcodeproj -scheme OllamaKit -configuration Release
```

### Build Unsigned IPA

```bash
# Build archive
xcodebuild archive \
  -project OllamaKit.xcodeproj \
  -scheme OllamaKit \
  -configuration Release \
  -sdk iphoneos \
  -archivePath build/OllamaKit.xcarchive \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

# Create IPA
mkdir -p build/Payload
cp -R build/OllamaKit.xcarchive/Products/Applications/OllamaKit.app build/Payload/
cd build && zip -r OllamaKit-unsigned.ipa Payload
```

## Usage

### First Launch

1. Open OllamaKit
2. Go to the **Models** tab
3. Search for a GGUF model on Hugging Face (e.g., "Llama-2-7B-GGUF")
4. Select a quantization level (Q4_K_M recommended for balance)
5. Download the model

### Chatting

1. Go to the **Chat** tab
2. Tap the compose button to start a new chat
3. Select your downloaded model
4. Choose a system prompt or customize your own
5. Start chatting!

### Using the API Server

1. Go to the **Server** tab
2. Start the server (or enable auto-start)
3. Note the connection URL (default: `http://127.0.0.1:11434`)
4. Use with any OpenAI-compatible client:

```bash
# List models
curl http://localhost:11434/api/tags

# Generate completion
curl -X POST http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama2-7b",
    "prompt": "Why is the sky blue?"
  }'

# Chat completion
curl -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama2-7b",
    "messages": [
      {"role": "user", "content": "Hello!"}
    ]
  }'
```

### Connecting from Other Devices

1. Enable "Allow External Connections" in Server settings
2. Connect devices to the same WiFi network
3. Use the Network URL shown in the Server tab
4. Include API key in requests if authentication is enabled:

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
  http://DEVICE_IP:11434/api/tags
```

## Settings Reference

### Model Parameters
| Setting | Default | Description |
|---------|---------|-------------|
| Temperature | 0.7 | Randomness of output (0-2) |
| Top P | 0.9 | Nucleus sampling threshold |
| Top K | 40 | Top-k sampling limit |
| Repeat Penalty | 1.1 | Penalty for repetition |
| Context Length | 4096 | Maximum context tokens |
| Max Tokens | -1 | Max generation tokens (-1 = unlimited) |

### Performance Settings
| Setting | Default | Description |
|---------|---------|-------------|
| CPU Threads | Auto | Number of inference threads |
| Batch Size | 512 | Processing batch size |
| GPU Layers | 0 | Layers to offload to GPU |
| Flash Attention | Off | Enable faster attention |

### Memory Management
| Setting | Default | Description |
|---------|---------|-------------|
| Memory Mapping | On | Map model files to memory |
| Lock Memory | Off | Prevent swapping to disk |
| Keep Model Loaded | Off | Don't unload after generation |
| Auto-offload Delay | 5 min | Minutes before unloading |

## Recommended Models

### Small (2-4GB) - Good for 4GB RAM devices
- [Phi-2](https://huggingface.co/microsoft/phi-2) - 2.7B parameters
- [TinyLlama](https://huggingface.co/TinyLlama/TinyLlama-1.1B) - 1.1B parameters
- [Gemma-2B](https://huggingface.co/google/gemma-2b) - 2B parameters

### Medium (4-6GB) - Good for 6GB RAM devices
- [Llama-2-7B](https://huggingface.co/meta-llama/Llama-2-7b) - 7B parameters
- [Mistral-7B](https://huggingface.co/mistralai/Mistral-7B-v0.1) - 7B parameters
- [Zephyr-7B](https://huggingface.co/HuggingFaceH4/zephyr-7b-beta) - 7B parameters

### Large (6-8GB) - Good for 8GB+ RAM devices
- [Llama-2-13B](https://huggingface.co/meta-llama/Llama-2-13b) - 13B parameters
- [CodeLlama-13B](https://huggingface.co/codellama/CodeLlama-13b-hf) - 13B parameters

## Troubleshooting

### Model fails to load
- Check available RAM (Settings → General → iPhone Storage)
- Try a smaller model or higher quantization (Q4 vs Q8)
- Reduce context length in settings
- Enable memory mapping

### Slow generation
- Increase GPU layers (if device supports Metal)
- Reduce context length
- Use a smaller model
- Enable Flash Attention

### Server not accessible
- Check if server is running in the Server tab
- Verify port is not blocked by another app
- Try a different port number
- Check firewall settings for external connections

### App crashes
- Ensure sufficient free RAM (close other apps)
- Try a smaller model
- Reset settings to defaults
- Check iOS version compatibility

## Architecture

```
OllamaKit/
├── OllamaKit/
│   ├── OllamaKitApp.swift      # App entry point
│   ├── Views/                   # SwiftUI views
│   │   ├── ContentView.swift
│   │   ├── ChatSessionsView.swift
│   │   ├── ChatView.swift
│   │   ├── ModelsView.swift
│   │   ├── ServerView.swift
│   │   └── SettingsView.swift
│   ├── Models/                  # Data models
│   │   ├── DownloadedModel.swift
│   │   └── AppSettings.swift
│   └── Services/                # Core services
│       ├── ModelRunner.swift    # llama.cpp integration
│       ├── HuggingFaceService.swift
│       ├── ServerManager.swift  # HTTP API server
│       └── BackgroundTaskManager.swift
└── OllamaKit.xcodeproj/
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/tags` | List available models |
| POST | `/api/generate` | Generate completion |
| POST | `/api/chat` | Chat completion |
| POST | `/api/embed` | Generate embeddings |
| POST | `/api/pull` | Download model |
| DELETE | `/api/delete` | Delete model |
| GET | `/api/ps` | List running models |

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp) - The inference engine
- [Ollama](https://ollama.ai) - API inspiration
- [Hugging Face](https://huggingface.co) - Model hosting
- [SwiftUI](https://developer.apple.com/xcode/swiftui/) - UI framework

## Disclaimer

This app is not affiliated with Ollama or Hugging Face. Use at your own risk. Running large language models on mobile devices may impact battery life and device performance.

## Support

- [GitHub Issues](https://github.com/yourusername/OllamaKit/issues)
- [Discussions](https://github.com/yourusername/OllamaKit/discussions)

---

Made with ❤️ for the local AI community
