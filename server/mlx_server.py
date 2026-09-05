# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "mlx-whisper>=0.4.0",
#   "mlx-lm>=0.24",
#   "fastapi>=0.110",
#   "uvicorn>=0.29",
#   "python-multipart>=0.0.9",
#   "numpy",
# ]
# ///
"""
CantoType 嘅本地 MLX 伺服器（Apple Silicon）：Whisper 語音辨識 + Qwen3 文字整理，全部 MLX。

OpenAI 相容 endpoint：
  POST /v1/audio/transcriptions   multipart：file, language, prompt
  POST /v1/chat/completions       JSON：model, messages, temperature, max_tokens
  GET  /health                    {"ok", "model", "llm": {"model", "ready", "error"}}

由 CantoType app 自動啟動（uv run），亦可以手動：
  uv run server/mlx_server.py
  uv run server/mlx_server.py --model mlx-community/whisper-large-v3-mlx --llm mlx-community/Qwen3-8B-4bit
  uv run server/mlx_server.py --llm none          # 只要 Whisper

Whisper 先載入（幾秒），LLM 喺背景載入（第一次要下載約 8 GB），/health 會話你知邊個就緒。
"""
from __future__ import annotations

import argparse
import io
import os
import re
import signal
import tempfile
import threading
import time
import uuid
import wave

import numpy as np
import uvicorn
from fastapi import Body, FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
from starlette.concurrency import run_in_threadpool

import mlx_whisper

DEFAULT_WHISPER = "Huan69/whisper-large-v3-turbo-cantonese-yue-english-mlx"
DEFAULT_LLM = "mlx-community/Qwen3-14B-4bit"
DEFAULT_LANGUAGE = "yue"
# 用繁體廣東話做 initial prompt，Whisper 會傾向出繁體同口語寫法
DEFAULT_PROMPT = "以下係一段廣東話口語，用繁體中文記錄。"

app = FastAPI(title="CantoType MLX Server")

STATE = {
    "whisper_model": DEFAULT_WHISPER,
    "language": DEFAULT_LANGUAGE,
    "prompt": DEFAULT_PROMPT,
    "no_speech_threshold": 0.75,
    "llm_model": DEFAULT_LLM,
    "llm": None,
    "llm_tokenizer": None,
    "llm_ready": False,
    "llm_error": None,
}
LLM_LOCK = threading.Lock()
WHISPER_LOCK = threading.Lock()
LLMS: dict[str, tuple] = {}          # repo -> (model, tokenizer)，最多 keep 幾個畀試驗室比較
LLM_CACHE_LIMIT = 3
THINK_RE = re.compile(r"<think>[\s\S]*?</think>", re.S)


# ---------------------------------------------------------------- audio helpers

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


def normalize(audio: np.ndarray, target_peak: float = 0.7, max_gain_db: float = 30.0) -> np.ndarray:
    """細聲錄音自動增益（最多 +30 dB），大聲嘅唔郁。"""
    if audio.size == 0:
        return audio
    peak = float(np.max(np.abs(audio)))
    if peak <= 0:
        return audio
    gain = min(target_peak / peak, 10 ** (max_gain_db / 20))
    if gain <= 1.0:
        return audio
    return np.clip(audio * gain, -1.0, 1.0).astype(np.float32)


def transcribe_array(audio: np.ndarray, language: str | None, prompt: str | None, model: str | None = None) -> dict:
    """`model` 非空就用另一個 Whisper repo（模型試驗室用）；mlx_whisper 會自己換模型。"""
    with WHISPER_LOCK:
        return mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=model or STATE["whisper_model"],
            language=language or STATE["language"],
            initial_prompt=prompt if prompt is not None else STATE["prompt"],
            condition_on_previous_text=False,
            no_speech_threshold=STATE["no_speech_threshold"],
            fp16=True,
        )


# ---------------------------------------------------------------- LLM

def load_llm_background() -> None:
    model_name = STATE["llm_model"]
    if not model_name or model_name.lower() == "none":
        return

    def worker():
        try:
            from mlx_lm import generate, load
            from mlx_lm.sample_utils import make_sampler

            print(f"載入 LLM {model_name} …（第一次要下載）", flush=True)
            started = time.time()
            model, tokenizer = load(model_name)
            # warm-up
            prompt = tokenizer.apply_chat_template(
                [{"role": "user", "content": "你好"}], add_generation_prompt=True, enable_thinking=False
            )
            generate(model, tokenizer, prompt=prompt, max_tokens=4, sampler=make_sampler(temp=0.0), verbose=False)
            with LLM_LOCK:
                STATE["llm"], STATE["llm_tokenizer"] = model, tokenizer
                LLMS[model_name] = (model, tokenizer)
                STATE["llm_ready"] = True
            print(f"LLM 就緒（{time.time() - started:.1f} 秒）", flush=True)
        except Exception as exc:  # noqa: BLE001
            STATE["llm_error"] = f"{type(exc).__name__}: {exc}"
            print(f"LLM 載入失敗：{STATE['llm_error']}", flush=True)

    threading.Thread(target=worker, daemon=True, name="llm-loader").start()


