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
