"""Cadeia de migrations do Alembic (`Python/alembic/versions`).

Usa o `ScriptDirectory` do mesmo jeito que `_heads_alembic` em
`scripts/conferir_servidor.py`, sem banco. Uma segunda "cabeça" (dois
arquivos com o mesmo `down_revision`, como aconteceu com os PRs #215/#216)
faz o `alembic upgrade head` do `deploy.yml` falhar com "Multiple head
revisions" depois do `git reset`, deixando código novo no servidor sem a
migration aplicada.
"""

import re
from collections import Counter
from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory

_PASTA = Path(__file__).resolve().parents[1]
_VERSOES = _PASTA / "alembic" / "versions"
_BASE = "663d2dcc98c8"

_REVISAO = re.compile(r"^revision\b[^=]*=\s*['\"]([^'\"]+)['\"]", re.MULTILINE)
_DOWN = re.compile(
    r"^down_revision\b[^=]*=\s*(?:['\"]([^'\"]+)['\"]|None)", re.MULTILINE
)


def _scripts() -> ScriptDirectory:
    config = Config()
    config.set_main_option("script_location", str(_PASTA / "alembic"))
    return ScriptDirectory.from_config(config)


def _revisoes_dos_arquivos() -> dict[str, str]:
    """`revision` lida do texto de cada `.py` → nome do arquivo."""
    revisoes = {}
    for arq in sorted(_VERSOES.glob("*.py")):
        texto = arq.read_text(encoding="utf-8")
        encontrada = _REVISAO.search(texto)
        assert encontrada, f"{arq.name} sem `revision`"
        revisoes[encontrada.group(1)] = arq.name
    return revisoes


def _down_revisions_dos_arquivos() -> dict[str, str | None]:
    """`revision` → `down_revision` (`None` na base) lido de cada `.py`."""
    downs = {}
    for arq in sorted(_VERSOES.glob("*.py")):
        texto = arq.read_text(encoding="utf-8")
        rev = _REVISAO.search(texto)
        down = _DOWN.search(texto)
        assert rev and down, f"{arq.name} sem `revision`/`down_revision`"
        downs[rev.group(1)] = down.group(1)
    return downs


def test_uma_so_cabeca():
    heads = _scripts().get_heads()
    assert len(heads) == 1, f"cabeças: {heads}"


def test_cadeia_da_base_a_cabeca_passa_por_todas():
    scripts = _scripts()
    bases = list(scripts.get_bases())
    heads = list(scripts.get_heads())
    assert len(bases) == 1, f"bases: {bases}"

    downs = _down_revisions_dos_arquivos()
    filhos: dict[str | None, list[str]] = {}
    for rev, down in downs.items():
        filhos.setdefault(down, []).append(rev)

    cadeia = [bases[0]]
    while filhos.get(cadeia[-1]):
        proximos = filhos[cadeia[-1]]
        assert (
            len(proximos) == 1
        ), f"{cadeia[-1]} tem {len(proximos)} filhos: {sorted(proximos)}"
        seguinte = proximos[0]
        assert seguinte not in cadeia, f"ciclo passando por {seguinte}"
        cadeia.append(seguinte)

    assert heads == [cadeia[-1]], (
        f"cadeia termina em {cadeia[-1]}, cabeças: {heads}"
    )
    soltas = set(downs) - set(cadeia)
    assert not soltas, f"revisões fora da cadeia: {sorted(soltas)}"


def test_revision_nao_repetida():
    revisoes = list(_revisoes_dos_arquivos())
    repetidas = sorted(r for r, n in Counter(revisoes).items() if n > 1)
    assert not repetidas, f"revisions repetidas: {repetidas}"


def test_base_e_a_migration_inicial():
    assert list(_scripts().get_bases()) == [_BASE]
