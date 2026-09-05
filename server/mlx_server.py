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
import json
import logging
import logging.handlers
import os
import re
import signal
import sys
import tempfile
import threading
import time
import traceback
import uuid
import wave

import numpy as np
import uvicorn
from fastapi import Body, FastAPI, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
from starlette.concurrency import run_in_threadpool

import mlx_whisper

DEFAULT_WHISPER = "Huan69/whisper-large-v3-turbo-cantonese-yue-english-mlx-int8"
DEFAULT_LLM = "mlx-community/Qwen3-8B-4bit"
DEFAULT_LANGUAGE = "yue"
# 用繁體廣東話做 initial prompt，Whisper 會傾向出繁體同口語寫法
DEFAULT_PROMPT = "以下係一段廣東話口語，用繁體中文記錄。"

app = FastAPI(title="CantoType MLX Server")
API_TOKEN = ""  # --token 設定咗先會檢查；Tailscale 已經係私人網絡，token 係多一重保險


def is_loopback(request: Request) -> bool:
    host = (request.client.host if request.client else "") or ""
    return host in ("127.0.0.1", "::1", "localhost") or host.startswith("::ffff:127.")


@app.middleware("http")
async def require_token(request: Request, call_next):
    # token 只係用嚟保護遠端（Tailscale／局域網）連入；本機嘅 Mac app 唔使帶 token
    if API_TOKEN and request.url.path != "/health" and not is_loopback(request):
        header = request.headers.get("authorization", "")
        query = request.query_params.get("token", "")
        if header != f"Bearer {API_TOKEN}" and query != API_TOKEN:
            log.warning("401 %s from %s (auth header %s)", request.url.path, request.client.host if request.client else "?", "present" if header else "missing")
            return JSONResponse(status_code=401, content={"error": {"message": "token 唔對", "type": "unauthorized"}})
    return await call_next(request)

