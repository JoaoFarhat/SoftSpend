"""Garantias do workflow de deploy (.github/workflows/deploy.yml), lido como texto."""

import re
from pathlib import Path

_TEXTO = (
    Path(__file__).resolve().parents[2] / ".github" / "workflows" / "deploy.yml"
).read_text(encoding="utf-8")


def _job_test() -> str:
    """Trecho do job `test` (do `  test:` até o próximo job)."""
    inicio = _TEXTO.index("\n  test:")
    fim = _TEXTO.index("\n  migrations-mysql:")
    return _TEXTO[inicio:fim]


def _job_migrations_mysql() -> str:
    """Trecho do job `migrations-mysql` (até o job `deploy`)."""
    inicio = _TEXTO.index("\n  migrations-mysql:")
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


def test_job_migrations_mysql_vem_antes_do_deploy():
    """O job novo fica entre `test` e `deploy` no arquivo."""
    assert _TEXTO.index("\n  test:") < _TEXTO.index("\n  migrations-mysql:")
    assert _TEXTO.index("\n  migrations-mysql:") < _TEXTO.index("\n  deploy:")


def test_job_migrations_mysql_sobe_mysql_8_e_roda_as_migrations():
    job = _job_migrations_mysql()
    assert "image: mysql:8.0" in job
    assert 'python-version: "3.12"' in job
    assert re.search(
        r"MYSQL_TESTE_URL:\s*mysql\+pymysql://", job
    )
    assert "pytest -q tests/test_migrations_mysql.py" in job


def test_job_deploy_espera_test_e_migrations_mysql():
    job = _job_deploy()
    assert re.search(
        r"^    needs:\s*\[test, migrations-mysql\]\s*$", job, re.MULTILINE
    )


def test_job_deploy_tem_environment_producao():
    job = _job_deploy()
    assert re.search(r"^    environment:\s*$", job, re.MULTILINE)
    assert re.search(r"^      name:\s*producao\s*$", job, re.MULTILINE)
    assert "url: https://softspend.com.br/health" in job


def test_job_deploy_tem_teto_de_15_minutos():
    """A migration roda dentro do SSH: um MySQL que não responde não pode
    prender o deploy pelas 6h padrão do Actions."""
    assert re.search(
        r"^    timeout-minutes:\s*15\s*$", _job_deploy(), re.MULTILINE
    )


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


def test_antes_e_capturado_antes_do_fetch_e_do_reset():
    linhas = _TEXTO.splitlines()
    rev = next(i for i, l in enumerate(linhas) if "git rev-parse HEAD" in l)
    fetch = next(i for i, l in enumerate(linhas) if "git fetch origin" in l)
    reset = next(
        i for i, l in enumerate(linhas) if "git reset --hard origin/main" in l
    )
    assert rev < fetch < reset


def test_health_check_virou_funcao_sem_exit_dentro():
    job = _job_deploy()
    inicio = job.index("checar_saude()")
    fim = job.index("\n            }", inicio)
    funcao = job[inicio:fim]
    assert "for i in {1..10}" in funcao
    assert "curl -fsS http://127.0.0.1:8000/health" in funcao
    assert "return 0" in funcao
    assert "return 1" in funcao
    assert "exit" not in funcao


def test_migrou_marcado_quando_atual_difere_do_novo():
    job = _job_deploy()
    assert 'MIGROU=""' in job
    linhas = job.splitlines()
    cond = next(
        i for i, l in enumerate(linhas) if '"$ATUAL" != "$NOVO"' in l
    )
    assert "MIGROU=1" in linhas[cond + 1]


def test_reset_para_antes_so_no_ramo_sem_migrou():
    job = _job_deploy()
    assert job.count('git reset --hard "$ANTES"') == 1
    trecho = job[job.index('[ -z "$MIGROU" ]') :]
    trecho = trecho[: trecho.index("health check falhou depois de migration")]
    assert "deploy desfeito: voltou para $ANTES" in trecho
    assert "a volta também falhou" in trecho


def test_volta_automatica_roda_inteira_dentro_de_um_if():
    """Os passos da volta (reset, deps, restart, health) ficam na condicao
    de um unico if: se qualquer um falha, o set -e nao encerra calado —
    cai no else que avisa "a volta também falhou"."""
    job = _job_deploy()
    trecho = job[job.index('[ -z "$MIGROU" ]') :]
    trecho = trecho[: trecho.index("health check falhou depois de migration")]
    cond = next(
        l.strip()
        for l in trecho.splitlines()
        if 'git reset --hard "$ANTES"' in l
    )
    assert cond.startswith("if ")
    assert "&& pip install -r requirements.txt" in cond
    assert "&& sudo systemctl restart softspend" in cond
    assert "&& checar_saude" in cond
    assert cond.endswith("; then")
    soltos = [
        l.strip()
        for l in trecho.splitlines()
        if l.strip()
        in ("pip install -r requirements.txt", "sudo systemctl restart softspend")
    ]
    assert soltos == []


def test_ramo_de_falha_mostra_journalctl_e_termina_em_exit_1():
    job = _job_deploy()
    assert "sudo journalctl -u softspend -n 50 --no-pager" in job
    linhas = [l.strip() for l in job.splitlines() if l.strip()]
    i_exit = len(linhas) - 1 - linhas[::-1].index("exit 1")
    assert all(l == "fi" for l in linhas[i_exit + 1 :])
    # O exit 1 continua depois do ramo da volta: o job sai vermelho nos
    # dois casos (volta ok ou falha).
    assert job.index('[ -z "$MIGROU" ]') < job.index("exit 1")


def test_health_check_continua_na_url_local():
    assert "curl -fsS http://127.0.0.1:8000/health" in _job_deploy()
