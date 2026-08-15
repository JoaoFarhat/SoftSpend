from sqlalchemy import *
from sqlalchemy import UniqueConstraint
from database import Base
from sqlalchemy.orm import relationship

class Dia(Base):
    __tablename__ = "dias"

    id = Column(Integer, primary_key=True)
    client_id = Column(String(50), index=True, nullable=True)
    ciclo_id = Column(Integer, ForeignKey("ciclos.id"))
    data = Column(DateTime(timezone=True))
    saldo = Column(Float)

    ciclo = relationship("Ciclo", back_populates="dias")
    gastos = relationship("Gasto", back_populates="dia", cascade="all, delete-orphan")

    __table_args__ = (
        UniqueConstraint("client_id", "ciclo_id", name="uix_dia_client_id_ciclo"),
    )
