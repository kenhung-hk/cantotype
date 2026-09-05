"""
將 HuggingFace transformers 格式嘅 Whisper（例如 alvanlii/whisper-small-cantonese）轉成 mlx-whisper 格式。

改編自 ml-explore/mlx-examples whisper/convert.py（MIT License, Copyright © 2023 Apple Inc.），
加上：sharded safetensors、只靠 mlx（.bin 先需要 torch）、可以喺伺服器 thread 內呼叫。

用法（獨立）：
  uv run --with mlx-whisper --with safetensors server/convert_whisper.py alvanlii/whisper-small-cantonese ./out
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Callable

import mlx.core as mx
from mlx.utils import tree_flatten


def hf_to_pt(weights: dict, config: dict) -> tuple[dict, dict]:
    dims = {
        "n_mels": config["num_mel_bins"],
        "n_audio_ctx": config["max_source_positions"],
        "n_audio_state": config["d_model"],
        "n_audio_head": config["encoder_attention_heads"],
        "n_audio_layer": config["encoder_layers"],
        "n_vocab": config["vocab_size"],
        "n_text_ctx": config["max_target_positions"],
        "n_text_state": config["d_model"],
        "n_text_head": config["decoder_attention_heads"],
        "n_text_layer": config["decoder_layers"],
    }

    def remap(k: str) -> str:
        k = k.replace("model.", "")
        k = k.replace(".layers", ".blocks")
        k = k.replace(".self_attn", ".attn")
        k = k.replace(".attn_layer_norm", ".attn_ln")
        k = k.replace(".encoder_attn.", ".cross_attn.")
        k = k.replace(".encoder_attn_layer_norm", ".cross_attn_ln")
        k = k.replace(".final_layer_norm", ".mlp_ln")
        k = k.replace(".q_proj", ".query")
        k = k.replace(".k_proj", ".key")
        k = k.replace(".v_proj", ".value")
        k = k.replace(".out_proj", ".out")
        k = k.replace(".fc1", ".mlp1")
        k = k.replace(".fc2", ".mlp2")
        k = k.replace("embed_positions.weight", "positional_embedding")
        k = k.replace("decoder.embed_tokens", "decoder.token_embedding")
        k = k.replace("encoder.layer_norm", "encoder.ln_post")
        k = k.replace("decoder.layer_norm", "decoder.ln")
        return k

    weights.pop("proj_out.weight", None)
    return {remap(k): v for k, v in weights.items()}, dims


def download(repo: str, progress: Callable[[str], None]) -> Path:
    from huggingface_hub import snapshot_download

    progress(f"下載 {repo} …")
    path = snapshot_download(
        repo_id=repo,
        allow_patterns=["config.json", "pytorch_model.bin", "model.safetensors", "model-*.safetensors", "model.safetensors.index.json"],
    )
    return Path(path)


def load_hf_weights(path: Path, progress: Callable[[str], None]) -> tuple[dict, dict]:
    with open(path / "config.json") as fp:
        config = json.load(fp)
    if config.get("model_type") not in (None, "whisper"):
        raise ValueError(f"唔係 Whisper 模型（model_type={config.get('model_type')}）")

    shards = sorted(path.glob("model-*.safetensors")) or ([path / "model.safetensors"] if (path / "model.safetensors").exists() else [])
    weights: dict = {}
    if shards:
        for shard in shards:
            progress(f"讀取 {shard.name} …")
            weights.update(mx.load(str(shard)))
    elif (path / "pytorch_model.bin").exists():
        progress("讀取 pytorch_model.bin（需要 torch）…")
        import torch

        state = torch.load(path / "pytorch_model.bin", map_location="cpu")
        weights = {k: mx.array(v.numpy()) for k, v in state.items()}
    else:
        raise FileNotFoundError("repo 入面搵唔到 model.safetensors / model-*.safetensors / pytorch_model.bin")
    return hf_to_pt(weights, config)


def convert(repo_or_path: str, out_dir: str, dtype: str = "float16", progress: Callable[[str], None] = print) -> str:
    """回傳輸出資料夾（含 config.json + weights.safetensors，可以直接畀 mlx_whisper 用）。"""
    from mlx_whisper.whisper import ModelDimensions, Whisper

    src = Path(repo_or_path)
    if not src.exists():
        src = download(repo_or_path, progress)
    weights, dims = load_hf_weights(src, progress)

    mx_dtype = getattr(mx, dtype)

    def remap(key: str, value):
        key = key.replace("mlp.0", "mlp1").replace("mlp.2", "mlp2")
        if "conv" in key and value.ndim == 3:
            value = value.swapaxes(1, 2)
        return key, value.astype(mx_dtype)

    weights.pop("encoder.positional_embedding", None)
    weights = dict(remap(k, v) for k, v in weights.items())

    progress("組裝 MLX 模型…")
    model = Whisper(ModelDimensions(**dims), mx_dtype)
    model.load_weights(list(weights.items()), strict=False)
    mx.eval(model.parameters())

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    progress("寫入 weights.safetensors …")
    mx.save_safetensors(str(out / "weights.safetensors"), dict(tree_flatten(model.parameters())))
    with open(out / "config.json", "w") as fp:
        json.dump(dims, fp, indent=2)
    with open(out / "source.json", "w") as fp:
        json.dump({"source": repo_or_path, "dtype": dtype}, fp)
    progress("完成")
    return str(out)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    convert(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "float16")
