from sqlalchemy import Column, Integer, Float, String, ForeignKey
from sqlalchemy.orm import relationship
from database import Base

class Ciclo(Base):
    __tablename__ = "ciclos"

    id = Column(Integer, primary_key=True, index=True)

    valor_total = Column(Float)
    gasto_total = Column(Float)
    titulo = Column(String(100))
    periodo = Column(String(100))
    diaria = Column(Float)

    id_usuario = Column(Integer, ForeignKey("users.id"))

    dias = relationship("Dia", back_populates="ciclo", cascade="all, delete-orphan")