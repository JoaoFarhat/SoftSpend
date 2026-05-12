from sqlalchemy import *
from database import Base
from sqlalchemy.orm import relationship

class Dia(Base):
    __tablename__ = "dias"

    id = Column(Integer, primary_key=True)
    ciclo_id = Column(Integer, ForeignKey("ciclos.id"))
    data = Column(DateTime(timezone=True))
    saldo = Column(Float)

    ciclo = relationship("Ciclo", back_populates="dias")
    gastos = relationship("Gasto", back_populates="dia", cascade="all, delete-orphan")