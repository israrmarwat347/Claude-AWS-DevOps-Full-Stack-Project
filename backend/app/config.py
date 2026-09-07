from typing import Literal

from pydantic import SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    app_env: Literal["local", "dev", "staging", "prod"] = "local"
    aws_region: str = "eu-west-1"
    table_name: str = ""
    anthropic_secret_arn: str = ""
    anthropic_api_key: SecretStr = SecretStr("")
    claude_model: str = "claude-haiku-4-5-20251001"
    mock_claude: bool = False
    local_auth: bool = False
    cognito_user_pool_id: str = ""
    cognito_client_id: str = ""
    cognito_domain: str = ""
    max_output_tokens: int = 1024
    generation_timeout: int = 120
    retention_days: int = 30
    chat_requests_per_minute: int = 10
    api_requests_per_minute: int = 60
    max_history_bytes: int = 100_000
    release_sha: str = "local"

    @model_validator(mode="after")
    def validate_deployment(self):
        if self.app_env != "local":
            if self.local_auth or self.mock_claude:
                raise ValueError("Local authentication and mock responses are forbidden on AWS")
            for field in (
                "table_name",
                "anthropic_secret_arn",
                "cognito_user_pool_id",
                "cognito_client_id",
                "cognito_domain",
            ):
                if not getattr(self, field):
                    raise ValueError(f"{field} is required on AWS")
            if self.anthropic_api_key.get_secret_value():
                raise ValueError("Use Secrets Manager on AWS, not ANTHROPIC_API_KEY")
        if not 1 <= self.max_output_tokens <= 4096:
            raise ValueError("max_output_tokens must be between 1 and 4096")
        if not 1 <= self.generation_timeout <= 120:
            raise ValueError("generation_timeout must be between 1 and 120 seconds")
        return self

    @property
    def issuer(self):
        return f"https://cognito-idp.{self.aws_region}.amazonaws.com/{self.cognito_user_pool_id}"
