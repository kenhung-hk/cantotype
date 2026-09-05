# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "mlx-whisper>=0.4.0",
#   "fastapi>=0.110",
#   "uvicorn>=0.29",
#   "python-multipart>=0.0.9",
#   "numpy",
# ]
# ///
"""
CantoType 嘅本地 Whisper 伺服器（Apple Silicon，用 MLX）。

OpenAI 相容 endpoint：POST /v1/audio/transcriptions（multipart：file, language, prompt）

啟動：
  uv run server/whisper_server.py
  uv run server/whisper_server.py --model mlx-community/whisper-large-v3-mlx
  uv run server/whisper_server.py --model /path/to/converted-cantonese-finetune

然後喺 CantoType 設定 → 辨識 → 揀「HTTP 伺服器」。

廣東話 fine-tune（HuggingFace 上例如 alvanlii/whisper-small-cantonese）要先轉成 MLX 格式：
  git clone https://github.com/ml-explore/mlx-examples
  cd mlx-examples/whisper
  python convert.py --torch-name-or-path alvanlii/whisper-small-cantonese --mlx-path ./cantonese-mlx --dtype float16
"""
from __future__ import annotations

import argparse
import io
import os
import tempfile
import time
import wave

import numpy as np
import uvicorn
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import PlainTextResponse

import mlx_whisper

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_LANGUAGE = "yue"
# 用繁體廣東話做 initial prompt，Whisper 會傾向出繁體同口語寫法
DEFAULT_PROMPT = "以下係一段廣東話口語，用繁體中文記錄。"

app = FastAPI(title="CantoType Whisper Server")
MODEL = DEFAULT_MODEL
LANGUAGE = DEFAULT_LANGUAGE
PROMPT = DEFAULT_PROMPT


def decode_wav(data: bytes) -> np.ndarray:
    with wave.open(io.BytesIO(data)) as w:
        if w.getsampwidth() != 2:
            raise ValueError("only 16-bit PCM supported")
        frames = w.readframes(w.getnframes())
        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
        channels = w.getnchannels()
        if channels > 1:
            audio = audio.reshape(-1, channels).mean(axis=1)
        if w.getframerate() != 16000:
            raise ValueError("expected 16 kHz")
    return audio


def transcribe_array(audio: np.ndarray, language: str | None, prompt: str | None) -> dict:
    return mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=MODEL,
        language=language or LANGUAGE,
        initial_prompt=prompt if prompt is not None else PROMPT,
        condition_on_previous_text=False,
        fp16=True,
    )


@app.get("/health")
def health():
    return {"ok": True, "model": MODEL, "language": LANGUAGE}


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form(""),
    language: str | None = Form(None),
    prompt: str | None = Form(None),
    response_format: str = Form("json"),
):
    data = await file.read()
    started = time.time()
    try:
        audio = decode_wav(data)
        result = transcribe_array(audio, language, prompt)
    except Exception:
        # 唔係 16k WAV 就交畀 ffmpeg 解碼
        suffix = os.path.splitext(file.filename or "")[1] or ".bin"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            tmp.write(data)
            path = tmp.name
        try:
            result = mlx_whisper.transcribe(
                path,
                path_or_hf_repo=MODEL,
                language=language or LANGUAGE,
                initial_prompt=prompt if prompt is not None else PROMPT,
                condition_on_previous_text=False,
                fp16=True,
            )
        finally:
            os.unlink(path)

    text = (result.get("text") or "").strip()
    elapsed_ms = int((time.time() - started) * 1000)
    print(f"[{elapsed_ms} ms] {text}", flush=True)
    if response_format == "text":
        return PlainTextResponse(text)
    return {"text": text, "language": result.get("language"), "elapsed_ms": elapsed_ms}


def main():
    global MODEL, LANGUAGE, PROMPT
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default=DEFAULT_MODEL, help="MLX 格式模型（HF repo 或本地路徑）")
    parser.add_argument("--language", default=DEFAULT_LANGUAGE, help="預設語言代碼（yue / zh / en）")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT, help="Whisper initial prompt；傳空字串可以關閉")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    MODEL, LANGUAGE, PROMPT = args.model, args.language, args.prompt

    print(f"載入模型 {MODEL} …", flush=True)
    started = time.time()
    transcribe_array(np.zeros(16000, dtype=np.float32), LANGUAGE, PROMPT)
    print(f"模型就緒（{time.time() - started:.1f} 秒）。監聽 http://{args.host}:{args.port}", flush=True)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
