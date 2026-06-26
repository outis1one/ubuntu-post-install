#!/usr/bin/env python3
"""
GPU setup script — runs at container startup.
Uses the same detection logic as the backend (gpu_detect.py) to show
exactly which models will be used before the server starts.
Non-fatal: any failure just prints a warning and startup continues.
"""
import os
import sys


def main():
    print("Detecting GPU capabilities…")

    try:
        import torch
    except ImportError:
        print("⚠ PyTorch not installed — GPU detection skipped")
        return

    if torch.cuda.is_available():
        props = torch.cuda.get_device_properties(0)
        free_b, total_b = torch.cuda.mem_get_info(0)
        vram_total = total_b / (1024 ** 3)
        vram_free  = free_b  / (1024 ** 3)
        major, minor = props.major, props.minor
        cc = f"{major}.{minor}"

        fp16 = major >= 6
        bf16 = major >= 8
        fp8  = major > 8 or (major == 8 and minor >= 9)
        int8 = major >= 7
        tc   = major >= 7

        flags = []
        if fp16: flags.append("fp16")
        if bf16: flags.append("bf16")
        if fp8:  flags.append("fp8")
        if int8: flags.append("int8")
        if tc:   flags.append("tensor-cores")

        print(f"✓ GPU     : {props.name}")
        print(f"  VRAM    : {vram_total:.1f} GB total  |  {vram_free:.1f} GB free")
        print(f"  Compute : CC {cc}  ({', '.join(flags) or 'fp32 only'})")

        if major < 6:
            print(f"  ⚠ Pre-Pascal (CC {cc}): using fp32 — effective VRAM budget halved")

    elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        print("✓ Apple Silicon MPS GPU detected (fp32 mode)")
        vram_total = vram_free = 0.0
    else:
        print("⚠ No GPU detected — AI inference will use CPU (very slow)")
        vram_total = vram_free = 0.0

    provider = os.environ.get("AI_PROVIDER", "").lower()
    if provider != "local_gpu":
        print(f"  AI_PROVIDER={provider!r} — local GPU not active, skipping model selection")
        return

    # Import and run the full detection to show what was selected
    try:
        sys.path.insert(0, "/app")
        from app.services.gpu_detect import detect_gpu
        info = detect_gpu()

        print(f"\n  Effective VRAM : {info.effective_vram_gb:.1f} GB  (tier: {info.tier})")
        print("\n  Model selection:")
        printed: set = set()
        for op, spec in info.recommended.items():
            if spec is None:
                print(f"    {op:<12} → (none — will use existing upscaler)")
            elif spec.model_id not in printed:
                print(f"    {op:<12} → [{spec.family}] {spec.model_id}")
                print(f"               mem_opt={spec.memory_opt}  res={spec.native_res}px  ~{spec.vram_fp16_gb}GB fp16")
                printed.add(spec.model_id)
            else:
                print(f"    {op:<12} → (same as above: {spec.model_id})")

        for w in info.warnings:
            print(f"\n  ⚠ {w}")

        auto_dl = os.environ.get("AUTO_DOWNLOAD_MODELS", "true").lower()
        print()
        if auto_dl == "true":
            print("  AUTO_DOWNLOAD_MODELS=true")
            print("  → Model files will download in background at startup.")
            print("  → First request loads from local disk (20-60s, not internet).")
            print("  → Track progress: GET /api/gpu/prefetch-status")
        else:
            print("  AUTO_DOWNLOAD_MODELS=false — models download on first request.")

    except Exception as exc:
        print(f"  (Could not run full detection: {exc})")

    print()


if __name__ == "__main__":
    main()
