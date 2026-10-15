from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict

from dtos.tipos import Dinheiro


class OpenFinanceConnectionResponse(BaseModel):
    id: int
    item_id: str
    provider: str
    institution_name: str | None
    status: str | None
    error_code: str | None
    error_message: str | None
    last_sync_at: datetime | None

    model_config = ConfigDict(from_attributes=True)


class CreditCardAccountResponse(BaseModel):
    id: int
    conexao_id: int
    account_id: str
    institution_name: str | None
    name: str | None
    marketing_name: str | None
    number_last4: str | None
    currency_code: str | None
    balance: Dinheiro | None
    credit_limit: Dinheiro | None
    available_credit_limit: Dinheiro | None
    minimum_payment: Dinheiro | None
    balance_close_date: datetime | None
    balance_due_date: datetime | None
    brand: str | None
    level: str | None
    status: str | None

    model_config = ConfigDict(from_attributes=True)


class CreditCardBillResponse(BaseModel):
    id: int
    cartao_id: int
    bill_id: str
    due_date: datetime | None
    closing_date: datetime | None
    total_amount: Dinheiro | None
    currency_code: str | None
    minimum_payment_amount: Dinheiro | None
    allows_installments: bool | None

    model_config = ConfigDict(from_attributes=True)


class ExpenseTransactionMatchResponse(BaseModel):
    id: int
    gasto_id: int
    cartao_transacao_id: int
    provider_transaction_id: str | None
    transaction_description: str | None
    transaction_amount: Dinheiro | None
    transaction_date: datetime | None
    status: str
    score: int
    method: str
    confirmed_by_user: bool
    matched_at: datetime

    model_config = ConfigDict(from_attributes=True)


class CreditCardTransactionResponse(BaseModel):
    id: int
    cartao_id: int
    fatura_id: int | None
    transaction_id: str
    description: str | None
    description_raw: str | None
    amount: Dinheiro | None
    amount_in_account_currency: Dinheiro | None
    currency_code: str | None
    date: datetime | None
    category: str | None
    status: str | None
    type: str | None
    provider_code: str | None
    provider_id: str | None
    merchant_name: str | None
    credit_card_metadata: dict[str, Any] | None
    open_finance_match: ExpenseTransactionMatchResponse | None = None

    model_config = ConfigDict(from_attributes=True)


class CreditCardBillDetailResponse(CreditCardBillResponse):
    transacoes: list[CreditCardTransactionResponse]


class ImportacaoOpenFinanceResponse(BaseModel):
    item_id: str
    cartoes: int
    faturas: int
    transacoes: int
    conciliacoes: int