STATE = {
    "whisper_model": DEFAULT_WHISPER,
    "language": DEFAULT_LANGUAGE,
    "prompt": DEFAULT_PROMPT,
    "no_speech_threshold": 0.75,
    # 解碼策略：先 greedy；只有出現重複迴圈（compression ratio 高）先升溫重試。
    # 唔會因為信心低（avg_logprob）而升溫——呢個 fine-tune 對正常廣東話都會報低信心，
    # 升溫出嚟就係「該Est補lang戰鬆…」呢類亂碼。greedy 模式就連重複都唔重試。
    "temperature": (0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
    "llm_model": DEFAULT_LLM,
    "llm": None,
    "llm_tokenizer": None,
    "llm_ready": False,
    "llm_error": None,
}
LLM_LOCK = threading.Lock()
# Whisper 同 LLM 共用一個 lock：MLX／Metal 唔好由兩條 thread 同時落 command
WHISPER_LOCK = LLM_LOCK
LLMS: dict[str, tuple] = {}          # repo -> (model, tokenizer)，最多 keep 幾個畀試驗室比較
LLM_CACHE_LIMIT = 3

LOG_DIR = os.path.expanduser("~/Library/Logs/CantoType")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_PATH = os.path.join(LOG_DIR, "mlx-server.log")
log = logging.getLogger("cantotype")
log.setLevel(logging.INFO)
_handler = logging.handlers.RotatingFileHandler(LOG_PATH, maxBytes=2_000_000, backupCount=3, encoding="utf-8")
_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
log.addHandler(_handler)


_STDOUT_BROKEN = False


def safe_print(message: str) -> None:
    """stdout 係 app 嘅 pipe；app 死咗 pipe 就斷，print 會 BrokenPipeError（之前就係咁令所有 request 500）。"""
    global _STDOUT_BROKEN
    if _STDOUT_BROKEN:
        return
    try:
        print(message, flush=True)
    except (BrokenPipeError, OSError, ValueError):
        _STDOUT_BROKEN = True
        try:
            devnull = open(os.devnull, "w")
            sys.stdout = devnull
            sys.stderr = devnull
        except OSError:
            pass


def say(message: str) -> None:
    """同時印去 stdout（app 會收）同寫入 ~/Library/Logs/CantoType/mlx-server.log。"""
    log.info(message)
    safe_print(message)


@app.exception_handler(Exception)
async def unhandled_exception(request: Request, exc: Exception):
    tb = traceback.format_exc()
    log.error("unhandled error on %s %s\n%s", request.method, request.url.path, tb)
    safe_print(f"[error] {request.url.path}: {type(exc).__name__}: {exc}")
    return JSONResponse(
        status_code=500,
        content={"error": {"message": f"{type(exc).__name__}: {exc}", "type": "server_error", "log": LOG_PATH}},
    )
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


def looks_garbled(text: str) -> bool:
    """prompt 唔啱時 Whisper 會出 U+FFFD 或者同一個字重複十幾次。"""
    return "\ufffd" in text or re.search(r"(.)\1{4,}", text) is not None


NO_PROMPT = object()


def transcribe_array(audio: np.ndarray, language: str | None, prompt, model: str | None = None) -> dict:
    """`model` 非空就用另一個 Whisper repo（模型試驗室用）；mlx_whisper 會自己換模型。

    `prompt`：None → 伺服器預設句；NO_PROMPT → 完全唔用 prompt；其他 → 該字串。
    解碼：greedy 為主，只有重複迴圈先升溫（見 STATE["temperature"] 註解）；唔會因為「冇人講嘢」機率高而丟走
    段落（用戶係按住快捷鍵先錄，一定有人講嘢）。
    語言：large-v3 之前嘅 Whisper（vocab 51865）冇 "yue" token，用 yue 會掟 ValueError；呢類模型自動改用 zh。
    """
    if prompt is NO_PROMPT:
        initial_prompt = None
    elif prompt is None or not str(prompt).strip():
        initial_prompt = STATE["prompt"] or None
    else:
        initial_prompt = str(prompt)
    lang = language or STATE["language"]
    with WHISPER_LOCK:
        try:
            result = _transcribe(audio, lang, initial_prompt, model)
        except ValueError as exc:
            if lang == "yue" and "not in tuple" in str(exc):
                result = _transcribe(audio, "zh", initial_prompt, model)
                result["language_used"] = "zh"
            else:
                raise
    result.setdefault("language_used", lang)
    return result


def _transcribe(audio: np.ndarray, language: str, initial_prompt: str | None, model: str | None) -> dict:
    return mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=model or STATE["whisper_model"],
        language=language,
        initial_prompt=initial_prompt,
        condition_on_previous_text=False,
        no_speech_threshold=None,
        logprob_threshold=None,
        compression_ratio_threshold=2.4,
        temperature=STATE["temperature"],
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

            say(f"載入 LLM {model_name} …（第一次要下載）")
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
            say(f"LLM 就緒（{time.time() - started:.1f} 秒）")
        except Exception as exc:  # noqa: BLE001
            STATE["llm_error"] = f"{type(exc).__name__}: {exc}"
            log.error("LLM load failed\n%s", traceback.format_exc())
            say(f"LLM 載入失敗：{STATE['llm_error']}")

    threading.Thread(target=worker, daemon=True, name="llm-loader").start()


def get_llm(name: str | None) -> tuple:
    """要求嘅模型未載入就即場載入（可能要下載）；預設模型永遠保留。"""
    name = (name or "").strip() or STATE["llm_model"]
    with LLM_LOCK:
        if name in LLMS:
            return LLMS[name]
    from mlx_lm import load

    say(f"載入 LLM {name} …")
    started = time.time()
    model, tokenizer = load(name)
    say(f"LLM {name} 就緒（{time.time() - started:.1f} 秒）")
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
        "pid": os.getpid(),
        "parent_pid": STATE.get("parent_pid", 0),
        "host": STATE.get("host", "127.0.0.1"),
        "token_required": bool(API_TOKEN),
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
            result = transcribe_array(audio, language, prompt, override)
            # prompt 太長／太怪會令 Whisper 完全唔出字或者出亂碼；逐級退：自訂 prompt → 預設短句 → 完全冇 prompt
            has_speech = float(np.abs(audio).mean()) > 1e-4
            ladder = []
            if prompt and prompt.strip():
                ladder.append(("default prompt", None))
            ladder.append(("no prompt", NO_PROMPT))
            for label, fallback in ladder:
                text = (result.get("text") or "").strip()
                if not has_speech or (text and not looks_garbled(text)):
                    break
                say(f"[asr] {'empty' if not text else 'garbled'} output, retrying with {label}")
                result = transcribe_array(audio, language, fallback, override)
                result["prompt_dropped"] = True
            return result
        except Exception:  # noqa: BLE001  唔係 16k WAV 就交畀 ffmpeg 解碼
            suffix = os.path.splitext(file.filename or "")[1] or ".bin"
            with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
                tmp.write(data)
                path = tmp.name
            try:
                import mlx_whisper.audio as whisper_audio

                decoded = whisper_audio.load_audio(path)
                return transcribe_array(normalize(np.asarray(decoded, dtype=np.float32)), language, prompt, override)
            finally:
                os.unlink(path)

    # 重工作放去 thread，event loop 先可以繼續答 /health（下載模型期間都係）
    result = await run_in_threadpool(work)

    text = (result.get("text") or "").strip()
    elapsed_ms = int((time.time() - started) * 1000)
    say(f"[asr {elapsed_ms} ms{' ' + override if override else ''}] {text}")
    if response_format == "text":
        return PlainTextResponse(text)
    return {"text": text, "language": result.get("language_used") or result.get("language"), "elapsed_ms": elapsed_ms, "model": override or STATE["whisper_model"], "prompt_dropped": bool(result.get("prompt_dropped"))}


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
        log.error("LLM request failed\n%s", traceback.format_exc())
        safe_print(f"[error] llm: {type(exc).__name__}: {exc}")
        return JSONResponse(status_code=500, content={"error": {"message": f"{type(exc).__name__}: {exc}", "type": "llm_error", "log": LOG_PATH}})
    elapsed_ms = int((time.time() - started) * 1000)
    say(f"[llm {elapsed_ms} ms{'' if uses_default else ' ' + requested}] {text[:80]}")
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": requested or STATE["llm_model"],
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        "elapsed_ms": elapsed_ms,
    }


