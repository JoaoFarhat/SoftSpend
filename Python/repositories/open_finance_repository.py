from sqlalchemy.orm import Session
import models


def buscar_conexao_por_item(db: Session, item_id: str):
    return (
        db.query(models.OpenFinanceConnection)
        .filter(
            models.OpenFinanceConnection.provider == "pluggy",
            models.OpenFinanceConnection.item_id == item_id,
        )
        .first()
    )


def upsert_conexao(
    db: Session,
    item_id: str,
    user_id: str,
    institution_name=None,
    status=None,
    client_user_id=None,
    error_code=None,
    error_message=None,
):
    conexao = buscar_conexao_por_item(db, item_id)
    if conexao is None:
        conexao = models.OpenFinanceConnection(
            provider="pluggy", item_id=item_id, user_id=user_id
        )
        db.add(conexao)

    conexao.user_id = user_id
    conexao.client_user_id = client_user_id
    conexao.institution_name = institution_name
    conexao.status = status
    conexao.error_code = error_code
    conexao.error_message = error_message
    db.flush()
    return conexao


def upsert_cartao(db: Session, conexao, account: dict):
    account_id = account.get("id")
    credit_data = account.get("creditData") or {}
    cartao = (
        db.query(models.CreditCardAccount)
        .filter(models.CreditCardAccount.account_id == account_id)
        .first()
    )
    if cartao is None:
        cartao = models.CreditCardAccount(
            conexao_id=conexao.id, user_id=conexao.user_id, account_id=account_id
        )
        db.add(cartao)

    cartao.conexao_id = conexao.id
    cartao.user_id = conexao.user_id
    cartao.institution_name = conexao.institution_name
    cartao.name = account.get("name")
    cartao.marketing_name = account.get("marketingName")
    cartao.number_last4 = str(account.get("number") or "")[-4:] or None
    cartao.type = account.get("type")
    cartao.subtype = account.get("subtype")
    cartao.currency_code = account.get("currencyCode")
    cartao.balance = account.get("balance")
    cartao.credit_limit = credit_data.get("creditLimit")
    cartao.available_credit_limit = credit_data.get("availableCreditLimit")
    cartao.minimum_payment = credit_data.get("minimumPayment")
    cartao.balance_close_date = credit_data.get("balanceCloseDate")
    cartao.balance_due_date = credit_data.get("balanceDueDate")
    cartao.brand = credit_data.get("brand")
    cartao.level = credit_data.get("level")
    cartao.status = credit_data.get("status")
    db.flush()
    return cartao


def upsert_fatura(db: Session, cartao, bill: dict):
    fatura = (
        db.query(models.CreditCardBill)
        .filter(models.CreditCardBill.bill_id == bill.get("id"))
        .first()
    )
    if fatura is None:
        fatura = models.CreditCardBill(
            cartao_id=cartao.id, user_id=cartao.user_id, bill_id=bill.get("id")
        )
        db.add(fatura)

    fatura.cartao_id = cartao.id
    fatura.user_id = cartao.user_id
    fatura.due_date = bill.get("dueDate")
    fatura.closing_date = bill.get("billClosingDate")
    fatura.total_amount = bill.get("totalAmount")
    fatura.currency_code = bill.get("totalAmountCurrencyCode")
    fatura.minimum_payment_amount = bill.get("minimumPaymentAmount")
    fatura.allows_installments = bill.get("allowsInstallments")
    fatura.finance_charges = bill.get("financeCharges")
    fatura.payments = bill.get("payments")
    db.flush()
    return fatura


def upsert_transacao(
    db: Session,
    cartao,
    transaction: dict,
    fatura=None,
    last_seen_at=None,
):
    transaction_id = transaction.get("id")
    merchant = transaction.get("merchant") or {}
    transacao = (
        db.query(models.CreditCardTransaction)
        .filter(models.CreditCardTransaction.transaction_id == transaction_id)
        .first()
    )
    if transacao is None:
        transacao = models.CreditCardTransaction(
            cartao_id=cartao.id,
            user_id=cartao.user_id,
            transaction_id=transaction_id,
        )
        db.add(transacao)

    transacao.cartao_id = cartao.id
    transacao.user_id = cartao.user_id
    transacao.fatura_id = fatura.id if fatura else None
    transacao.description = transaction.get("description")
    transacao.description_raw = transaction.get("descriptionRaw")
    transacao.amount = transaction.get("amount")
    transacao.amount_in_account_currency = transaction.get(
        "amountInAccountCurrency"
    )
    transacao.currency_code = transaction.get("currencyCode")
    transacao.date = transaction.get("date")
    transacao.category = transaction.get("category")
    transacao.status = transaction.get("status")
    transacao.type = transaction.get("type")
    transacao.provider_code = transaction.get("providerCode")
    transacao.provider_id = transaction.get("providerId")
    transacao.merchant_name = merchant.get("name")
    transacao.credit_card_metadata = transaction.get("creditCardMetadata")
    transacao.last_seen_at = last_seen_at
    db.flush()
    return transacao


