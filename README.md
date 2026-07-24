# 🦙 LlamaDart Local — Flutter + llama_cpp_dart

Run GGUF models **directly on your device** — no server, no Termux, no Wi-Fi needed.
Pick any `.gguf` file from your storage and start chatting instantly.

---

## How it works

```
┌─────────────────────────────────────────┐
│         Flutter App (your phone)        │
│                                         │
│  File Picker → picks .gguf from storage │
│       ↓                                 │
│  llama_cpp_dart (FFI bindings)          │
│       ↓                                 │
│  libllama.so (native llama.cpp)         │
│       ↓                                 │
│  Runs model ON DEVICE, fully offline    │
└─────────────────────────────────────────┘
```

No HTTP server. No Termux. No Wi-Fi. Just the app + your GGUF file.

```

### Recommended models by RAM

| RAM  | Model | Size |
|------|-------|------|
| 4 GB | Qwen2.5-1.5B-Instruct-Q4_K_M | ~1 GB |
| 6 GB | Phi-3-mini-4k-instruct-Q4_K_M | ~2.3 GB |
| 8 GB | Llama-3.2-3B-Instruct-Q4_K_M | ~2 GB |
| 12 GB+ | Mistral-7B-Instruct-Q4_K_M | ~4.4 GB |

---

## Project Structure

```
lib/
├── main.dart                        # App entry + routing
├── models/
│   ├── app_theme.dart               # Dark theme
│   ├── chat_provider.dart           # ChangeNotifier state
├── services/
│   └── llama_service.dart           # llama_cpp_dart wrapper
├── screens/
│   ├── model_picker_screen.dart     # Pick GGUF + load model
│   ├── chat_screen.dart             # Chat UI
│   └── settings_screen.dart        # Sliders for temp, tokens, etc.
└── widgets/
    └── chat_bubble.dart             # Markdown bubbles
```

---

## Features

- **File picker** — browse and load any `.gguf` from your storage
- **Fully offline** — no internet needed after model download
- **Streaming tokens** — see response generate word by word
- **Markdown rendering** — code blocks, bold, lists all rendered
- **Auto chat format** — detects Llama2, Mistral, Gemma, ChatML automatically
- **Settings** — temperature, max tokens, top-p, repeat penalty, threads
- **Persistent settings** — saved across app launches
- **Long press to copy** — any bubble

---

## Troubleshooting

**"Failed to load model"**
→ Make sure the `.gguf` file isn't corrupted (re-download if needed)
→ Try a smaller model if you're low on RAM

**File picker shows no .gguf files**
→ Check storage permission is granted in Android Settings → Apps → LlamaDart → Permissions

**Very slow responses**
→ Increase CPU Threads in Settings (try 4-6)
→ Use a smaller/more quantized model (Q4_K_M or Q3_K_M)

**App crashes on load**
→ The model is too large for your device RAM
→ Try Qwen2.5-1.5B-Q4_K_M (~1GB) as a starting point
