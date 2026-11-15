"""Páginas estáticas legais (/termos, /privacidade, /suporte).

São servidas direto pelo nginx, a partir de /var/www/softspend, sem passar
pelo uvicorn (deploy/ec2/nginx-softspend.conf). Este arquivo garante que as
três páginas existem em deploy/site/, estão em pt-BR e não têm campo por
preencher, e que a config do nginx publica as três URLs.
"""

import re
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parents[2]
SITE = RAIZ / "deploy" / "site"
NGINX_CONF = RAIZ / "deploy" / "ec2" / "nginx-softspend.conf"

PAGINAS = ("termos", "privacidade", "suporte")

# Campo por preencher no texto legal, como [CNPJ] ou [E-MAIL DE SUPORTE].
CAMPO_PENDENTE = re.compile(r"\[[A-ZÀ-Ú0-9][^\[\]]*\]")


@pytest.mark.parametrize("pagina", PAGINAS)
def test_pagina_existe_e_esta_em_pt_br(pagina):
    arquivo = SITE / f"{pagina}.html"
    assert arquivo.is_file(), f"{arquivo} não existe"
    html = arquivo.read_text(encoding="utf-8")
    assert 'lang="pt-BR"' in html
    assert 'name="viewport"' in html


@pytest.mark.parametrize("pagina", PAGINAS)
def test_pagina_sem_campo_por_preencher(pagina):
    html = (SITE / f"{pagina}.html").read_text(encoding="utf-8")
    assert CAMPO_PENDENTE.search(html) is None


def test_nginx_serve_as_tres_paginas():
    conf = NGINX_CONF.read_text(encoding="utf-8")
    for pagina in PAGINAS:
        assert f"location = /{pagina}" in conf
        assert f"/{pagina}.html" in conf
    # As locations ficam no bloco do 443, antes do proxy reverso.
    bloco_443 = conf.split("listen 443", 1)[1]
    assert bloco_443.index("location = /termos") < bloco_443.index("location /")
