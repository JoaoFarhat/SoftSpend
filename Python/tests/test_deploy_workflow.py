"""Garantias do workflow de deploy (.github/workflows/deploy.yml), lido como texto."""

import re
from pathlib import Path

_TEXTO = (
    Path(__file__).resolve().parents[2] / ".github" / "workflows" / "deploy.yml"
).read_text(encoding="utf-8")


def _job_test() -> str:
    """Trecho do job `test` (do `  test:` até o próximo job)."""
    inicio = _TEXTO.index("\n  test:")
    fim = _TEXTO.index("\n  deploy:")
    return _TEXTO[inicio:fim]


def _job_deploy() -> str:
    """Trecho do job `deploy` (do `  deploy:` até o fim do arquivo)."""
    return _TEXTO[_TEXTO.index("\n  deploy:") :]


def test_job_test_roda_no_python_312_e_314():
    job = _job_test()
    assert re.search(r"^    strategy:\s*$", job, re.MULTILINE)
    assert re.search(r"^      fail-fast:\s*false\s*$", job, re.MULTILINE)
    assert re.search(r'^      matrix:\s*$', job, re.MULTILINE)
    assert '"3.12"' in job
    assert '"3.14"' in job
    assert "python-version: ${{ matrix.python-version }}" in job


def test_job_deploy_espera_o_job_test():
    job = _job_deploy()
    assert re.search(r"^    needs:\s*test\s*$", job, re.MULTILINE)


def test_job_deploy_tem_environment_producao():
    job = _job_deploy()
    assert re.search(r"^    environment:\s*$", job, re.MULTILINE)
    assert re.search(r"^      name:\s*producao\s*$", job, re.MULTILINE)
    assert "url: https://softspend.com.br/health" in job


def test_apt_get_so_dentro_do_bloco_condicional():
    linhas = _TEXTO.splitlines()
    dpkg = next(
        i for i, l in enumerate(linhas) if "dpkg -s" in l
    )
    fecha = next(
        i for i in range(dpkg, len(linhas)) if linhas[i].strip() == "}"
    )
    dentro = linhas[dpkg : fecha + 1]
    fora = [
        l
        for l in linhas[:dpkg] + linhas[fecha + 1 :]
        if not l.strip().startswith("#")
    ]
    assert any("apt-get update" in l for l in dentro)
    assert any("apt-get install" in l for l in dentro)
    assert not any("apt-get" in l for l in fora)


def test_backup_vem_antes_do_alembic_upgrade():
    linhas = _TEXTO.splitlines()
    backup = next(
        i
        for i, l in enumerate(linhas)
        if "systemctl start softspend-backup.service" in l
    )
    upgrade = next(
        i for i, l in enumerate(linhas) if "alembic" in l and "upgrade head" in l
    )
    assert backup < upgrade


def test_backup_condicionado_a_migration_pendente_e_ao_servico():
    job = _job_deploy()
    assert "alembic -c alembic/alembic.ini current" in job
    assert "alembic -c alembic/alembic.ini heads" in job
    assert "systemctl cat softspend-backup.service" in job
    assert "backup não instalado, migration sem cópia" in job