# ---------------------------------------------------------------- 整理 prompt（同 Swift Prompts.system 保持一致）

DEFAULT_SPEAKER_CONTEXT = "香港嘅 full stack developer，日常講廣東話夾雜英文技術用語（GitHub、API、Kubernetes、SQL、deploy 等），會提到公司同 project 名。"

TECH_RULE = ("8. 英文技術詞語一律用標準寫法同大小寫，唔要翻譯成中文。辨識結果如果將英文詞聽錯成讀音相近嘅字，要改返做正確英文詞，例如："
             "get hub→GitHub、sequel→SQL、post gres→PostgreSQL、Q 班／cube→Kubernetes、派森→Python、多卡→Docker、A P I→API、J son→JSON、red is→Redis；"
             "講開 GitHub／code 嘅時候，report／Vebok／理 po→repo、P R→PR、common／卡米→commit、bran／班→branch；威迫／vibe 曲→vibe code、威迫 coding→vibe coding、ng run／N G run→ng run（Angular CLI）、stable／tail scale／tail sale→Tailscale、Kithub／Gitub→GitHub、bond alert／bot 阿 lert→bot alert、summer review→summary review、K8s／k 8 s→k8s。")

COMMON_RULES = [
    "2. 刪除口頭填充詞（呃、嗯、啊、即係、咁、然後、就係、hmm、like 等），保留有實際意思嘅字。",
    "3. 加上正確嘅中文標點（，。？！、「」），英文詞語保留英文原樣。",
    "4. 修正明顯嘅同音錯字或辨識錯誤，但唔要改變原意；唔確定就保留原文。",
    "5. 唔要回答內容、唔要補充、唔要解釋、唔要加標題、唔要續寫；就算原文係一個問題或者只有幾個字，都唔要答、唔要延伸，輸出長度要同原文差唔多。",
    "6. 如果用戶講「新一行」、「另起一段」、「換行」，用換行代替呢幾個字。",
    "7. 只輸出整理後嘅文字，唔要有任何前言後語。",
]


