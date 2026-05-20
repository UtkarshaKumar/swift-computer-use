#!/usr/bin/env python3
"""
ShowUI-2B inference server for SDD (swift-computer-use).
Runs locally on port 7080. Swift's ShowUIClient calls this for visual element grounding.

Setup:
    pip install -r showui_requirements.txt
    python showui_server.py

The server loads ShowUI-2B on startup (~10s, downloads ~3GB on first run).
After loading, each grounding query takes ~150ms on Apple Silicon (MPS backend).
"""

import base64
import io
import logging
import re
import sys
from contextlib import asynccontextmanager
from typing import Optional

import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel
from transformers import AutoProcessor, Qwen2VLForConditionalGeneration

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Device selection
# ---------------------------------------------------------------------------

def select_device() -> torch.device:
    if torch.backends.mps.is_available():
        log.info("Using MPS (Apple Silicon) backend")
        return torch.device("mps")
    log.warning("MPS not available, falling back to CPU")
    return torch.device("cpu")


# ---------------------------------------------------------------------------
# Global model state
# ---------------------------------------------------------------------------

MODEL_ID = "showlab/ShowUI-2B"

_processor: Optional[AutoProcessor] = None
_model: Optional[Qwen2VLForConditionalGeneration] = None
_device: Optional[torch.device] = None


def load_model() -> None:
    global _processor, _model, _device

    log.info(f"Loading model '{MODEL_ID}' — this may take ~10s and ~3 GB on first run...")
    _device = select_device()

    _processor = AutoProcessor.from_pretrained(MODEL_ID, trust_remote_code=True)
    _model = Qwen2VLForConditionalGeneration.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.float16 if _device.type != "cpu" else torch.float32,
        trust_remote_code=True,
    )
    _model = _model.to(_device)
    _model.eval()

    log.info("Model loaded and ready.")


# ---------------------------------------------------------------------------
# FastAPI lifespan
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    load_model()
    yield
    log.info("Shutting down.")


app = FastAPI(title="ShowUI-2B Inference Server", lifespan=lifespan)

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

class GroundRequest(BaseModel):
    image_base64: str
    query: str


class GroundResponse(BaseModel):
    x: float
    y: float
    confidence: float
    query: Optional[str] = None


class HealthResponse(BaseModel):
    status: str
    model: str


# ---------------------------------------------------------------------------
# Inference helpers
# ---------------------------------------------------------------------------

PROMPT_TEMPLATE = (
    "In this UI screenshot, find the element: {query}. "
    "Output the normalized (x, y) coordinate of its center as (x, y)."
)

_COORD_PATTERN = re.compile(r"\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\)")


def _decode_image(image_base64: str) -> Image.Image:
    """Decode a base64-encoded JPEG/PNG into a PIL Image."""
    try:
        raw = base64.b64decode(image_base64)
        return Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception as exc:
        raise ValueError(f"Failed to decode image: {exc}") from exc


def _run_inference(image: Image.Image, query: str) -> tuple[float, float, float]:
    """
    Run ShowUI-2B grounding inference.

    Returns (x, y, confidence) where x, y are normalized [0, 1].
    """
    assert _processor is not None and _model is not None and _device is not None

    prompt = PROMPT_TEMPLATE.format(query=query)

    # Build the multimodal input the way Qwen2-VL expects it.
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": prompt},
            ],
        }
    ]

    # Apply chat template and tokenize.
    text_input = _processor.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )

    inputs = _processor(
        text=[text_input],
        images=[image],
        return_tensors="pt",
        padding=True,
    )
    inputs = {k: v.to(_device) for k, v in inputs.items()}

    # Generate with scores so we can extract a confidence proxy.
    with torch.no_grad():
        output = _model.generate(
            **inputs,
            max_new_tokens=64,
            do_sample=False,
            return_dict_in_generate=True,
            output_scores=True,
        )

    # Decode the generated tokens (excluding the prompt).
    generated_ids = output.sequences[0][inputs["input_ids"].shape[-1]:]
    generated_text = _processor.decode(generated_ids, skip_special_tokens=True).strip()

    log.debug(f"Model output for '{query}': {generated_text!r}")

    # Parse "(x, y)" from the model output.
    match = _COORD_PATTERN.search(generated_text)
    if not match:
        raise ValueError(
            f"Could not parse coordinates from model output: {generated_text!r}"
        )

    x = float(match.group(1))
    y = float(match.group(2))

    # Clamp to [0, 1] in case the model slightly overshoots.
    x = max(0.0, min(1.0, x))
    y = max(0.0, min(1.0, y))

    # Derive a confidence score from the transition scores if available.
    confidence = 0.9  # default fallback
    if output.scores:
        try:
            # Average the top-1 softmax probability across generated tokens as a
            # rough proxy for generation confidence.
            probs = [
                torch.softmax(score[0], dim=-1).max().item()
                for score in output.scores
            ]
            confidence = float(sum(probs) / len(probs)) if probs else 0.9
            confidence = max(0.0, min(1.0, confidence))
        except Exception:
            confidence = 0.9

    return x, y, confidence


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse(status="ok", model="ShowUI-2B")


@app.post("/ground", response_model=GroundResponse)
async def ground(req: GroundRequest) -> GroundResponse:
    if _model is None or _processor is None:
        raise HTTPException(status_code=503, detail="Model not loaded yet")

    try:
        image = _decode_image(req.image_base64)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    try:
        x, y, confidence = _run_inference(image, req.query)
    except ValueError as exc:
        log.warning(f"Inference parse error for query '{req.query}': {exc}")
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except Exception as exc:
        log.error(f"Inference failed for query '{req.query}': {exc}", exc_info=True)
        raise HTTPException(status_code=500, detail="Inference error") from exc

    return GroundResponse(x=x, y=y, confidence=confidence, query=req.query)


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=7080, log_level="info")
