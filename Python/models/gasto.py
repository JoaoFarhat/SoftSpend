from sqlalchemy import Column, Enum, ForeignKey, Integer, Numeric, String, UniqueConstraint
from enums.categoria_enum import Categoria
from database import Base
from sqlalchemy.orm import relationship

class Gasto(Base):
    __tablename__ = "gastos_dia"

    id = Column(Integer, primary_key=True)
    client_id = Column(String(50), index=True, nullable=True)
    dia_id = Column(Integer, ForeignKey("dias.id"))
    titulo = Column(String(100))
    valor = Column(Numeric(10, 2))
    categoria = Column(Enum(Categoria, values_callable=lambda obj: [e.name for e in obj]))
    comprovante_key = Column(String(255), nullable=True)

    dia = relationship("Dia", back_populates="gastos")
    open_finance_match = relationship(
        "ExpenseTransactionMatch",
        back_populates="gasto",
        uselist=False,
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("client_id", "dia_id", name="uix_gasto_client_id_dia"),
    )

    @property
    def open_finance_status(self) -> str:
        return self.open_finance_match.status if self.open_finance_match else "PENDENTE"

    @property
    def comprovante_url(self) -> str | None:
        from services import storage_service

        return storage_service.url_do_comprovante(self.comprovante_key)