def system_prompt(mode: str, vocabulary: list[str], speaker_context: str | None = None, tech_correction: bool = True) -> str:
    lines: list[str] = []
    context = (DEFAULT_SPEAKER_CONTEXT if speaker_context is None else speaker_context).strip()
    # 改寫模式唔放講者背景：Gemma 見到「日常講廣東話」會將英文原文譯成廣東話
    if context and mode != "rephrase":
        lines += [f"講者背景：{context}", ""]
    if mode == "rephrase":
        lines += [
            "你係一個文字改寫助手。用戶會俾你一段文字（可能係廣東話、英文或者中英夾雜），請將佢改寫得更清楚、自然、通順。",
            "",
            "規則：",
            "1. 保留原意、語氣同語言，絕對唔要翻譯：原文係英文就輸出英文，係廣東話口語就保持廣東話口語，中英夾雜就照樣夾雜。",
            "2. 修正錯字、語法同標點；句子可以重組，但唔要加新內容、唔要刪走重點。",
            "3. 唔要回答或者評論內容，唔要加標題、前言後語。",
            "4. 只輸出改寫後嘅文字。",
        ]
    elif mode == "written":
        lines += [
            "你係一個語音輸入嘅文字整理器。用戶用廣東話講嘢，語音辨識會轉成文字。你嘅任務：將廣東話口語嘅辨識結果，改寫成自然流暢嘅繁體書面中文，令佢可以直接貼上使用。",
            "", "例子：", "輸入：呃 我今日唔得閒 即係 你哋自己搞掂佢先啦 然後 聽日再同我講", "輸出：我今天沒有空，你們先自己處理吧，明天再告訴我。", "", "規則：",
            "1. 一定要轉成書面中文，唔可以保留廣東話口語字：唔→不、係→是、嘅→的、佢→他／她／它、喺→在、咩→什麼、點解→為什麼、我哋→我們、你哋→你們、冇→沒有、啲→一些、得閒→有空、搞掂→處理好、俾／畀→給、睇→看、講→說、聽日→明天、今日→今天、下晝→下午、返工→上班、識得→懂得、幫我記低→幫我記下。",
        ] + COMMON_RULES
    else:
        lines += [
            "你係一個語音輸入嘅文字整理器。用戶用廣東話講嘢，語音辨識會轉成文字。你嘅任務：將辨識結果整理成乾淨、可以直接貼上使用嘅文字，但保留廣東話口語寫法。",
            "", "例子：", "輸入：呃 我今日唔得閒 即係 你哋自己搞掂佢先啦 然後 聽日再同我講", "輸出：我今日唔得閒，你哋自己搞掂佢先啦，聽日再同我講。", "", "規則：",
            "1. 保留廣東話口語用字（唔、係、嘅、咩、喺、佢、點解、我哋），唔要轉做書面語。",
        ] + COMMON_RULES
    if tech_correction and mode != "rephrase":
        lines.append(TECH_RULE)
    if vocabulary:
        lines += ["", "用戶常用嘅專有名詞（人名、公司、project 名）。辨識結果如果有讀音相近但寫法唔同嘅字詞，請改用呢啲寫法：" + "、".join(vocabulary)]
    return "\n".join(lines)


