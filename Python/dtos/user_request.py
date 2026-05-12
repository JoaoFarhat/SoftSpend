from pydantic import BaseModel

class UserRequest(BaseModel):
    nome: str