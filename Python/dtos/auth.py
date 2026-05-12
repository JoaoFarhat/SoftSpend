from pydantic import BaseModel, EmailStr, field_validator


class RegisterRequest(BaseModel):
    nome: str
    username: str
    email: EmailStr
    senha: str

    @field_validator("senha")
    @classmethod
    def senha_forte(cls, v: str) -> str:
        if len(v) < 8:
            raise ValueError("A senha deve ter no mínimo 8 caracteres")
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


class AuthResponse(BaseModel):
    id: int
    nome: str
    username: str
    email: str
    token: str