def normalize_input(text: str) -> str:
    """同 Swift InputNormalizer：K M→KM，中英之間加空格。"""
    text = re.sub(r"(?<![A-Za-z])[A-Z](?: [A-Za-z])+(?![A-Za-z])", lambda m: m.group(0).replace(" ", ""), text)
    text = re.sub(r"(?<=[A-Za-z0-9])(?=[\u4e00-\u9fff])", " ", text)
    text = re.sub(r"(?<=[\u4e00-\u9fff])(?=[A-Za-z0-9])", " ", text)
    return text


def sanitize_llm(text: str, original: str) -> str:
    text = THINK_RE.sub("", text).strip()
    if text.startswith("```"):
        parts = text.split("\n")[1:]
        if parts and parts[-1].strip().startswith("```"):
            parts = parts[:-1]
        text = "\n".join(parts).strip()
    for open_, close in (("「", "」"), ("“", "”"), ('"', '"')):
        if len(text) > 2 and text.startswith(open_) and text.endswith(close):
            text = text[len(open_):-len(close)].strip()
    if not text or len(text) > len(original) * 3 + 40:
        return original
    return text


def polish_text(text: str, mode: str, model: str | None, vocabulary: list[str], speaker_context: str | None, tech_correction: bool) -> tuple[str, int]:
    """回傳 (整理後文字, 毫秒)。mode: colloquial | written | rephrase | raw"""
    if mode == "raw" or not text.strip():
        return text, 0
    prepared = normalize_input(text) if mode != "rephrase" else text
    messages = [{"role": "system", "content": system_prompt(mode, vocabulary, speaker_context, tech_correction)}, {"role": "user", "content": prepared}]
    max_tokens = min(2048, max(48, len(prepared) * 3 + 24))
    started = time.time()
    reply = run_llm(messages, 0.0, max_tokens, model)
    return sanitize_llm(reply, prepared), int((time.time() - started) * 1000)


@app.post("/v1/polish")
async def polish_endpoint(body: dict = Body(...)):
    """{"text", "mode": colloquial|written|rephrase, "model"?, "vocabulary"?: [], "speaker_context"?, "tech_correction"?}"""
    text = (body.get("text") or "").strip()
    if not text:
        return JSONResponse(status_code=400, content={"error": {"message": "缺少 text"}})
    mode = body.get("mode") or "colloquial"
    model = (body.get("model") or "").strip() or None
    if (model is None or model == STATE["llm_model"]) and not STATE["llm_ready"]:
        return JSONResponse(status_code=503, content={"error": {"message": STATE["llm_error"] or "LLM 仍在載入", "type": "llm_not_ready"}})
    try:
        polished, ms = await run_in_threadpool(
            polish_text, text, mode, model, body.get("vocabulary") or [], body.get("speaker_context"), bool(body.get("tech_correction", True))
        )
    except Exception as exc:  # noqa: BLE001
        log.error("polish failed\n%s", traceback.format_exc())
        return JSONResponse(status_code=500, content={"error": {"message": f"{type(exc).__name__}: {exc}", "type": "llm_error"}})
    say(f"[polish {mode} {ms} ms{' ' + model if model else ''}] {polished[:80]}")
    return {"text": polished, "mode": mode, "model": model or STATE["llm_model"], "elapsed_ms": ms}


