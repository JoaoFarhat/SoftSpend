from sqlalchemy import *
from enums.categoria_enum import Categoria
from database import Base
from sqlalchemy.orm import relationship

class Gasto(Base):
    __tablename__ = "gastos_dia"

    id = Column(Integer, primary_key=True)
    dia_id = Column(Integer, ForeignKey("dias.id"))
    titulo = Column(String(100))
    valor = Column(Float)
    categoria = Column(Enum(Categoria, values_callable=lambda obj: [e.name for e in obj]))

    dia = relationship("Dia", back_populates="gastos")