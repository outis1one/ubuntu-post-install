from pydantic_settings import BaseSettings
from typing import List


class Settings(BaseSettings):
    # Database
    database_url: str = "sqlite:///./data/ai_photo_edit.db"

    # Security
    secret_key: str = "your-secret-key-change-in-production"
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 30

    # AI Provider
    # Local: blank or "mock" — always available, no config needed
    # Remote default (used for any operation without a specific override):
    #   openai | invokeai | comfyui | replicate | stability
    ai_provider: str = "mock"

    # Per-operation provider overrides — blank means use ai_provider default.
    # Operations: inpaint, txt2img, img2img, outpaint
    # Example: AI_PROVIDER_TXT2IMG=openai  (use OpenAI for text-to-image only)
    ai_provider_inpaint: str = ""   # remote inpaint / replace selection
    ai_provider_txt2img: str = ""   # text-to-image
    ai_provider_img2img: str = ""   # image-to-image
    ai_provider_outpaint: str = ""  # expand canvas

    # Provider API Keys
    openai_api_key: str = ""
    openai_model: str = "dall-e-3"
    stability_api_key: str = ""
    replicate_api_key: str = ""

    # InvokeAI (self-hosted)
    invokeai_url: str = ""
    invokeai_default_model: str = "flux-dev"

    # ComfyUI (self-hosted)
    comfyui_url: str = ""
    comfyui_default_model: str = "v1-5-pruned-emaonly.ckpt"

    # Model Selection (optional, provider-specific)
    stability_model: str = "sdxl"  # Options: sdxl, sd15, sd21
    replicate_model: str = "sdxl-inpaint"  # Options: sdxl-inpaint, lama, realistic-vision

    # Allow per-edit model override
    allow_model_override: bool = True

    # Remove Background — preferred local model when request.model="auto"
    # Options: ben2 (default, best for clean cutouts/hair), birefnet-hr (best
    # for high-res/print work), u2net (lightweight, smallest download)
    bg_removal_model: str = "ben2"

    # Local GPU diffusion (AI_PROVIDER=local_gpu)
    auto_download_models: bool = True      # download HF models on first use
    local_gpu_max_pipelines: int = 2       # max diffusion pipelines kept in GPU memory
    hf_token: str = ""                     # HuggingFace token (only needed for gated models)
    # Override auto-selected models per operation (leave blank = auto-pick by VRAM tier)
    hf_model_inpaint: str = ""
    hf_model_txt2img: str = ""
    hf_model_img2img: str = ""

    # File Storage
    data_dir: str = "./data"
    max_upload_size_mb: int = 50

    # CORS
    cors_origins: str = "http://localhost:3000,http://localhost:5173"

    @property
    def cors_origins_list(self) -> List[str]:
        return [origin.strip() for origin in self.cors_origins.split(",")]

    class Config:
        env_file = ".env"
        case_sensitive = False


settings = Settings()