@app.post("/v1/dictate")
async def dictate_endpoint(
    file: UploadFile = File(...),
    mode: str = Form("colloquial"),
    language: str | None = Form(None),
    prompt: str | None = Form(None),
    llm_model: str = Form(""),
    vocabulary: str = Form(""),
    speaker_context: str | None = Form(None),
):
    """一個 request 做齊辨識＋整理（iOS 鍵盤用）。vocabulary 用逗號或換行分隔。"""
    data = await file.read()
    started = time.time()

    def asr() -> dict:
        audio = normalize(decode_wav(data))
        result = transcribe_array(audio, language, prompt, None)
        text = (result.get("text") or "").strip()
        if prompt and (not text or looks_garbled(text)) and float(np.abs(audio).mean()) > 1e-4:
            result = transcribe_array(audio, language, NO_PROMPT, None)
        return result

    try:
        result = await run_in_threadpool(asr)
    except Exception as exc:  # noqa: BLE001
        log.error("dictate asr failed\n%s", traceback.format_exc())
        return JSONResponse(status_code=500, content={"error": {"message": f"{type(exc).__name__}: {exc}", "type": "asr_error"}})
    raw = re.sub(r"\s+(?=[，。？！、；：」』）])", "", (result.get("text") or "").strip())
    raw = re.sub(r"(?<=[\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])", "", raw)
    asr_ms = int((time.time() - started) * 1000)
    if not raw:
        return {"raw": "", "text": "", "asr_ms": asr_ms, "llm_ms": 0, "note": "聽唔到內容"}
    vocab = [v.strip() for v in re.split(r"[,，\n、]", vocabulary) if v.strip()]
    model = llm_model.strip() or None
    llm_ms = 0
    text = raw
    note = ""
    if mode != "raw":
        if (model is None or model == STATE["llm_model"]) and not STATE["llm_ready"]:
            note = "LLM 載入中，未整理"
        else:
            try:
                text, llm_ms = await run_in_threadpool(polish_text, raw, mode, model, vocab, speaker_context, True)
            except Exception as exc:  # noqa: BLE001
                log.error("dictate polish failed\n%s", traceback.format_exc())
                note = f"整理失敗，用原文：{type(exc).__name__}"
    say(f"[dictate asr {asr_ms} ms + llm {llm_ms} ms] {text[:80]}")
    return {"raw": raw, "text": text, "asr_ms": asr_ms, "llm_ms": llm_ms, "note": note, "model": model or STATE["llm_model"]}


# ---------------------------------------------------------------- model management（模型試驗室用）

MODELS_DIR = os.path.expanduser("~/Library/Application Support/CantoType/models/whisper")
CONVERT_JOBS: dict[str, dict] = {}
CONVERT_LOCK = threading.Lock()


def local_model_dir(repo: str) -> str:
    return os.path.join(MODELS_DIR, repo.replace("/", "--"))


@app.get("/models/inspect")
def inspect_model(repo: str):
    """{"format": "mlx" | "hf" | "local" | "unknown", "files": [...]}"""
    if os.path.isdir(repo):
        return {"repo": repo, "format": "local", "files": sorted(os.listdir(repo))[:20]}
    converted = local_model_dir(repo)
    if os.path.exists(os.path.join(converted, "weights.safetensors")):
        return {"repo": repo, "format": "converted", "path": converted, "files": []}
    from huggingface_hub import HfApi

    try:
        files = HfApi().list_repo_files(repo)
    except Exception as exc:  # noqa: BLE001
        return JSONResponse(status_code=404, content={"error": {"message": f"HuggingFace 搵唔到 {repo}：{type(exc).__name__}"}})
    names = {os.path.basename(f) for f in files}
    if names & {"weights.safetensors", "weights.npz"}:
        fmt = "mlx"
    elif names & {"model.safetensors", "pytorch_model.bin"} or any(n.startswith("model-") and n.endswith(".safetensors") for n in names):
        fmt = "hf"
    else:
        fmt = "unknown"
    return {"repo": repo, "format": fmt, "files": sorted(files)[:40]}


