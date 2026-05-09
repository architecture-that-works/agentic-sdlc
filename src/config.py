from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Logging
    log_profile: str = "TEST"           # PRD | TEST | DEBUG
    log_separator_width: int = 80
    log_line_width: int = 120
    log_dir: Path = Path("logs")


settings = Settings()
