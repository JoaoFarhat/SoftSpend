from sqlalchemy import Column, Integer, Float, String, ForeignKey, UniqueConstraint
from sqlalchemy.orm import relationship
from database import Base

class Ciclo(Base):
    __tablename__ = "ciclos"

    id = Column(Integer, primary_key=True, index=True)
    client_id = Column(String(50), index=True, nullable=True)

    valor_total = Column(Float)
    gasto_total = Column(Float)
    titulo = Column(String(100))
    periodo = Column(String(100))
    diaria = Column(Float)

    id_usuario = Column(Integer, ForeignKey("users.id"))

    usuario = relationship("User", back_populates="ciclos")
    dias = relationship("Dia", back_populates="ciclo", cascade="all, delete-orphan")

    __table_args__ = (
        UniqueConstraint("client_id", "id_usuario", name="uix_ciclo_client_id_usuario"),
    )
