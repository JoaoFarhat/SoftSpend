//
//  LinksLegais.swift
//  SoftSpend
//
//  Endereços dos textos legais exigidos pela loja, usados na tela de planos,
//  no cadastro e no perfil (docs/publicacao.md §2). Abrem no Safari.
//

import Foundation

/// PENDENTE (§6): os textos ainda não estão hospedados (rascunhos em
/// `docs/legal/`). O app não vai para a loja antes de essas URLs responderem.
enum LinksLegais {
    static let termos = URL(string: "https://softspend.com.br/termos")!
    static let privacidade = URL(string: "https://softspend.com.br/privacidade")!
    static let suporte = URL(string: "https://softspend.com.br/suporte")!
}
