//
//  FecharTeclado.swift
//  SoftexVamo
//

import UIKit

/// Fecha o teclado com um toque em qualquer lugar fora de um campo de texto, no app inteiro
/// (pedido do usuário de 10/11, no lugar do botão "OK" que ficava sobre o teclado).
///
/// É um toque na janela que não consome o toque (`cancelsTouchesInView = false`): botões, listas e
/// gestos das telas continuam recebendo o mesmo toque. Toque dentro de um campo de texto é ignorado,
/// e tocar em outro campo só troca o foco (o campo novo assume o teclado logo em seguida).
@MainActor
final class FecharTeclado: NSObject, UIGestureRecognizerDelegate {
    static let shared = FecharTeclado()

    private var janelas: Set<ObjectIdentifier> = []

    /// Liga em todas as janelas abertas; chamar de novo não duplica.
    func instalar() {
        for cena in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for janela in cena.windows where !janelas.contains(ObjectIdentifier(janela)) {
                let toque = UITapGestureRecognizer(target: self, action: #selector(tocou(_:)))
                toque.cancelsTouchesInView = false
                toque.delegate = self
                janela.addGestureRecognizer(toque)
                janelas.insert(ObjectIdentifier(janela))
            }
        }
    }

    @objc private func tocou(_ toque: UITapGestureRecognizer) {
        toque.view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let atual = view {
            if atual is UITextField || atual is UITextView { return false }
            view = atual.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith outro: UIGestureRecognizer) -> Bool {
        true
    }
}
