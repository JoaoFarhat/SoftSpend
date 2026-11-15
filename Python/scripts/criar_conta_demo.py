"""Conta de demonstração para a revisão da Apple (`docs/publicacao.md` §2).

Uso, de dentro de `Python/`:

    DEMO_SENHA='...' python -m scripts.criar_conta_demo --email demo@softspend.com.br

A senha só entra pela variável `DEMO_SENHA`, nunca na linha de comando e
nunca é impressa. Cria o usuário pelo mesmo caminho do cadastro
(`auth_service.registrar`, com o mesmo hash de senha e as mesmas
validações do `RegisterRequest`) e uma viagem de 7 dias terminando hoje,
com 2 a 4 gastos por dia em categorias variadas, sem comprovante.

Em sucesso imprime **só** o `users.id`, para colocar em
`ACESSO_LIBERADO_USUARIOS`. Rodar de novo com o mesmo e-mail não duplica
nada: avisa no stderr e sai sem gravar.
"""

import argparse
import os
import re
import sys
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal

import models
from dtos.auth import RegisterRequest
from enums.categoria_enum import Categoria
from repositories import auth_repository

NOME_PADRAO = "Conta de demonstração"
TITULO_VIAGEM = "Viagem a trabalho"
DIARIA = Decimal("450.00")

# (título, valor, categoria) por dia da viagem, do mais antigo ao de hoje.
GASTOS_POR_DIA = [
    [
        ("Café da manhã", "18.50", Categoria.ALIMENTACAO),
        ("Almoço", "52.90", Categoria.ALIMENTACAO),
        ("Táxi", "34.00", Categoria.TRANSPORTE),
    ],
    [
        ("Almoço", "47.30", Categoria.ALIMENTACAO),
        ("Estacionamento", "20.00", Categoria.TRANSPORTE),
    ],
    [
        ("Café", "9.80", Categoria.ALIMENTACAO),
        ("Almoço", "55.00", Categoria.ALIMENTACAO),
        ("Farmácia", "23.75", Categoria.COMPRAS),
        ("Uber", "27.80", Categoria.TRANSPORTE),
    ],
    [
        ("Almoço", "49.90", Categoria.ALIMENTACAO),
        ("Lavanderia", "45.00", Categoria.OUTROS),
        ("Jantar", "61.40", Categoria.ALIMENTACAO),
    ],
    [
        ("Café da manhã", "21.00", Categoria.ALIMENTACAO),
        ("Almoço", "44.50", Categoria.ALIMENTACAO),
    ],
    [
        ("Almoço", "58.20", Categoria.ALIMENTACAO),
        ("Cinema", "32.00", Categoria.LAZER),
        ("Uber", "31.50", Categoria.TRANSPORTE),
        ("Lanche", "15.20", Categoria.ALIMENTACAO),
    ],
    [
        ("Café", "11.40", Categoria.ALIMENTACAO),
        ("Almoço", "46.80", Categoria.ALIMENTACAO),
        ("Supermercado", "48.60", Categoria.COMPRAS),
    ],
]


def _username_do_email(email: str) -> str:
    """Base do username a partir do e-mail (mesmos limites do cadastro)."""
    base = re.sub(r"[^a-z0-9._-]", "", email.split("@", 1)[0].lower())
    if len(base) < 3:
        base = f"{base}demo"
    return base[:50]


def _username_livre(db, base: str) -> str:
    """Primeiro username livre: `base`, `base-1`, `base-2`, ..."""
    for i in range(100):
        candidato = base if i == 0 else f"{base[:46]}-{i}"
        if not auth_repository.buscar_por_username(db, candidato):
            return candidato
    raise ValueError("Nenhum username livre a partir do e-mail")