def remover_transacoes(
    db: Session, user_id: str, cartao_id: int, transaction_ids: list[str]
):
    transacoes_ids = db.query(models.CreditCardTransaction.id).filter(
        models.CreditCardTransaction.user_id == user_id,
        models.CreditCardTransaction.cartao_id == cartao_id,
        models.CreditCardTransaction.transaction_id.in_(transaction_ids),
    )
    db.query(models.ExpenseTransactionMatch).filter(
        models.ExpenseTransactionMatch.cartao_transacao_id.in_(transacoes_ids)
    ).delete(synchronize_session=False)
    db.query(models.CreditCardTransaction).filter(
        models.CreditCardTransaction.id.in_(transacoes_ids)
    ).delete(synchronize_session=False)


def listar_conexoes(db: Session, user_id: str):
    return (
        db.query(models.OpenFinanceConnection)
        .filter(models.OpenFinanceConnection.user_id == user_id)
        .order_by(models.OpenFinanceConnection.created_at.desc())
        .all()
    )


def listar_cartoes(db: Session, user_id: str):
    return (
        db.query(models.CreditCardAccount)
        .filter(models.CreditCardAccount.user_id == user_id)
        .order_by(models.CreditCardAccount.created_at.desc())
        .all()
    )


def buscar_cartao(db: Session, user_id: str, cartao_id: int):
    return (
        db.query(models.CreditCardAccount)
        .filter(
            models.CreditCardAccount.id == cartao_id,
            models.CreditCardAccount.user_id == user_id,
        )
        .first()
    )


def listar_faturas(db: Session, user_id: str, cartao_id: int):
    return (
        db.query(models.CreditCardBill)
        .filter(
            models.CreditCardBill.user_id == user_id,
            models.CreditCardBill.cartao_id == cartao_id,
        )
        .order_by(models.CreditCardBill.due_date.desc())
        .all()
    )


def listar_transacoes(db: Session, user_id: str, cartao_id: int):
    return (
        db.query(models.CreditCardTransaction)
        .filter(
            models.CreditCardTransaction.user_id == user_id,
            models.CreditCardTransaction.cartao_id == cartao_id,
        )
        .order_by(models.CreditCardTransaction.date.desc())
        .all()
    )


def buscar_fatura_por_provider_id(db: Session, bill_id: str):
    return (
        db.query(models.CreditCardBill)
        .filter(models.CreditCardBill.bill_id == bill_id)
        .first()
    )


def buscar_fatura(db: Session, user_id: str, fatura_id: int):
    return (
        db.query(models.CreditCardBill)
        .filter(
            models.CreditCardBill.id == fatura_id,
            models.CreditCardBill.user_id == user_id,
        )
        .first()
    )


def listar_transacoes_fatura(db: Session, user_id: str, fatura_id: int):
    return (
        db.query(models.CreditCardTransaction)
        .filter(
            models.CreditCardTransaction.user_id == user_id,
            models.CreditCardTransaction.fatura_id == fatura_id,
        )
        .order_by(models.CreditCardTransaction.date.desc())
        .all()
    )


def listar_gastos_sem_match(db: Session, user_id: str):
    return (
        db.query(models.Gasto)
        .join(models.Gasto.dia)
        .join(models.Dia.ciclo)
        .outerjoin(
            models.ExpenseTransactionMatch,
            models.ExpenseTransactionMatch.gasto_id == models.Gasto.id,
        )
        .filter(
            models.Ciclo.id_usuario == user_id,
            models.ExpenseTransactionMatch.id.is_(None),
        )
        .all()
    )


def listar_transacoes_sem_match(db: Session, user_id: str):
    return (
        db.query(models.CreditCardTransaction)
        .outerjoin(
            models.ExpenseTransactionMatch,
            models.ExpenseTransactionMatch.cartao_transacao_id
            == models.CreditCardTransaction.id,
        )
        .filter(
            models.CreditCardTransaction.user_id == user_id,
            models.ExpenseTransactionMatch.id.is_(None),
        )
        .all()
    )


def listar_matches_usuario(db: Session, user_id: str):
    return (
        db.query(models.ExpenseTransactionMatch)
        .join(
            models.CreditCardTransaction,
            models.ExpenseTransactionMatch.cartao_transacao_id
            == models.CreditCardTransaction.id,
        )
        .filter(models.CreditCardTransaction.user_id == user_id)
        .order_by(models.ExpenseTransactionMatch.matched_at.desc())
        .all()
    )


def buscar_match(db: Session, user_id: str, match_id: int):
    return (
        db.query(models.ExpenseTransactionMatch)
        .join(
            models.CreditCardTransaction,
            models.ExpenseTransactionMatch.cartao_transacao_id
            == models.CreditCardTransaction.id,
        )
        .filter(
            models.ExpenseTransactionMatch.id == match_id,
            models.CreditCardTransaction.user_id == user_id,
        )
        .first()
    )


def confirmar_match(
    db: Session, match: models.ExpenseTransactionMatch
) -> models.ExpenseTransactionMatch:
    match.status = "CONFIRMED"
    match.method = "MANUAL_CONFIRM"
    match.confirmed_by_user = True
    db.flush()
    return match


def criar_match(
    db: Session,
    gasto: models.Gasto,
    transacao: models.CreditCardTransaction,
    status: str,
    score: int,
    method: str = "RULES",
):
    match = models.ExpenseTransactionMatch(
        gasto_id=gasto.id,
        cartao_transacao_id=transacao.id,
        status=status,
        score=score,
        method=method,
    )
    db.add(match)
    db.flush()
    return match


def remover_match(db: Session, match: models.ExpenseTransactionMatch):
    db.delete(match)
    db.flush()
