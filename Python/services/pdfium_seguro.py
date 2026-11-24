"""Serializa o uso do pypdfium2, que não é seguro entre threads.

A documentação do pypdfium2 pede uma trava de processo: a biblioteca
nativa mantém estado global e duas threads dentro dela ao mesmo tempo
podem derrubar o processo inteiro — e o uvicorn roda em processo único,
derrubando o servidor para todo mundo. O FastAPI executa
`desproteger_pdf` (fatura) e `pdf_primeira_pagina_para_jpeg`
(comprovante) no threadpool, então todo uso do `pdfium` — abrir, contar
páginas, importar, salvar, fechar — fica dentro de `with trava_pdfium:`.
"""

import threading

trava_pdfium = threading.Lock()