@app.post("/models/convert")
def start_convert(body: dict = Body(...)):
    """背景將 HF transformers Whisper 轉成 MLX；回傳 job id，用 GET /models/convert/{id} 睇進度。"""
    repo = (body.get("repo") or "").strip()
    if not repo:
        return JSONResponse(status_code=400, content={"error": {"message": "缺少 repo"}})
    out = local_model_dir(repo)
    with CONVERT_LOCK:
        for job_id, job in CONVERT_JOBS.items():
            if job["repo"] == repo and job["status"] in ("running", "done"):
                return {"job": job_id, **job}
        job_id = uuid.uuid4().hex[:8]
        CONVERT_JOBS[job_id] = {"repo": repo, "status": "running", "path": out, "log": ["開始…"], "error": None}

    def worker():
        job = CONVERT_JOBS[job_id]

        def progress(message: str):
            job["log"].append(message)
            job["log"] = job["log"][-20:]
            say(f"[convert {repo}] {message}")

        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            from convert_whisper import convert

            convert(repo, out, "float16", progress)
            job["status"] = "done"
        except Exception as exc:  # noqa: BLE001
            job["status"] = "failed"
            job["error"] = f"{type(exc).__name__}: {exc}"
            log.error("convert %s failed\n%s", repo, traceback.format_exc())
            say(f"[convert {repo}] 失敗：{job['error']}")

    threading.Thread(target=worker, daemon=True, name=f"convert-{job_id}").start()
    return {"job": job_id, **CONVERT_JOBS[job_id]}


@app.get("/models/convert/{job_id}")
def convert_status(job_id: str):
    job = CONVERT_JOBS.get(job_id)
    if job is None:
        return JSONResponse(status_code=404, content={"error": {"message": "無此 job"}})
    return {"job": job_id, **job}


@app.get("/models")
def list_models():
    """本地已轉換嘅 Whisper 模型。"""
    result = []
    if os.path.isdir(MODELS_DIR):
        for name in sorted(os.listdir(MODELS_DIR)):
            path = os.path.join(MODELS_DIR, name)
            if os.path.exists(os.path.join(path, "weights.safetensors")):
                source = name.replace("--", "/")
                try:
                    with open(os.path.join(path, "source.json")) as fp:
                        source = json.load(fp).get("source", source)
                except OSError:
                    pass
                result.append({"source": source, "path": path})
    return {"whisper": result, "llm_loaded": list(LLMS.keys())}


# ---------------------------------------------------------------- main

def watch_parent(pid: int) -> None:
    """CantoType app 唔喺度就自動退出，唔會留低孤兒 process。"""

    def loop():
        while True:
            gone = False
            try:
                os.kill(pid, 0)
            except OSError:
                gone = True
            if gone or os.getppid() == 1:
                try:
                    log.info("parent gone, exiting")
                finally:
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
    parser.add_argument("--greedy", action="store_true", help="Whisper 固定 temperature 0，重複迴圈都唔重試")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="127.0.0.1", help="0.0.0.0 就可以由 Tailscale／局域網連入")
    parser.add_argument("--token", default="", help="設定咗就要求 Authorization: Bearer <token>（/health 除外）")
    parser.add_argument("--parent-pid", type=int, default=0, help="呢個 pid 消失就自動退出")
    args = parser.parse_args()

    STATE.update(
        whisper_model=args.model,
        llm_model=args.llm,
        language=args.language,
        prompt=args.prompt,
        no_speech_threshold=args.no_speech_threshold,
        temperature=0.0 if args.greedy else (0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
    )
    global API_TOKEN
    API_TOKEN = args.token
    STATE["parent_pid"] = args.parent_pid
    STATE["host"] = args.host
    if args.parent_pid:
        watch_parent(args.parent_pid)
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))

    say(f"啟動：pid {os.getpid()}，parent {args.parent_pid}，log {LOG_PATH}")
    say(f"載入 Whisper {STATE['whisper_model']} …")
    started = time.time()
    transcribe_array(np.zeros(16000, dtype=np.float32), STATE["language"], None)
    say(f"Whisper 就緒（{time.time() - started:.1f} 秒）。監聽 http://{args.host}:{args.port}")
    load_llm_background()
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
