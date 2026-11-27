from pydantic import BaseModel, EmailStr, field_validator, Field


def _aparar_espacos(v):
    # O teclado do iPhone sugere o e-mail com um espaco no fim; tab e quebra
    # de linha nem passam pelo EmailStr (422 em vez de cair na busca).
    return v.strip() if isinstance(v, str) else v


class RegisterRequest(BaseModel):
    nome: str = Field(..., min_length=1, max_length=100)
    username: str = Field(..., min_length=3, max_length=50)
    email: EmailStr = Field(..., max_length=255)
    senha: str

    @field_validator("email", mode="before")
    @classmethod
    def email_sem_espacos(cls, v):
        return _aparar_espacos(v)

    @field_validator("senha")
    @classmethod
    def senha_forte(cls, v: str) -> str:
        return _validar_senha_forte(v)


def _validar_senha_forte(v: str) -> str:
    """Mesma regra no cadastro e na senha nova do "Esqueci minha senha"."""
    if len(v) < 8:
        raise ValueError("A senha deve ter no mínimo 8 caracteres")
    if len(v) > 128:
        raise ValueError("A senha deve ter no máximo 128 caracteres")
    if not any(c.isupper() for c in v):
        raise ValueError("A senha deve conter ao menos uma letra maiúscula")
    if not any(c.islower() for c in v):
        raise ValueError("A senha deve conter ao menos uma letra minúscula")
    if not any(c.isdigit() for c in v):
        raise ValueError("A senha deve conter ao menos um número")
    if not any(c in "!@#$%^&*()_+-=[]{}|;:',.<>?/~`" for c in v):
        raise ValueError("A senha deve conter ao menos um caractere especial")
    return v


class LoginRequest(BaseModel):
    email: EmailStr
    senha: str

    @field_validator("email", mode="before")
    @classmethod
    def email_sem_espacos(cls, v):
        return _aparar_espacos(v)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(..., min_length=1, max_length=512)


class LogoutRequest(BaseModel):
    refresh_token: str = Field(..., min_length=1, max_length=512)


class AuthResponse(BaseModel):
    id: str
    nome: str
    username: str
    email: str
    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int


class EsqueciSenhaRequest(BaseModel):
    email: EmailStr = Field(..., max_length=255)

    @field_validator("email", mode="before")
    @classmethod
    def email_sem_espacos(cls, v):
        return _aparar_espacos(v)


class EsqueciSenhaResponse(BaseModel):
    """Igual exista a conta ou nao: o app so mostra "se houver uma conta..."."""

    expires_in_seconds: int
    resend_after_seconds: int


class RedefinirSenhaRequest(BaseModel):
    email: EmailStr = Field(..., max_length=255)
    codigo: str = Field(..., pattern=r"^[0-9]{6}$")
    nova_senha: str

    @field_validator("email", mode="before")
    @classmethod
    def email_sem_espacos(cls, v):
        return _aparar_espacos(v)

    @field_validator("codigo", mode="before")
    @classmethod
    def codigo_sem_espacos(cls, v):
        return _aparar_espacos(v)

    @field_validator("nova_senha")
    @classmethod
    def senha_forte(cls, v: str) -> str:
        return _validar_senha_forte(v)