def get_llm(name: str | None) -> tuple:
    """要求嘅模型未載入就即場載入（可能要下載）；預設模型永遠保留。"""
    name = (name or "").strip() or STATE["llm_model"]
    with LLM_LOCK:
        if name in LLMS:
            return LLMS[name]
    from mlx_lm import load

    print(f"載入 LLM {name} …", flush=True)
    started = time.time()
    model, tokenizer = load(name)
    print(f"LLM {name} 就緒（{time.time() - started:.1f} 秒）", flush=True)
    with LLM_LOCK:
        LLMS[name] = (model, tokenizer)
        while len(LLMS) > LLM_CACHE_LIMIT:
            victim = next((k for k in LLMS if k not in (name, STATE["llm_model"])), None)
            if victim is None:
                break
            del LLMS[victim]
    return model, tokenizer


def run_llm(messages: list[dict], temperature: float, max_tokens: int, model_name: str | None = None) -> str:
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = get_llm(model_name)
    with LLM_LOCK:
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True, enable_thinking=False)
        text = generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=make_sampler(temp=temperature),
            verbose=False,
        )
    return THINK_RE.sub("", text).strip()


# ---------------------------------------------------------------- routes

@app.get("/health")
def health():
    return {
        "ok": True,
        "model": STATE["whisper_model"],
        "language": STATE["language"],
        "llm": {
            "model": None if STATE["llm_model"].lower() == "none" else STATE["llm_model"],
            "ready": STATE["llm_ready"],
            "error": STATE["llm_error"],
            "loaded": list(LLMS.keys()),
        },
    }


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
    override = model.strip() or None

    def work() -> dict:
        try:
            audio = normalize(decode_wav(data))
            return transcribe_array(audio, language, prompt, override)
        except Exception:  # noqa: BLE001  唔係 16k WAV 就交畀 ffmpeg 解碼
            suffix = os.path.splitext(file.filename or "")[1] or ".bin"
            with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
                tmp.write(data)
                path = tmp.name
            try:
                with WHISPER_LOCK:
                    return mlx_whisper.transcribe(
                        path,
                        path_or_hf_repo=override or STATE["whisper_model"],
                        language=language or STATE["language"],
                        initial_prompt=prompt if prompt is not None else STATE["prompt"],
                        condition_on_previous_text=False,
                        no_speech_threshold=STATE["no_speech_threshold"],
                        fp16=True,
                    )
            finally:
                os.unlink(path)

    # 重工作放去 thread，event loop 先可以繼續答 /health（下載模型期間都係）
    result = await run_in_threadpool(work)

    text = (result.get("text") or "").strip()
    elapsed_ms = int((time.time() - started) * 1000)
    print(f"[asr {elapsed_ms} ms{' ' + override if override else ''}] {text}", flush=True)
    if response_format == "text":
        return PlainTextResponse(text)
    return {"text": text, "language": result.get("language"), "elapsed_ms": elapsed_ms, "model": override or STATE["whisper_model"]}


@app.post("/v1/chat/completions")
async def chat_completions(body: dict = Body(...)):
    requested = (body.get("model") or "").strip()
    uses_default = not requested or requested == STATE["llm_model"]
    if uses_default and not STATE["llm_ready"]:
        detail = STATE["llm_error"] or "LLM 仍在載入"
        return JSONResponse(status_code=503, content={"error": {"message": detail, "type": "llm_not_ready"}})
    messages = body.get("messages") or []
    temperature = float(body.get("temperature", 0.1))
    max_tokens = int(body.get("max_tokens", 1024))
    started = time.time()
    try:
        text = await run_in_threadpool(run_llm, messages, temperature, max_tokens, None if uses_default else requested)
    except Exception as exc:  # noqa: BLE001
        return JSONResponse(status_code=500, content={"error": {"message": f"{type(exc).__name__}: {exc}", "type": "llm_error"}})
    elapsed_ms = int((time.time() - started) * 1000)
    print(f"[llm {elapsed_ms} ms{'' if uses_default else ' ' + requested}] {text[:80]}", flush=True)
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": requested or STATE["llm_model"],
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        "elapsed_ms": elapsed_ms,
    }


# ---------------------------------------------------------------- main

def watch_parent(pid: int) -> None:
    """CantoType app 唔喺度就自動退出，唔會留低孤兒 process。"""

    def loop():
        while True:
            try:
                os.kill(pid, 0)
            except OSError:
                print("parent gone, exiting", flush=True)
                os._exit(0)
            time.sleep(2)

    threading.Thread(target=loop, daemon=True).start()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default=DEFAULT_WHISPER, help="Whisper MLX 模型（HF repo 或本地路徑）")
    parser.add_argument("--llm", default=DEFAULT_LLM, help="LLM MLX 模型；傳 none 就唔載入")
    parser.add_argument("--language", default=DEFAULT_LANGUAGE, help="Whisper 預設語言代碼（yue / zh / en）")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT, help="Whisper initial prompt；傳空字串可以關閉")
    parser.add_argument("--no-speech-threshold", type=float, default=0.75, help="Whisper 判斷「冇人講嘢」嘅門檻，越高越寬鬆")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--parent-pid", type=int, default=0, help="呢個 pid 消失就自動退出")
    args = parser.parse_args()

    STATE.update(
        whisper_model=args.model,
        llm_model=args.llm,
        language=args.language,
        prompt=args.prompt,
        no_speech_threshold=args.no_speech_threshold,
    )
    if args.parent_pid:
        watch_parent(args.parent_pid)
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))

    print(f"載入 Whisper {STATE['whisper_model']} …", flush=True)
    started = time.time()
    transcribe_array(np.zeros(16000, dtype=np.float32), STATE["language"], STATE["prompt"])
    print(f"Whisper 就緒（{time.time() - started:.1f} 秒）。監聽 http://{args.host}:{args.port}", flush=True)
    load_llm_background()
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
