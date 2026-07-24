# 🦙 LlamaDart Local

Run GGUF language models **directly on your phone** — no server, no Wi-Fi, no internet connection needed after setup.

Just pick a `.gguf` model file from your storage and start chatting instantly.

---

## How It Works

Your phone runs the entire model locally:

```
Your Phone
   │
   ├── Pick a .gguf model file from storage
   ├── App loads the model on-device
   └── Chat fully offline — nothing leaves your phone
```

No accounts, no cloud calls, no background data usage. Once the model is loaded, it works in airplane mode.

---

## Getting Started

1. Download a `.gguf` model file (see recommendations below) and save it to your phone.
2. Open the app and use the file picker to select the `.gguf` file.
3. Wait for the model to load.
4. Start chatting.

---

## Recommended Models by RAM

Choose a model based on how much RAM your phone has:

| Phone RAM | Recommended Model | Download Size |
|-----------|-------------------|----------------|
| 4 GB | Qwen2.5-1.5B-Instruct-Q4_K_M | ~1 GB |
| 6 GB | Phi-3-mini-4k-instruct-Q4_K_M | ~2.3 GB |
| 8 GB | Llama-3.2-3B-Instruct-Q4_K_M | ~2 GB |
| 12 GB+ | Mistral-7B-Instruct-Q4_K_M | ~4.4 GB |

**Not sure how much RAM you have?** The speed depends on how much RAM you have — start with the smallest model (Qwen2.5-1.5B) to be safe.

---

## Features

- **File picker** — load any `.gguf` model straight from your storage
- **Fully offline** — no internet required once the model is downloaded
- **Streaming responses** — see replies generate word by word, like a live conversation
- **Markdown rendering** — code blocks, bold text, and lists all display properly
- **Auto chat format detection** — automatically adapts to Llama2, Mistral, Gemma, or ChatML-style models
- **Adjustable settings** — fine-tune temperature, max tokens, top-p, repeat penalty, and CPU threads
- **Settings persist** — your preferences are saved between app launches
- **Copy messages** — long-press any message bubble to copy its text

---

## Troubleshooting

**"Failed to load model"**
- Make sure the `.gguf` file isn't corrupted — try re-downloading it
- Try a smaller model if your phone is low on RAM

**File picker shows no .gguf files**
- Check that storage permission is granted: Android Settings → Apps → LlamaDart → Permissions

**Very slow responses**
- Increase CPU Threads in Settings (try 4–6)
- Switch to a smaller or more compressed model (Q4_K_M or Q3_K_M)

**App crashes when loading a model**
- The model is likely too large for your phone's RAM
- Try Qwen2.5-1.5B-Q4_K_M (~1 GB) as a safe starting point