def _criar_viagem(db, usuario: models.User, hoje: date) -> models.Ciclo:
    """Viagem de 7 dias terminando hoje, com gastos nos dias.

    Mantém `saldo` do dia e `gasto_total` do ciclo no mesmo valor que o
    lançamento pela API deixaria (dia nasce com a diária e cada gasto
    desconta).
    """
    inicio = hoje - timedelta(days=len(GASTOS_POR_DIA) - 1)
    ciclo = models.Ciclo(
        id_usuario=usuario.id,
        client_id="demo-ciclo",
        valor_total=DIARIA * len(GASTOS_POR_DIA),
        gasto_total=Decimal("0"),
        titulo=TITULO_VIAGEM,
        periodo=f"{inicio:%d/%m/%Y} a {hoje:%d/%m/%Y}",
        diaria=DIARIA,
    )
    db.add(ciclo)
    db.flush()

    for i, gastos_do_dia in enumerate(GASTOS_POR_DIA):
        total_dia = sum(Decimal(valor) for _, valor, _ in gastos_do_dia)
        data = inicio + timedelta(days=i)
        dia = models.Dia(
            client_id=f"demo-dia-{i}",
            ciclo_id=ciclo.id,
            data=datetime.combine(data, time.min, tzinfo=timezone.utc),
            saldo=DIARIA - total_dia,
        )
        db.add(dia)
        db.flush()
        for j, (titulo, valor, categoria) in enumerate(gastos_do_dia):
            db.add(
                models.Gasto(
                    client_id=f"demo-gasto-{i}-{j}",
                    dia_id=dia.id,
                    titulo=titulo,
                    valor=Decimal(valor),
                    categoria=categoria,
                )
            )
        ciclo.gasto_total += total_dia
    db.flush()
    return ciclo


def criar_conta_demo(
    db, dados: RegisterRequest, hoje: date | None = None
) -> models.User | None:
    """Cria a conta demo. Devolve o usuário, ou `None` se o e-mail já existe.

    `None` significa "já existia": nada é gravado. Com e-mail livre, se o
    username pedido estiver em uso por outra conta, tenta sufixos.
    """
    if auth_repository.buscar_por_email(db, dados.email) is not None:
        return None

    from services import auth_service

    if auth_repository.buscar_por_username(db, dados.username) is not None:
        dados = dados.model_copy(
            update={"username": _username_livre(db, dados.username)}
        )
    usuario = auth_service.registrar(db, dados)
    _criar_viagem(db, usuario, hoje or date.today())
    db.commit()
    return usuario


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m scripts.criar_conta_demo",
        description="Cria a conta de demonstração da revisão da Apple.",
    )
    parser.add_argument("--email", required=True, help="E-mail da conta demo")
    parser.add_argument("--nome", default=NOME_PADRAO)
    parser.add_argument(
        "--username",
        default=None,
        help="Padrão: parte local do e-mail (com sufixo se estiver em uso)",
    )
    args = parser.parse_args(argv)

    senha = os.getenv("DEMO_SENHA")
    if not senha:
        print(
            "DEMO_SENHA não definida — a senha só entra por essa variável.",
            file=sys.stderr,
        )
        return 2

    try:
        dados = RegisterRequest(
            nome=args.nome,
            username=args.username or _username_do_email(args.email),
            email=args.email,
            senha=senha,
        )
    except ValueError as exc:
        # `errors` sem `input`: a senha não pode aparecer nem na mensagem.
        erros = exc.errors(include_input=False) if hasattr(exc, "errors") else exc
        print(f"Dados inválidos: {erros}", file=sys.stderr)
        return 2

    from database import SessionLocal

    db = SessionLocal()
    try:
        usuario = criar_conta_demo(db, dados)
        if usuario is None:
            existente = auth_repository.buscar_por_email(db, dados.email)
            print(
                f"Conta demo já existe: {dados.email} (id {existente.id}); "
                "nada foi gravado.",
                file=sys.stderr,
            )
            return 0
        # Lê antes do close: o commit expira os atributos do objeto.
        user_id = usuario.id
    finally:
        db.close()

    # Só o id no stdout: é o que vai em ACESSO_LIBERADO_USUARIOS.
    print(user_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
