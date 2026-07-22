from pydantic import BaseModel
from datetime import datetime

class DiaRequest(BaseModel):
    data: datetime