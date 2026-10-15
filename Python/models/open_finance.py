from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    JSON,
    Numeric,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import relationship
from database import Base


class OpenFinanceConnection(Base):
    __tablename__ = "open_finance_connections"

    id = Column(Integer, primary_key=True)
    user_id = Column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    provider = Column(String(30), nullable=False, default="pluggy")
    item_id = Column(String(64), nullable=False)
    client_user_id = Column(String(100), nullable=True)
    institution_name = Column(String(255), nullable=True)
    status = Column(String(50), nullable=True)
    error_code = Column(String(100), nullable=True)
    error_message = Column(String(500), nullable=True)
    last_sync_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=func.now(), nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    cartoes = relationship(
        "CreditCardAccount", back_populates="conexao", cascade="all, delete-orphan"
    )

    __table_args__ = (
        UniqueConstraint("provider", "item_id", name="uix_open_finance_provider_item"),
        Index("ix_open_finance_connections_user_id", "user_id"),
    )


class CreditCardAccount(Base):
    __tablename__ = "credit_card_accounts"

    id = Column(Integer, primary_key=True)
    conexao_id = Column(
        Integer,
        ForeignKey("open_finance_connections.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_id = Column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    account_id = Column(String(64), nullable=False, unique=True)
    institution_name = Column(String(255), nullable=True)
    name = Column(String(255), nullable=True)
    marketing_name = Column(String(255), nullable=True)
    number_last4 = Column(String(4), nullable=True)
    type = Column(String(30), nullable=True)
    subtype = Column(String(30), nullable=True)
    currency_code = Column(String(3), nullable=True)
    balance = Column(Numeric(14, 2), nullable=True)
    credit_limit = Column(Numeric(14, 2), nullable=True)
    available_credit_limit = Column(Numeric(14, 2), nullable=True)
    minimum_payment = Column(Numeric(14, 2), nullable=True)
    balance_close_date = Column(DateTime(timezone=True), nullable=True)
    balance_due_date = Column(DateTime(timezone=True), nullable=True)
    brand = Column(String(50), nullable=True)
    level = Column(String(50), nullable=True)
    status = Column(String(50), nullable=True)
    created_at = Column(DateTime(timezone=True), default=func.now(), nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    conexao = relationship("OpenFinanceConnection", back_populates="cartoes")
    faturas = relationship(
        "CreditCardBill", back_populates="cartao", cascade="all, delete-orphan"
    )
    transacoes = relationship(
        "CreditCardTransaction", back_populates="cartao", cascade="all, delete-orphan"
    )

    __table_args__ = (
        Index("ix_credit_card_accounts_user_id", "user_id"),
        Index("ix_credit_card_accounts_conexao_id", "conexao_id"),
    )


class CreditCardBill(Base):
    __tablename__ = "credit_card_bills"

    id = Column(Integer, primary_key=True)
    cartao_id = Column(
        Integer,
        ForeignKey("credit_card_accounts.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_id = Column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    bill_id = Column(String(64), nullable=False, unique=True)
    due_date = Column(DateTime(timezone=True), nullable=True)
    closing_date = Column(DateTime(timezone=True), nullable=True)
    total_amount = Column(Numeric(14, 2), nullable=True)
    currency_code = Column(String(3), nullable=True)
    minimum_payment_amount = Column(Numeric(14, 2), nullable=True)
    allows_installments = Column(Boolean, nullable=True)
    finance_charges = Column(JSON, nullable=True)
    payments = Column(JSON, nullable=True)
    created_at = Column(DateTime(timezone=True), default=func.now(), nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    cartao = relationship("CreditCardAccount", back_populates="faturas")
    transacoes = relationship("CreditCardTransaction", back_populates="fatura")

    __table_args__ = (
        Index("ix_credit_card_bills_user_id", "user_id"),
        Index("ix_credit_card_bills_cartao_id", "cartao_id"),
    )


class CreditCardTransaction(Base):
    __tablename__ = "credit_card_transactions"

    id = Column(Integer, primary_key=True)
    cartao_id = Column(
        Integer,
        ForeignKey("credit_card_accounts.id", ondelete="CASCADE"),
        nullable=False,
    )
    fatura_id = Column(
        Integer, ForeignKey("credit_card_bills.id", ondelete="SET NULL"), nullable=True
    )
    user_id = Column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    transaction_id = Column(String(64), nullable=False, unique=True)
    description = Column(String(255), nullable=True)
    description_raw = Column(String(500), nullable=True)
    amount = Column(Numeric(14, 2), nullable=True)
    amount_in_account_currency = Column(Numeric(14, 2), nullable=True)
    currency_code = Column(String(3), nullable=True)
    date = Column(DateTime(timezone=True), nullable=True)
    category = Column(String(100), nullable=True)
    status = Column(String(30), nullable=True)
    type = Column(String(30), nullable=True)
    provider_code = Column(String(100), nullable=True)
    provider_id = Column(String(100), nullable=True)
    merchant_name = Column(String(255), nullable=True)
    credit_card_metadata = Column(JSON, nullable=True)
    last_seen_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=func.now(), nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    cartao = relationship("CreditCardAccount", back_populates="transacoes")
    fatura = relationship("CreditCardBill", back_populates="transacoes")
    open_finance_match = relationship(
        "ExpenseTransactionMatch",
        back_populates="transacao",
        uselist=False,
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        Index("ix_credit_card_transactions_user_id", "user_id"),
        Index("ix_credit_card_transactions_cartao_id", "cartao_id"),
        Index("ix_credit_card_transactions_user_date", "user_id", "date"),
    )


class ExpenseTransactionMatch(Base):
    __tablename__ = "expense_transaction_matches"

    id = Column(Integer, primary_key=True)
    gasto_id = Column(
        Integer, ForeignKey("gastos_dia.id", ondelete="CASCADE"), nullable=False
    )
    cartao_transacao_id = Column(
        Integer,
        ForeignKey("credit_card_transactions.id", ondelete="CASCADE"),
        nullable=False,
    )
    status = Column(String(30), nullable=False)
    score = Column(Integer, nullable=False)
    method = Column(String(50), nullable=False, default="RULES")
    confirmed_by_user = Column(Boolean, nullable=False, default=False)
    matched_at = Column(DateTime(timezone=True), default=func.now(), nullable=False)
    created_at = Column(DateTime(timezone=True), default=func.now(), nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    gasto = relationship("Gasto", back_populates="open_finance_match")
    transacao = relationship(
        "CreditCardTransaction", back_populates="open_finance_match"
    )

    __table_args__ = (
        UniqueConstraint("gasto_id", name="uix_expense_match_gasto"),
        UniqueConstraint(
            "cartao_transacao_id", name="uix_expense_match_transaction"
        ),
        Index("ix_expense_transaction_matches_status", "status"),
    )

    @property
    def provider_transaction_id(self) -> str | None:
        return self.transacao.transaction_id if self.transacao else None

    @property
    def transaction_description(self) -> str | None:
        return self.transacao.description if self.transacao else None

    @property
    def transaction_amount(self):
        return self.transacao.amount if self.transacao else None

    @property
    def transaction_date(self):
        return self.transacao.date if self.transacao else None
